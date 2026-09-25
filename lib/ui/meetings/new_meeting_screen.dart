import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/mail_engine.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart';
import '../../domain/mail_message.dart';
import '../../domain/meeting.dart';
import '../../state/calendar_providers.dart';
import '../../state/compose_providers.dart'
    show addressesLookValid, parseAddresses;
import '../../state/meeting_providers.dart';
import '../../state/providers.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../common/problem_view.dart';
import '../compose/header_fields.dart';
import '../messages/date_format.dart' show formatClock, formatDay;

/// Open the new-meeting screen.
///
/// [accountId] presets From. Without one it is the account of the folder on
/// screen, or the first account where that is the unified Inbox. [title]
/// and [notes] prefill the rest, for a meeting made out of a message.
Future<void> openNewMeeting(
  BuildContext context,
  WidgetRef ref, {
  String? accountId,
  String title = '',
  String notes = '',
}) async {
  final resolved = accountId ??
      ref.read(accountOnScreenProvider) ??
      ref.read(accountsProvider).value?.firstOrNull?.id;
  if (resolved == null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        duration: kBottomMessage,
        content: Text('Add an account first.'),
      ));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NewMeetingScreen(
        accountId: resolved,
        title: title,
        notes: notes,
      ),
    ),
  );
}

/// The new-meeting screen filled in from a message: its subject as the
/// title, its text as the notes, from the account it came to. For the mail
/// that says "let's meet Thursday" without sending an invitation.
Future<void> openNewMeetingFromMessage(
  BuildContext context,
  WidgetRef ref,
  MailMessage message,
  MailBody body,
) {
  final text = body.text.trim();
  // Cut, as a body can run to pages; the message itself stays where it is.
  final notes = text.length > 2000 ? '${text.substring(0, 2000)}…' : text;
  return openNewMeeting(
    context,
    ref,
    accountId: message.accountId,
    title: message.subject,
    notes: '$notes\n\nFrom: ${message.from.display}',
  );
}

/// Set up a meeting: from which account, what, who is asked, and when.
///
/// The shape of the compose screen, because it is the same act, writing to
/// people from one of the accounts, with a time in place of a body. Send
/// puts the event on the account's own calendar, which sends the
/// invitations and keeps the answers. Where the account has no calendar the
/// app can reach, the meeting goes to the phone's calendar app instead,
/// attendees and all; where Microsoft has not yet allowed the app the
/// calendar, the sign-in that asks for it is offered here rather than in
/// Settings.
class NewMeetingScreen extends ConsumerStatefulWidget {
  const NewMeetingScreen({
    super.key,
    required this.accountId,
    this.title = '',
    this.notes = '',
    this.start,
  });

  final String accountId;
  final String title;
  final String notes;

  /// When it starts. The next whole hour when null; the end is an hour on.
  final DateTime? start;

  @override
  ConsumerState<NewMeetingScreen> createState() => _NewMeetingScreenState();
}

class _NewMeetingScreenState extends ConsumerState<NewMeetingScreen> {
  /// Which account the meeting is from. Starts as the one it was opened
  /// for, and can be changed from the header: Ron asked to choose the
  /// account before anything else about an invitation, and the calendar
  /// it lands on follows from it.
  late String _accountId = widget.accountId;

  late final _title = TextEditingController(text: widget.title);
  final _attendees = TextEditingController();
  final _location = TextEditingController();
  late final _notes = TextEditingController(text: widget.notes);

  late DateTime _start = widget.start ?? _nextHour(DateTime.now());
  late DateTime _end = _start.add(const Duration(hours: 1));
  bool _allDay = false;
  bool _sending = false;

  /// Something the person can correct on the screen: no title, an end
  /// before the start, an address with a typo. Not a failure.
  String? _invalid;

  /// A way things went that is neither theirs to correct nor worth
  /// reporting, said in a sentence: Microsoft wanting a consent, or nowhere
  /// to hand the meeting to.
  String? _notice;

  /// Whether a sign-in that asks Microsoft for the calendar is offered
  /// under [_notice], and whether it is the administrator being asked.
  ///
  /// Offered even when only an administrator can give it. The sign-in
  /// cannot succeed then, but Microsoft's page is where the request to
  /// the administrator is made: it offers "Request approval", the
  /// administrator is told, and the mail permissions were granted this
  /// way the first time. Kept off it, there was no way to ask.
  bool _offerConsent = false;
  bool _askAdministrator = false;

  /// Something that went wrong out of their hands. Worth reporting.
  ProblemReport? _problem;

  static DateTime _nextHour(DateTime now) =>
      DateTime(now.year, now.month, now.day, now.hour + 1);

  @override
  void dispose() {
    _title.dispose();
    _attendees.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Account? get _account => ref
      .read(accountsProvider)
      .value
      ?.where((a) => a.id == _accountId)
      .firstOrNull;

  /// Whether leaving loses nothing: the screen is as it opened, and what it
  /// opened with can be had again.
  bool get _untouched =>
      _title.text == widget.title &&
      _attendees.text.isEmpty &&
      _location.text.isEmpty &&
      _notes.text == widget.notes;

  /// Move the start, and the end with it, so the meeting keeps its length:
  /// a meeting moved to Tuesday is still an hour long.
  void _setStart(DateTime next) {
    final length = _end.difference(_start);
    setState(() {
      _start = next;
      _end = next.add(length.isNegative ? const Duration(hours: 1) : length);
    });
  }

  Future<void> _pickDate(DateTime at, ValueChanged<DateTime> set) async {
    final day = await showDatePicker(
      context: context,
      initialDate: at,
      firstDate: DateTime(at.year - 1),
      lastDate: DateTime(at.year + 10),
    );
    if (day == null) return;
    set(DateTime(day.year, day.month, day.day, at.hour, at.minute));
  }

  Future<void> _pickTime(DateTime at, ValueChanged<DateTime> set) async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(at),
    );
    if (time == null) return;
    set(DateTime(at.year, at.month, at.day, time.hour, time.minute));
  }

  /// What the screen holds, as a meeting, with the device's zone so the
  /// calendar knows what clock the times are on.
  Future<MeetingDraft> _draft(List<MailAddress> attendees) async {
    String? zone;
    try {
      zone = await ref.read(deviceCalendarProvider).timeZoneId();
    } catch (_) {
      // Then the times go as UTC, which every calendar reads.
    }
    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
    return MeetingDraft(
      accountId: _accountId,
      title: _title.text.trim(),
      attendees: attendees,
      start: _allDay ? day(_start) : _start,
      end: _allDay ? day(_end) : _end,
      allDay: _allDay,
      location: _location.text.trim(),
      notes: _notes.text.trim(),
      timeZone: zone,
    );
  }

  Future<void> _send() async {
    final attendees = parseAddresses(_attendees.text);
    if (!addressesLookValid(attendees)) {
      setState(() => _invalid = 'One of the addresses does not look right.');
      return;
    }
    final meeting = await _draft(attendees);
    if (!mounted) return;
    final problem = meeting.problem;
    if (problem != null) {
      setState(() => _invalid = problem);
      return;
    }

    setState(() {
      _sending = true;
      _invalid = null;
      _notice = null;
      _offerConsent = false;
      _problem = null;
    });
    try {
      await ref.read(mailEngineProvider).createMeeting(meeting);
      if (!mounted) return;
      _leave(meeting.hasAttendees ? 'Invitation sent' : 'Added to your calendar');
    } on CalendarUnavailable catch (e) {
      await _handToDevice(meeting, e);
    } on SignInNeedsConsent catch (e) {
      // In words of its own rather than Microsoft's, which send the person
      // to Settings for the sign-in that is offered right here.
      setState(() {
        _notice = e.needsAdministrator
            ? "Microsoft has not allowed the app to use this account's "
                "calendar, and only the organisation's administrator can "
                "allow it. Sign in below: Microsoft's page will offer to "
                'send them the request. Once they approve, tap Send again.'
            : "Microsoft has not yet allowed the app to use this account's "
                'calendar. Sign in again to allow it; nothing cached is lost.';
        _offerConsent = true;
        _askAdministrator = e.needsAdministrator;
      });
    } catch (e) {
      // Every failure the calendars throw on purpose already carries a
      // sentence written for a person; the rest is kept whole for a report.
      setState(() => _problem = ProblemReport(
            doing: 'Creating a meeting',
            error: e,
            account: _account,
          ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The account has no calendar the app can reach, so the phone's calendar
  /// app takes the meeting, attendees and all, and invites them from there.
  Future<void> _handToDevice(MeetingDraft meeting, CalendarUnavailable why) async {
    final ok = await ref.read(deviceCalendarProvider).insertEvent(
          title: meeting.title,
          description: meeting.notes.isEmpty ? null : meeting.notes,
          location: meeting.location.isEmpty ? null : meeting.location,
          start: meeting.start,
          // Exclusive, which is how the calendar provider counts the end of
          // a whole day.
          end: meeting.allDay ? dayAfter(meeting.end) : meeting.end,
          allDay: meeting.allDay,
          attendees: [for (final a in meeting.attendees) a.email],
        );
    if (!mounted) return;
    if (ok) {
      _leave("Handed to your calendar app: this account's calendar cannot be "
          'reached from here.');
    } else {
      setState(() => _notice =
          '${why.message} There is no calendar app on this phone to hand it '
          'to either.');
    }
  }

  /// A sign-in that asks Microsoft for the calendar beside the mail, then
  /// the meeting again. The account keeps everything cached: this is the
  /// same sign-in again that Settings offers, brought to where it is needed.
  Future<void> _allowCalendar() async {
    final account = _account;
    if (account == null) return;
    final token = await MicrosoftSignInScreen.show(
      context,
      loginHint: account.emailAddress,
      scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.calendarScopes],
    );
    if (token == null || !mounted) return;
    setState(() {
      _sending = true;
      _notice = null;
      _offerConsent = false;
    });
    try {
      await ref
          .read(accountsProvider.notifier)
          .signInAgain(accountId: account.id, token: token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _problem = ProblemReport(
          doing: 'Signing in again to ${account.emailAddress}',
          error: e,
          account: account,
        );
      });
      return;
    }
    if (!mounted) return;
    await _send();
  }

  void _leave(String message) {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(message)));
  }

  /// Backing out of a half-written meeting. There is no draft to keep it
  /// in, so the question is only whether to lose it; an untouched screen
  /// asks nothing.
  Future<bool> _mayLeave() async {
    if (_untouched) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this meeting?'),
        content: const Text('Nothing has been sent.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep writing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final account = accounts.where((a) => a.id == _accountId).firstOrNull;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _mayLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('New meeting'),
          centerTitle: false,
          actions: [
            IconButton(
              tooltip: 'Send',
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            // As the compose screen has it: with one account there is
            // nothing to choose, and a menu with one entry is a puzzle.
            if (accounts.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(
                  children: [
                    SizedBox(width: 64, child: Text('From', style: muted)),
                    Expanded(
                      child: DropdownButton<String>(
                        key: const ValueKey('meeting-from-account'),
                        value: account?.id,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        style: theme.textTheme.bodyMedium,
                        items: [
                          for (final a in accounts)
                            DropdownMenuItem(
                              value: a.id,
                              child: Text(
                                a.emailAddress,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _sending
                            ? null
                            : (id) {
                                if (id == null) return;
                                setState(() => _accountId = id);
                              },
                      ),
                    ),
                  ],
                ),
              )
            else if (account != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'From ${account.emailAddress}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            HeaderField(
              key: const ValueKey('meeting-title'),
              label: 'Title',
              controller: _title,
              enabled: !_sending,
              // A meeting from a message has its title; the cursor is
              // better off with the people then.
              autofocus: widget.title.isEmpty,
            ),
            RecipientField(
              key: const ValueKey('meeting-attendees'),
              label: 'Attendees',
              controller: _attendees,
              enabled: !_sending,
              autofocus: widget.title.isNotEmpty,
            ),
            _WhenRow(
              label: 'Start',
              at: _start,
              allDay: _allDay,
              enabled: !_sending,
              keyPrefix: 'start',
              onDate: () => _pickDate(_start, _setStart),
              onTime: () => _pickTime(_start, _setStart),
            ),
            _WhenRow(
              label: 'End',
              at: _end,
              allDay: _allDay,
              enabled: !_sending,
              keyPrefix: 'end',
              onDate: () => _pickDate(_end, (at) => setState(() => _end = at)),
              onTime: () => _pickTime(_end, (at) => setState(() => _end = at)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  SizedBox(width: 64, child: Text('All day', style: muted)),
                  Switch(
                    value: _allDay,
                    onChanged: _sending
                        ? null
                        : (on) => setState(() => _allDay = on),
                  ),
                ],
              ),
            ),
            HeaderField(
              key: const ValueKey('meeting-location'),
              label: 'Location',
              controller: _location,
              enabled: !_sending,
            ),
            if (_invalid != null)
              Container(
                width: double.infinity,
                color: theme.colorScheme.errorContainer,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  _invalid!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            if (_notice != null)
              _Notice(
                _notice!,
                action: _offerConsent
                    ? FilledButton.tonal(
                        onPressed: _sending ? null : _allowCalendar,
                        child: Text(_askAdministrator
                            ? 'Ask the administrator'
                            : 'Allow the calendar'),
                      )
                    : null,
              ),
            if (_problem != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: ProblemView(problem: _problem!),
              ),
            const Divider(height: 1),
            Expanded(
              child: TextField(
                key: const ValueKey('meeting-notes'),
                controller: _notes,
                enabled: !_sending,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: theme.textTheme.bodyMedium,
                decoration: const InputDecoration(
                  hintText: 'Notes',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A day and, unless the meeting is a whole day, a time, each a button
/// that opens the picker for it.
class _WhenRow extends StatelessWidget {
  const _WhenRow({
    required this.label,
    required this.at,
    required this.allDay,
    required this.enabled,
    required this.keyPrefix,
    required this.onDate,
    required this.onTime,
  });

  final String label;
  final DateTime at;
  final bool allDay;
  final bool enabled;
  final String keyPrefix;
  final VoidCallback onDate;
  final VoidCallback onTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            key: ValueKey('$keyPrefix-date'),
            onPressed: enabled ? onDate : null,
            child: Text(formatDay(at)),
          ),
          if (!allDay)
            TextButton(
              key: ValueKey('$keyPrefix-time'),
              onPressed: enabled ? onTime : null,
              child: Text(formatClock(
                at,
                use24h: MediaQuery.alwaysUse24HourFormatOf(context),
              )),
            ),
        ],
      ),
    );
  }
}

/// A quiet band of explanation, distinct from the error band above it,
/// with the one thing to do about it beside the words when there is one.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 24),
              child: action,
            ),
        ],
      ),
    );
  }
}
