import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_event.dart';
import '../../domain/meeting_links.dart'
    show placeLine, placeLinkToOpen, placeNamed;
import '../../domain/text_direction.dart' show firstStrongDirection;
import '../../state/attachment_providers.dart' show fileBridgeProvider;
import '../../state/calendar_view_providers.dart';
import '../common/bottom_message.dart';
import '../messages/date_format.dart';

/// A meeting's details, or a day's meetings, as plain text to copy or to
/// hand to another app through Android's share sheet (calendar idea #48).
/// Nothing goes anywhere but where Ron sends it: the clipboard, or the app
/// he picks.

/// When [e] is, as its sheet says it: "Tue 17 Nov, 10:00–11:00", "All
/// day, Tue 17 Nov to Thu 19 Nov", on the phone's clock ([use24h]).
String meetingWhen(CalendarEvent e, {required bool use24h}) {
  String clock(DateTime t) => formatClock(t, use24h: use24h);
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  if (e.allDay) {
    final last = DateTime(e.end.year, e.end.month, e.end.day - 1);
    return sameDay(e.start, last) || !last.isAfter(e.start)
        ? 'All day, ${formatDay(e.start)}'
        : 'All day, ${formatDay(e.start)} to ${formatDay(last)}';
  }
  return sameDay(e.start, e.end)
      ? '${formatDay(e.start)}, ${clock(e.start)}–${clock(e.end)}'
      : '${formatDay(e.start)}, ${clock(e.start)} to '
          '${formatDay(e.end)}, ${clock(e.end)}';
}

/// [e]'s details for one meeting shared on purpose: its title, when, where,
/// and the link to join it, whole, a line each, nothing for what it has
/// none of. Its place as the sheet shows it, a link in it named; a place
/// that is nothing but a link to somewhere (a map's) is that link, since
/// it is all there is to say where.
String meetingText(CalendarEvent e, {required bool use24h}) {
  final title = e.title.trim();
  final place = placeLinkToOpen(e.location) != null
      ? e.location.trim()
      : placeNamed(e.location);
  return [
    title.isEmpty ? '(No title)' : title,
    meetingWhen(e, use24h: use24h),
    if (place.isNotEmpty) place,
    if (e.joinUrl case final join?) 'Join: $join',
  ].join('\n');
}

/// [day]'s meetings among [events] as a few lines of plain text: the day,
/// then a line for each meeting, the whole days first, with when and
/// where. A link in a place is named, never written out (a Zoom link's
/// passcode stays on the phone); a meeting held online with no place says
/// Online. What Ron will not be at, declined or cancelled, is left out, a
/// meeting on two calendars is said once, and a private one says only that
/// the time is taken, as its calendar shows it to others.
String dayText(
  DateTime day,
  Iterable<CalendarEvent> events, {
  required bool use24h,
}) {
  final from = DateTime(day.year, day.month, day.day);
  final to = DateTime(day.year, day.month, day.day + 1);
  String clock(DateTime t) => formatClock(t, use24h: use24h);
  String line(CalendarEvent e) {
    final before = e.start.isBefore(from), after = e.end.isAfter(to);
    final when = e.allDay || (before && after)
        ? 'All day'
        : before
            ? 'Until ${clock(e.end)}'
            : after
                ? 'From ${clock(e.start)}'
                : '${clock(e.start)}–${clock(e.end)}';
    if (e.isPrivate) return '$when  Private';
    final title = e.title.trim();
    return [
      '$when  ${title.isEmpty ? '(No title)' : title}',
      ?placeLine(e),
    ].join(' · ');
  }

  final said = <String>{};
  final lines = [
    for (final e in eventsOn(from, events))
      if (!e.declined &&
          !e.cancelled &&
          said.add('${e.title.trim().toLowerCase()}|${e.start}|${e.end}'))
        line(e),
  ];
  return [formatDay(from), if (lines.isEmpty) 'Nothing on.', ...lines]
      .join('\n');
}

void _say(ScaffoldMessengerState messenger, String text) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));

/// Copy details, on a meeting's sheet: [event]'s details on the
/// clipboard, as [meetingText] writes them.
Future<void> copyMeeting(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final text =
      meetingText(event, use24h: MediaQuery.alwaysUse24HourFormatOf(context));
  await Clipboard.setData(ClipboardData(text: text));
  _say(messenger, 'Details copied.');
}

/// Share, on a meeting's sheet: [event]'s details to the app Ron picks
/// from Android's share sheet, its title as the subject.
Future<void> shareMeeting(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final text =
      meetingText(event, use24h: MediaQuery.alwaysUse24HourFormatOf(context));
  try {
    await ref
        .read(fileBridgeProvider)
        .shareText(text, subject: event.title.trim());
  } catch (e) {
    debugPrint('[myemail] the share sheet did not open: $e');
    _say(messenger, 'Could not open the share sheet.');
  }
}

/// Share the day, on a meeting's sheet: the meetings of [event]'s day, as
/// the calendar shows them; see [showDayToShare].
Future<void> shareMeetingsDay(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
) =>
    showDayToShare(context, event.start);

/// [day]'s meetings as [dayText] writes them, shown as they will go, with
/// Copy and Share. What the calendar's own menu could offer as Share my
/// day too.
Future<void> showDayToShare(BuildContext context, DateTime day) {
  final messenger = ScaffoldMessenger.of(context);
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  return showDialog<void>(
    context: context,
    builder: (_) => _DayToShare(
      day: DateTime(day.year, day.month, day.day),
      use24h: use24h,
      messenger: messenger,
    ),
  );
}

class _DayToShare extends ConsumerWidget {
  const _DayToShare({
    required this.day,
    required this.use24h,
    required this.messenger,
  });

  final DateTime day;
  final bool use24h;
  final ScaffoldMessengerState messenger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The day as the calendar shows it: what the device kept at once, then
    // as its calendars were read again, with the calendars shown and any
    // change just made here.
    final load = ref.watch(calendarEventsProvider(
        (start: day, end: DateTime(day.year, day.month, day.day + 1))));
    final prefs = ref.watch(calendarPrefsProvider);
    final pending = ref.watch(calendarPendingProvider);
    final events = load.value?.events;
    final text = events == null
        ? null
        : dayText(day, shownEvents(withPending(events, pending), prefs),
            use24h: use24h);
    final navigator = Navigator.of(context);
    // Had now: the box is gone by the time the share sheet is asked for.
    final bridge = ref.read(fileBridgeProvider);
    return AlertDialog(
      title: Text(formatDay(day)),
      content: text == null
          ? const SizedBox(
              height: 48,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Each line read the way the app it goes to will read
                  // it: by its first letter, a Hebrew one from the right.
                  for (final line in text.split('\n').skip(1))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        line,
                        textDirection: firstStrongDirection(line),
                      ),
                    ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => navigator.pop(),
          child: const Text('Close'),
        ),
        TextButton(
          key: const ValueKey('day-copy'),
          onPressed: text == null
              ? null
              : () async {
                  navigator.pop();
                  await Clipboard.setData(ClipboardData(text: text));
                  _say(messenger, 'Day copied.');
                },
          child: const Text('Copy'),
        ),
        FilledButton(
          key: const ValueKey('day-share'),
          onPressed: text == null
              ? null
              : () async {
                  navigator.pop();
                  try {
                    await bridge.shareText(text, subject: formatDay(day));
                  } catch (e) {
                    debugPrint('[myemail] the share sheet did not open: $e');
                    _say(messenger, 'Could not open the share sheet.');
                  }
                },
          child: const Text('Share'),
        ),
      ],
    );
  }
}
