import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar/running_late.dart';
import '../../data/mail_engine.dart' show MailEngine;
import '../../domain/account.dart';
import '../../domain/calendar_change.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/draft.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mail_message.dart';
import '../../state/calendar_providers.dart' show deviceCalendarProvider;
import '../../state/calendar_view_providers.dart';
import '../../state/compose_providers.dart'
    show addressesLookValid, parseAddresses;
import '../../state/providers.dart';
import '../common/bottom_message.dart';
import '../compose/open_compose.dart';
import '../meetings/new_meeting_screen.dart';
import '../messages/date_format.dart';
import '../messages/invite_answers.dart';

/// What can be done with a meeting the calendar shows, as its sheet, its
/// block in Day and Week, and the rest of the calendar do it: answer it,
/// change, move, cancel or delete it, write to the people on it. Each takes
/// the calendar screen's own context and ref, which outlive the sheet.

Account? accountOf(WidgetRef ref, CalendarEvent event) => ref
    .read(accountsProvider)
    .value
    ?.where((a) => a.id == event.accountId)
    .firstOrNull;

/// Say [text] along the bottom, through [messenger], taken before any
/// wait: the sheet the action came from is gone by then.
void _tell(ScaffoldMessengerState messenger, String text) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));

String _why(Object e) => switch (e) {
      ReadableError(:final message) => message,
      ArgumentError(:final message) => '$message',
      _ => '$e',
    };

/// The first name of whoever [who] is, for a sentence.
String _name(MailAddress who) {
  final display = who.display.trim();
  return display.contains('@') ? display : display.split(RegExp(r'\s+')).first;
}

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// After an action, [event]'s days read again so what the views keep has
/// the change, then every view read again: those days from what was just
/// kept, the rest from the calendar. What was pending for it gives way by
/// itself once a view has it as it now is (see [withPending]). [moved] is
/// where it went, when it moved.
Future<void> settleCalendar(
  WidgetRef ref,
  CalendarEvent event, {
  CalendarEvent? moved,
}) async {
  final MailEngine engine;
  final CalendarRefresh refresh;
  try {
    engine = ref.read(mailEngineProvider);
    refresh = ref.read(calendarRefreshProvider.notifier);
  } on StateError {
    // The calendar was left meanwhile: it reads afresh when it opens.
    return;
  }
  final asked = DateTime.now();
  final starts = [event.start, ?moved?.start]..sort();
  final ends = [event.end, ?moved?.end]..sort();
  final from = _day(starts.first);
  final last = ends.last;
  final to = DateTime(last.year, last.month, last.day + 1);
  try {
    await engine.calendarEvents(event.accountId, from, to);
  } catch (_) {
    // The views read again below, and say what is wrong there.
  }
  refresh.since(asked);
}

/// Ask whether a change to [event], one meeting of a series, is for it or
/// for every meeting of the series. False for this one, true for all, null
/// if backed out of; false at once for a meeting on its own.
Future<bool?> askWholeSeries(
  BuildContext context,
  CalendarEvent event, {
  required String doing,
}) async {
  if (event.seriesId == null) return false;
  return showDialog<bool>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(doing),
      children: [
        SimpleDialogOption(
          key: const ValueKey('series-one'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('This meeting'),
        ),
        SimpleDialogOption(
          key: const ValueKey('series-all'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Every meeting in the series'),
        ),
      ],
    ),
  );
}

// --- answering ----------------------------------------------------------------

/// Answer [event] as [response], telling the organiser. With [asked], the
/// answer is asked for first, with a note or without a word to them.
Future<void> answerEvent(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
  InviteResponse response, {
  bool asked = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  var note = '';
  var send = true;
  var chosen = response;
  if (asked) {
    final answer = await askForNotedAnswer(
      context,
      canStayQuiet: true,
      initial: response,
    );
    if (answer == null || !context.mounted) return;
    chosen = answer.response;
    note = answer.note;
    send = answer.send;
  }
  final series = await askWholeSeries(context, event, doing: 'Answer');
  if (series == null || !context.mounted) return;
  try {
    await ref.read(mailEngineProvider).respondToEvent(
          event,
          chosen,
          note: note,
          send: send,
          wholeSeries: series,
        );
    final who = event.organizer;
    _tell(
      messenger,
      send && who != null
          ? '${chosen.word}. ${_name(who)} is told.'
          : '${chosen.word}. The organiser was not told.',
    );
    unawaited(settleCalendar(ref, event));
  } catch (e) {
    _tell(messenger, 'Could not answer: ${_why(e)}');
  }
}

/// Propose a new time for [event], someone else's meeting on a Microsoft
/// calendar: a tentative or declined answer with the time beside it.
Future<void> proposeForEvent(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final answer =
      await askForProposalAt(context, start: event.start, end: event.end);
  if (answer == null || !context.mounted) return;
  try {
    await ref.read(mailEngineProvider).respondToEvent(
          event,
          answer.response,
          note: answer.note,
          proposal: answer.proposal,
        );
    _tell(messenger, '${answer.response.word}, with a new time proposed. '
        'The organiser is told.');
    unawaited(settleCalendar(ref, event));
  } catch (e) {
    _tell(messenger, 'Could not propose it: ${_why(e)}');
  }
}

// --- changing -------------------------------------------------------------------

/// Edit [event], the account's own: its notes read in full, then the
/// meeting screen, filled in, whose Save sends the change.
Future<void> editEvent(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final series = await askWholeSeries(context, event, doing: 'Change');
  if (series == null || !context.mounted) return;
  final engine = ref.read(mailEngineProvider);
  final EventNotes notes;
  try {
    notes = await _withSpinner(
      context,
      engine.eventNotes(event, wholeSeries: series),
    );
  } catch (e) {
    _tell(messenger, 'Could not open it: ${_why(e)}');
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NewMeetingScreen(
        accountId: event.accountId,
        editing: EventEdit(event: event, notes: notes, wholeSeries: series),
      ),
    ),
  );
}

/// [event], the account's own, moved to [start]..[end] by dragging it:
/// asked first where others are on it, since they are sent the new time.
/// Shown there at once; put back if the calendar refuses.
Future<void> moveEvent(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
  DateTime start,
  DateTime end,
) async {
  final account = accountOf(ref, event);
  if (account == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final others = hasOthers(event, account.emailAddress);
  if (others) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move the meeting?'),
        content: Text(
          '${event.title} moves to ${formatDay(start)}, '
          '${formatClock(start, use24h: use24h)}–'
          '${formatClock(end, use24h: use24h)}. Everyone on it is sent the '
          'new time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('move-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move it'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
  }
  final moved = event.copyWith(start: start, end: end);
  final pending = ref.read(calendarPendingProvider.notifier);
  final engine = ref.read(mailEngineProvider);
  final device = ref.read(deviceCalendarProvider);
  pending.moved(event, moved);
  String? zone;
  try {
    zone = await device.timeZoneId();
  } catch (_) {
    // Then the times go as UTC, which every calendar reads.
  }
  try {
    await engine.updateEvent(
          event,
          EventChange(
            start: start,
            end: end,
            allDay: event.allDay,
            timeZone: zone,
          ),
        );
    _tell(messenger,
        others ? 'Moved. Everyone on it is sent the new time.' : 'Moved.');
    unawaited(settleCalendar(ref, event, moved: moved));
  } catch (e) {
    pending.settle(event);
    _tell(messenger, 'Could not move it: ${_why(e)}');
  }
}

/// Cancel [event], the account's own with others on it, asked first, with
/// a note to them where the calendar sends one; or delete it, where nobody
/// else is on it, at once with Undo; or for someone else's meeting,
/// decline it and take it off, asked first.
Future<void> cancelOrDeleteEvent(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final account = accountOf(ref, event);
  if (account == null) return;
  final own = isOwnEvent(event);
  final others = hasOthers(event, account.emailAddress);
  final engine = ref.read(mailEngineProvider);
  final pending = ref.read(calendarPendingProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  if (own && !others) {
    final series = await askWholeSeries(context, event, doing: 'Delete');
    if (series == null || !context.mounted) return;
    await _deleteWithUndo(context, ref, event, wholeSeries: series);
    return;
  }
  final series = await askWholeSeries(
    context,
    event,
    doing: own ? 'Cancel' : 'Decline and remove',
  );
  if (series == null || !context.mounted) return;
  final words = await showDialog<String>(
    context: context,
    builder: (_) => _CancelDialog(
      event: event,
      own: own,
      withNote: own && account.provider == MailProvider.outlook,
    ),
  );
  if (words == null || !context.mounted) return;
  pending.hide(event);
  try {
    if (own) {
      await engine.cancelEvent(event, note: words, wholeSeries: series);
    } else {
      await engine.removeEvent(event, wholeSeries: series);
    }
    _tell(messenger, own
        ? 'Cancelled. Everyone on it is told.'
        : 'Declined and taken off your calendar.');
    unawaited(settleCalendar(ref, event));
  } catch (e) {
    pending.settle(event);
    _tell(messenger, own
        ? 'Could not cancel it: ${_why(e)}'
        : 'Could not remove it: ${_why(e)}');
  }
}

/// An appointment, with nobody else on it, off the calendar at once, and
/// gone for good once Undo has had its moment.
Future<void> _deleteWithUndo(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event, {
  required bool wholeSeries,
}) async {
  final pending = ref.read(calendarPendingProvider.notifier);
  final engine = ref.read(mailEngineProvider);
  pending.hide(event);
  var undone = false;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  final shown = messenger.showSnackBar(SnackBar(
    duration: kBottomMessage,
    persist: false,
    content: const Text('Deleted.'),
    action: SnackBarAction(
      key: const ValueKey('delete-undo'),
      label: 'Undo',
      onPressed: () {
        undone = true;
        pending.settle(event);
      },
    ),
  ));
  await shown.closed;
  if (undone) return;
  try {
    await engine.removeEvent(event, wholeSeries: wholeSeries);
    unawaited(settleCalendar(ref, event));
  } catch (e) {
    pending.settle(event);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: kBottomMessage,
        content: Text('Could not delete it: ${_why(e)}'),
      ));
  }
}

// --- writing to the people on it ----------------------------------------------

/// A new message to everyone on [event] (or, with [notAnsweredOnly], to
/// those who have not answered), from its account, its title the subject.
Future<void> emailEveryone(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event, {
  bool notAnsweredOnly = false,
}) async {
  final account = accountOf(ref, event);
  if (account == null) return;
  final to = notAnsweredOnly
      ? notAnswered(event, account.emailAddress)
      : everyoneOn(event, account.emailAddress);
  await openCompose(
    context,
    ref,
    kind: ComposeKind.newMessage,
    accountId: account.id,
    to: to,
    subject: event.title,
  );
}

/// Tell them [event] starts late for you: a short message, sent straight
/// away, to its organiser, or to everyone on it when it is yours.
Future<void> runningLate(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final account = accountOf(ref, event);
  if (account == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final minutes = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Running late'),
      children: [
        for (final m in lateBy)
          SimpleDialogOption(
            key: ValueKey('late-$m'),
            onPressed: () => Navigator.of(context).pop(m),
            child: Text('About $m minutes'),
          ),
      ],
    ),
  );
  if (minutes == null || !context.mounted) return;
  final own = isOwnEvent(event);
  final draft = runningLateDraft(
    event,
    ownEmail: account.emailAddress,
    minutes: minutes,
  );
  if (draft == null) {
    _tell(messenger, 'There is nobody on it to tell.');
    return;
  }
  final to = draft.to;
  try {
    await ref.read(mailEngineProvider).sendDraft(draft);
    _tell(messenger, own || to.length > 1
        ? 'Told them you are running $minutes minutes late.'
        : 'Told ${_name(to.single)} you are running $minutes minutes late.');
  } catch (e) {
    _tell(messenger, 'Could not send it: ${_why(e)}');
  }
}

/// Add people to [event], the account's own, so only they are sent the
/// invitation; or forward it, someone else's on a Microsoft calendar,
/// which tells its organiser.
Future<void> invitePeople(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final account = accountOf(ref, event);
  if (account == null) return;
  final own = isOwnEvent(event);
  final messenger = ScaffoldMessenger.of(context);
  final people = await showDialog<List<MailAddress>>(
    context: context,
    builder: (_) => _InviteDialog(own: own),
  );
  if (people == null || people.isEmpty || !context.mounted) return;
  final engine = ref.read(mailEngineProvider);
  try {
    if (own) {
      final had = [
        for (final a in event.attendees)
          if (a.response != EventResponse.organizer) a.address,
      ];
      final known = {for (final a in had) a.email.trim().toLowerCase()};
      await engine.updateEvent(
        event,
        EventChange(attendees: [
          ...had,
          for (final a in people)
            if (known.add(a.email.trim().toLowerCase())) a,
        ]),
      );
      _tell(messenger, people.length == 1
          ? 'Invited ${_name(people.single)}.'
          : 'Invited ${people.length} people.');
      unawaited(settleCalendar(ref, event));
    } else {
      await engine.forwardEvent(event, people);
      _tell(messenger, 'Forwarded. The organiser is told.');
    }
  } catch (e) {
    _tell(messenger, own
        ? 'Could not invite them: ${_why(e)}'
        : 'Could not forward it: ${_why(e)}');
  }
}

/// The meeting screen, filled in from [event] with everything but the
/// day: the same time on the next day it can be, and its notes.
Future<void> duplicateEvent(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final account = accountOf(ref, event);
  final own = account?.emailAddress.trim().toLowerCase() ?? '';
  final now = DateTime.now();
  var start = DateTime(now.year, now.month, now.day, event.start.hour,
      event.start.minute);
  if (!start.isAfter(now)) {
    start = DateTime(
        start.year, start.month, start.day + 1, start.hour, start.minute);
  }
  if (event.allDay) start = DateTime(now.year, now.month, now.day + 1);
  var notes = event.preview;
  try {
    notes = (await ref.read(mailEngineProvider).eventNotes(event)).text;
  } catch (_) {
    // The first lines, then: the calendar could not be asked for more.
  }
  if (!context.mounted) return;
  await openNewMeeting(
    context,
    ref,
    accountId: event.accountId,
    title: event.title,
    notes: notes,
    location: event.location,
    attendees: everyoneOn(event, own),
    start: start,
    length: event.end.difference(event.start),
    allDay: event.allDay,
  );
}

/// [work], with a spinner over the screen while it runs.
Future<T> _withSpinner<T>(BuildContext context, Future<T> work) async {
  final navigator = Navigator.of(context);
  var shown = true;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  ).then((_) => shown = false));
  try {
    return await work;
  } finally {
    if (shown) navigator.pop();
  }
}

/// Cancel or decline-and-remove, asked: the note to everyone, where the
/// calendar sends one, or null if backed out of. Its own state, so the note
/// outlives the dialog's closing.
class _CancelDialog extends StatefulWidget {
  const _CancelDialog({
    required this.event,
    required this.own,
    required this.withNote,
  });

  final CalendarEvent event;
  final bool own;
  final bool withNote;

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final who = e.organizer == null ? 'The organiser' : _name(e.organizer!);
    return AlertDialog(
      title: Text(widget.own ? 'Cancel the meeting?' : 'Decline and remove it?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.own
                ? 'Everyone on ${e.title} is sent the cancellation.'
                : '$who is told you declined, and it comes off your calendar.'),
            if (widget.withNote) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('cancel-note'),
                controller: _note,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'A note to them',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep it'),
        ),
        FilledButton(
          key: const ValueKey('cancel-go'),
          onPressed: () => Navigator.of(context).pop(_note.text),
          child: Text(widget.own ? 'Cancel meeting' : 'Decline and remove'),
        ),
      ],
    );
  }
}

/// The people to invite, or to forward an invitation to; null if backed
/// out of.
class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.own});

  final bool own;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _field = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _go() {
    final found = parseAddresses(_field.text);
    if (found.isEmpty || !addressesLookValid(found)) {
      setState(() => _problem = 'Those do not look like addresses.');
      return;
    }
    Navigator.of(context).pop(found);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.own ? 'Invite people' : 'Forward the invitation'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.own
                  ? 'Only the people you add are sent the invitation.'
                  : 'They are sent the invitation, and the organiser is told.'),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('invite-addresses'),
                controller: _field,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                onSubmitted: (_) => _go(),
                decoration: InputDecoration(
                  labelText: 'Addresses',
                  hintText: 'dana@example.com, yossi@example.com',
                  errorText: _problem,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('invite-go'),
            onPressed: _go,
            child: Text(widget.own ? 'Invite' : 'Forward'),
          ),
        ],
      );
}
