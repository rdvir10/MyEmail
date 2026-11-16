import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar/sheet_calendar.dart';
import '../../domain/calendar_event.dart';
import '../../domain/meeting.dart' show Reminder;
import '../../domain/meeting_repeat.dart';
import '../../state/providers.dart';
import '../meetings/meeting_options.dart' show showAsLabel;

/// What a meeting's sheet says under its time beyond the when (calendar
/// idea #44): how it repeats, and the rest of what its calendar keeps of
/// it, its reminder, how it shows, private and its categories. Quietly,
/// and nothing for what a meeting has none of.

/// A reminder [minutes] before a meeting, in plain words: "Reminder 15
/// minutes before", "Reminder 1 hour before", "Reminder at the start". The
/// length in New meeting's words ([Reminder.labelFor]).
String reminderSaid(int minutes) => minutes <= 0
    ? 'Reminder at the start'
    : 'Reminder ${Reminder.labelFor(minutes)}';

/// [e]'s reminder, how it shows, private and its categories, in one line:
/// "Reminder 15 minutes before · Busy · Private · Sales". Each is left out
/// where it has none. [freeOrBusy] is a Google calendar's, which keeps
/// only whether the time is taken: a meeting answered maybe is busy there,
/// whatever the app draws it as. Neither the reminder nor how it would
/// show is said of one declined or cancelled, which takes no time and
/// which MyEmail does not remind of.
String meetingFacts(CalendarEvent e, {bool freeOrBusy = false}) => [
      if (!e.declined && !e.cancelled) ...[
        if (e.reminderMinutes case final m? when m >= 0) reminderSaid(m),
        showAsLabel(freeOrBusy && e.showAs != EventShowAs.free
            ? EventShowAs.busy
            : e.showAs),
      ],
      if (e.isPrivate) 'Private',
      for (final c in e.categories)
        if (c.trim().isNotEmpty) c.trim(),
    ].join(' · ');

/// How the series [CalendarEvent] is one meeting of repeats, asked of its
/// calendar as the sheet opens, and asked again the next time it does.
/// Null where it cannot be said: not asked (the meeting is on its own, or
/// the engine has no calendars), not answered (no signal), or a series
/// that repeats in a way the app does not name. Never an error.
final meetingRepeatProvider = FutureProvider.autoDispose
    .family<MeetingRepeat?, CalendarEvent>((ref, event) async {
  final engine = ref.watch(mailEngineProvider);
  if (event.seriesId == null || engine is! ReadsMeetingRepeat) return null;
  try {
    return await (engine as ReadsMeetingRepeat).meetingRepeat(event);
  } catch (e) {
    debugPrint('[myemail] how a series repeats was not read: $e');
    return null;
  }
});

/// The line under a meeting's time that says how it repeats, for one of a
/// series: "Every week on Tuesday, until 30 June 2027" once its calendar
/// has said, and "Repeats" until then, or where it cannot be said. Nothing
/// for a meeting on its own. [asks] is whether its calendar can be asked:
/// one the app reaches.
class MeetingRepeatLine extends ConsumerWidget {
  const MeetingRepeatLine({
    super.key,
    required this.event,
    required this.asks,
    this.style,
  });

  final CalendarEvent event;
  final bool asks;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (event.seriesId == null) return const SizedBox.shrink();
    final known = asks ? ref.watch(meetingRepeatProvider(event)).value : null;
    return Text(
      known?.describe() ?? 'Repeats',
      key: const ValueKey('event-repeat'),
      style: style,
    );
  }
}
