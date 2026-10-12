import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart' show SignInNeedsConsent;
import '../../data/compose/reply_draft.dart' show escapeHtml;
import '../../data/mail_engine.dart' show CalendarUnavailable;
import '../../domain/account.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/calendar_meeting.dart';
import '../../domain/draft.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mail_message.dart';
import '../../state/calendar_providers.dart';
import '../../state/providers.dart';
import 'date_format.dart';

/// The meeting mail inside a message, under its header: what, when, where,
/// who, and what can be done about it.
///
/// - An invitation: the three answers, sent to the organiser through the
///   account it came to. Add to calendar hands it to the device's calendar
///   app, where the account's own calendar does not have it already.
/// - A cancellation: Remove from calendar while the account's calendar
///   still has it, as Outlook's button does.
/// - A new time proposed to you as organiser: the time the meeting has now
///   beside the time proposed. Accept proposal moves it on your calendar,
///   which sends everyone the new time; Decline proposal tells the proposer
///   by mail that it stays.
/// - An answer to your invitation: who answered, and how.
///
/// The account's calendar is asked where the meeting stands each time the
/// message is opened ([meetingOnCalendarProvider]), so an invitation moved
/// or cancelled since says so, and nothing is offered that is done already.
class InviteCard extends ConsumerStatefulWidget {
  const InviteCard({super.key, required this.message, required this.invite});

  final MailMessage message;
  final CalendarInvite invite;

  @override
  ConsumerState<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<InviteCard> {
  bool _busy = false;

  String get _id => widget.message.id;

  /// Do [action] with the buttons held, then say [done], or why not after
  /// [failed]. True when it worked.
  Future<bool> _run(
    Future<void> Function() action, {
    required String done,
    required String failed,
  }) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(duration: kBottomMessage, content: Text(done)));
      return true;
    } catch (e) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          content: Text('$failed: ${_reason(e)}'),
        ));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _reason(Object e) => switch (e) {
        ReadableError(:final message) => message,
        ArgumentError(:final message) => '$message',
        _ => '$e',
      };

  Future<void> _respond(InviteResponse response) async {
    // Read before the wait: the card may be gone by the time it is over.
    final responses = ref.read(inviteResponsesProvider.notifier);
    final engine = ref.read(mailEngineProvider);
    if (await _run(
      () => engine.respondToInvite(_id, widget.invite, response),
      done: '${response.word}. The organiser has been told.',
      failed: 'Could not reply',
    )) {
      responses.record(_id, response);
    }
  }

  Future<void> _addToCalendar() async {
    final i = widget.invite;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await ref.read(deviceCalendarProvider).insertEvent(
          title: i.summary,
          description: i.description,
          location: i.location,
          start: i.start,
          end: i.end,
          allDay: i.isAllDay,
        );
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(duration: kBottomMessage, content: Text('No calendar app to add it to.')),
      );
    }
  }

  Future<void> _remove(CalendarMeeting meeting) async {
    final actions = ref.read(meetingActionsProvider.notifier);
    final engine = ref.read(mailEngineProvider);
    if (await _run(
      () => engine.removeFromCalendar(meeting),
      done: 'Removed from your calendar.',
      failed: 'Could not remove it',
    )) {
      actions.record(_id, MeetingAction.removed);
    }
  }

  /// Asked first: everyone on the meeting is sent the new time.
  Future<void> _acceptProposal(CalendarMeeting meeting) async {
    final i = widget.invite;
    final when = describeWhen(
      i,
      use24h: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move the meeting?'),
        content: Text(
          '${i.summary} moves to $when. Everyone invited is sent the new '
          'time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move it'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final actions = ref.read(meetingActionsProvider.notifier);
    final engine = ref.read(mailEngineProvider);
    if (await _run(
      () => engine.moveMeeting(meeting, i),
      done: 'Moved. Everyone invited has been sent the new time.',
      failed: 'Could not move it',
    )) {
      actions.record(_id, MeetingAction.moved);
    }
  }

  Future<void> _declineProposal(CalendarMeeting? meeting) async {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final actions = ref.read(meetingActionsProvider.notifier);
    final engine = ref.read(mailEngineProvider);
    // Waited for rather than read as it stands: the name the mail is
    // signed with is the account's.
    final accounts = ref.read(accountsProvider.future);
    final who = proposerOf(widget.message, widget.invite);
    if (await _run(
      () async {
        List<Account> known;
        try {
          known = await accounts;
        } catch (_) {
          known = const [];
        }
        final account =
            known.where((a) => a.id == widget.message.accountId).firstOrNull;
        await engine.sendDraft(proposalDeclinedDraft(
          message: widget.message,
          proposal: widget.invite,
          senderName: account?.senderName ?? '',
          meeting: meeting,
          use24h: use24h,
        ));
      },
      done: 'Declined. ${who.display} has been told.',
      failed: 'Could not send it',
    )) {
      actions.record(_id, MeetingAction.proposalDeclined);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = widget.invite;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String timesOf(CalendarMeeting m) =>
        describeTimes(m.start, m.end, allDay: m.isAllDay, use24h: use24h);
    final answered = ref.watch(inviteResponsesProvider)[_id];
    final done = ref.watch(meetingActionsProvider)[_id];
    final calendarApp = ref.watch(calendarAvailableProvider).value ?? false;

    // Where the meeting stands on the account's own calendar: settled with
    // it or without it, still being asked, or not to be asked at all.
    final lookup = i.isRequest || i.isCancellation || i.isCounter
        ? ref.watch(meetingOnCalendarProvider(_id))
        : null;
    final checking = lookup != null && lookup.isLoading;
    final failure = lookup != null && !checking && lookup.hasError
        ? lookup.error
        : null;
    final settled = lookup != null && !checking && failure == null;
    final meeting = settled ? lookup.value : null;
    final mine = meeting != null && meeting.isOrganizer;

    final who = proposerOf(widget.message, i);
    final (IconData icon, String heading) = switch (i.method) {
      'CANCEL' => (Icons.event_busy, 'Cancelled'),
      'REQUEST' => (
          Icons.event,
          i.sequence > 0 ? 'Invitation, updated' : 'Invitation',
        ),
      'COUNTER' => (Icons.update, 'New time proposed'),
      'REPLY' => switch (i.responderAnswer) {
          InviteResponse.accepted => (Icons.event_available, 'Accepted'),
          InviteResponse.tentative => (Icons.event_note, 'Tentative'),
          InviteResponse.declined => (Icons.event_busy, 'Declined'),
          null => (Icons.event, 'Answer'),
        },
      'DECLINECOUNTER' => (Icons.event_busy, 'New time declined'),
      _ => (Icons.event, 'Event'),
    };

    // The time the meeting has now, beside the time proposed: the
    // calendar's own once it has answered, the proposer's view till then.
    final current = meeting != null
        ? timesOf(meeting)
        : i.originalStart == null
            ? null
            : describeTimes(i.originalStart!, i.originalEnd, use24h: use24h);
    final atProposed = i.isCounter && meeting?.isAtTimeOf(i) == true;
    // A time proposed that is the time the meeting had, which Outlook lets
    // through: nothing to accept or turn down.
    final unchanged = i.isCounter &&
        i.originalStart != null &&
        _sameTimes(i.originalStart!, i.originalEnd, i.start, i.end);

    final (IconData, String)? status = switch (i.method) {
      'REQUEST' when done == MeetingAction.removed =>
        (Icons.check, 'Removed from your calendar.'),
      'REQUEST' when meeting == null => null,
      'REQUEST' when meeting!.isCancelled =>
        (Icons.event_busy, 'Cancelled since, and still on your calendar.'),
      'REQUEST' when meeting!.isAtTimeOf(i) == false => (
          Icons.info_outline,
          'Your calendar has it at ${timesOf(meeting)}.',
        ),
      'REQUEST' => (Icons.event_available, 'On your calendar at this time.'),
      'CANCEL' when done == MeetingAction.removed =>
        (Icons.check, 'Removed from your calendar.'),
      'COUNTER' when done == MeetingAction.moved => (
          Icons.check,
          'Moved to the time proposed. Everyone invited has been sent it.',
        ),
      'COUNTER' when done == MeetingAction.proposalDeclined =>
        (Icons.check, 'You declined it, and ${who.display} has been told.'),
      'COUNTER' when unchanged =>
        (Icons.info_outline, 'The time proposed is the time it has now.'),
      'CANCEL' || 'COUNTER' when checking =>
        (Icons.hourglass_empty, 'Checking your calendar…'),
      'CANCEL' || 'COUNTER' when failure != null => (
          Icons.info_outline,
          _lookupProblem(failure, counter: i.isCounter),
        ),
      'CANCEL' when meeting == null => (Icons.check, 'Not on your calendar.'),
      'CANCEL' when mine =>
        (Icons.info_outline, 'You organised this meeting.'),
      'CANCEL' => (Icons.event_busy, 'Still on your calendar.'),
      'COUNTER' when meeting == null =>
        (Icons.info_outline, 'The meeting is not on your calendar.'),
      'COUNTER' when !mine =>
        (Icons.info_outline, 'Only its organiser can move it.'),
      'COUNTER' when meeting!.isSeries => (
          Icons.info_outline,
          'Your calendar has this as a whole series; move it there.',
        ),
      'COUNTER' when atProposed =>
        (Icons.check, 'Your calendar already has the time proposed.'),
      _ => null,
    };

    // Can be asked again: a connection or a sign-in that failed, not an
    // account the app has no calendar for.
    final canRetry = failure != null &&
        failure is! CalendarUnavailable &&
        failure is! SignInNeedsConsent &&
        (i.isCancellation || i.isCounter);
    final cancelledOnCalendar = meeting != null && meeting.isCancelled;
    final canRemove = done == null &&
        meeting != null &&
        !mine &&
        (i.isCancellation || (i.isRequest && cancelledOnCalendar));
    final canMove = done == null &&
        i.isCounter &&
        i.timeIsKnown &&
        meeting != null &&
        meeting.isOrganizer &&
        !meeting.isSeries &&
        !atProposed &&
        !unchanged;
    final canDecline = done == null &&
        i.isCounter &&
        !checking &&
        !atProposed &&
        !unchanged;
    // Not where the account's calendar has it already, which is where an
    // Exchange or Google invitation lands by itself; and not for a time in
    // a zone that could not be worked out, which would go in at the right
    // hour of the wrong day's clock.
    final canAdd = calendarApp &&
        i.timeIsKnown &&
        done == null &&
        (i.isRequest ? failure != null || (settled && meeting == null)
            : !(i.isCancellation || i.isCounter || i.isReply ||
                i.isDeclineCounter));

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 12, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: i.isCancellation
            ? scheme.errorContainer.withValues(alpha: 0.5)
            : scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: i.isCancellation ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: 8),
              Text(heading, style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 6),
          Text(i.summary, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          if (i.isCounter) ...[
            _line(
              theme,
              Icons.person_outline,
              switch (i.responderAnswer) {
                InviteResponse.declined =>
                  '${who.display} declined and proposed a new time.',
                InviteResponse.tentative =>
                  '${who.display} tentatively accepted and proposed a new '
                      'time.',
                _ => '${who.display} proposed a new time.',
              },
            ),
            if (current != null)
              _line(theme, Icons.schedule, 'Current: $current'),
            _line(
              theme,
              Icons.update,
              'Proposed: ${describeWhen(i, use24h: use24h)}',
            ),
          ] else
            _line(theme, Icons.schedule, describeWhen(i, use24h: use24h)),
          if (i.location != null && i.location!.trim().isNotEmpty)
            _line(theme, Icons.place_outlined, i.location!),
          if (i.isReply || i.isDeclineCounter)
            _line(theme, Icons.person_outline, who.display)
          else if (!i.isCounter && i.organizer != null)
            _line(theme, Icons.person_outline,
                'Organiser: ${i.organizer!.display}'),
          if (status != null) ...[
            const SizedBox(height: 4),
            _line(theme, status.$1, status.$2),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (answered != null)
                Chip(
                  avatar: const Icon(Icons.check, size: 16),
                  label: Text('You ${answered.word.toLowerCase()}'),
                )
              else if (i.isRequest && !cancelledOnCalendar) ...[
                FilledButton(
                  onPressed: _busy ? null : () => _respond(InviteResponse.accepted),
                  child: const Text('Accept'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _respond(InviteResponse.tentative),
                  child: const Text('Tentative'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _respond(InviteResponse.declined),
                  child: const Text('Decline'),
                ),
              ],
              if (canRemove)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _remove(meeting),
                  icon: const Icon(Icons.event_busy, size: 18),
                  label: const Text('Remove from calendar'),
                ),
              if (canMove)
                FilledButton(
                  onPressed: _busy ? null : () => _acceptProposal(meeting),
                  child: const Text('Accept proposal'),
                ),
              if (canDecline)
                OutlinedButton(
                  onPressed: _busy ? null : () => _declineProposal(meeting),
                  child: const Text('Decline proposal'),
                ),
              if (canRetry)
                TextButton(
                  onPressed: () =>
                      ref.invalidate(meetingOnCalendarProvider(_id)),
                  child: const Text('Try again'),
                ),
              if (canAdd)
                TextButton.icon(
                  onPressed: _addToCalendar,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: const Text('Add to calendar'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The same start, to the minute, and the same end where both have one.
  static bool _sameTimes(
    DateTime start,
    DateTime? end,
    DateTime otherStart,
    DateTime? otherEnd,
  ) {
    bool same(DateTime a, DateTime b) =>
        a.toUtc().difference(b.toUtc()).inSeconds.abs() < 60;
    return same(start, otherStart) &&
        (end == null || otherEnd == null || same(end, otherEnd));
  }

  /// Why the calendar could not say where the meeting stands, and what to
  /// do instead.
  static String _lookupProblem(Object e, {required bool counter}) =>
      switch (e) {
        CalendarUnavailable() =>
          "The app cannot reach this account's calendar. "
              '${counter ? 'Move' : 'Remove'} it in your calendar app.',
        SignInNeedsConsent() =>
          "Microsoft has not yet allowed the app to use this account's "
              'calendar. A New meeting from this account asks for it.',
        ReadableError(:final message) =>
          'Could not check your calendar. $message',
        _ => 'Could not check your calendar. $e',
      };

  Widget _line(ThemeData theme, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
      );
}

/// Who answered, or proposed the time, in [invite]: the attendee its
/// calendar part names, with the message's name for them where the part
/// gives none; the sender, where it names nobody.
MailAddress proposerOf(MailMessage message, CalendarInvite invite) {
  final named = invite.responder;
  if (named == null) return message.from;
  final hasName = named.name?.trim().isNotEmpty ?? false;
  if (!hasName &&
      named.email.toLowerCase() == message.from.email.toLowerCase()) {
    return message.from;
  }
  return named;
}

/// The mail Decline proposal sends whoever proposed [proposal]'s time:
/// that the meeting stays as it is, and when that is.
///
/// Plain words, with no calendar part: Outlook reads no iCalendar that says
/// no to a time proposed, and one it misread would be worse than none. The
/// times carry the phone's zone, since the proposer may be in another.
Draft proposalDeclinedDraft({
  required MailMessage message,
  required CalendarInvite proposal,
  required String senderName,
  CalendarMeeting? meeting,
  bool use24h = true,
}) {
  String zoned(DateTime start, DateTime? end, {required bool allDay}) =>
      describeTimes(
        start,
        end,
        allDay: allDay,
        use24h: use24h,
        zone: allDay ? null : start.toLocal().timeZoneName,
      );
  final proposed = proposal.timeIsKnown
      ? zoned(proposal.start, proposal.end, allDay: proposal.isAllDay)
      : describeWhen(proposal, use24h: use24h);
  final current = meeting != null
      ? zoned(meeting.start, meeting.end, allDay: meeting.isAllDay)
      : proposal.originalStart != null
          ? zoned(proposal.originalStart!, proposal.originalEnd,
              allDay: false)
          : null;
  final name = senderName.trim().isEmpty ? 'The organiser' : senderName.trim();
  return Draft(
    accountId: message.accountId,
    kind: ComposeKind.reply,
    to: [proposerOf(message, proposal)],
    subject: 'New time declined: ${proposal.summary}',
    htmlBody: '<p>${escapeHtml(name)} declined the new time you proposed for '
        '${escapeHtml(proposal.summary)}, ${escapeHtml(proposed)}.</p>'
        '${current == null ? '' : '<p>The meeting stays at '
            '${escapeHtml(current)}.</p>'}',
    originalMessageId: message.id,
  );
}

/// "Mon 21 Sep 2026, 13:00–14:00 (Eastern Standard Time)", or the day
/// alone for a whole-day event.
///
/// Times are written the way the phone's clock is set ([use24h]).
String describeWhen(CalendarInvite i, {bool use24h = true}) => describeTimes(
      i.start,
      i.end,
      allDay: i.isAllDay,
      use24h: use24h,
      // A named zone the device could not apply: the time is the sender's.
      zone: i.timeZone != null && !i.start.isUtc ? i.timeZone : null,
    );

/// "Mon 21 Sep 2026, 13:00–14:00", on the phone's clock: an instant is
/// shown as the phone's time, and anything else as it is. A whole day is
/// its date, whatever zone it was given in. [zone], where given, is named
/// after the time.
String describeTimes(
  DateTime start,
  DateTime? end, {
  bool allDay = false,
  bool use24h = true,
  String? zone,
}) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String clock(DateTime t) => formatClock(t, use24h: use24h);
  final s = start.isUtc && !allDay ? start.toLocal() : start;
  final day = '${days[s.weekday - 1]} ${s.day} ${months[s.month - 1]} ${s.year}';
  if (allDay) return '$day, all day';
  final e = end == null ? null : (end.isUtc ? end.toLocal() : end);
  var when = '$day, ${clock(s)}';
  if (e != null) {
    when += e.year == s.year && e.month == s.month && e.day == s.day
        ? '–${clock(e)}'
        : ' to ${days[e.weekday - 1]} ${e.day} ${months[e.month - 1]}, ${clock(e)}';
  }
  if (zone != null) when += ' ($zone)';
  return when;
}
