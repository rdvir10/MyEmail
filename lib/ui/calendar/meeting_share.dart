import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_event.dart';
import '../../domain/meeting_links.dart'
    show placeLine, placeLinkToOpen, placeNamed, throughSafeLinks;
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
/// that is nothing but links is the one to somewhere (a map's) that it
/// holds, since that is all there is to say where: see [_placeToSend].
String meetingText(CalendarEvent e, {required bool use24h}) {
  final title = e.title.trim();
  final place = _placeToSend(e.location);
  return [
    title.isEmpty ? '(No title)' : title,
    meetingWhen(e, use24h: use24h),
    if (place.isNotEmpty) place,
    if (e.joinUrl case final join?) 'Join: $join',
  ].join('\n');
}

/// What Copy details and Share say of [location]: as the sheet shows it,
/// a link in it named; or, for a place that is nothing but links, the one
/// to somewhere ([placeLinkToOpen]) alone, not a meeting's link beside it
/// with its passcode. One inside Microsoft's Safe Links goes as the link
/// it holds: the wrapper's address carries Ron's own address and his
/// organisation's. One that holds no single link to go by is named.
String _placeToSend(String location) {
  final open = placeLinkToOpen(location);
  if (open == null) return placeNamed(location);
  final host = open.host.toLowerCase();
  final wrapped = host == _safeLinks || host.endsWith('.$_safeLinks');
  final link = wrapped ? throughSafeLinks(open) : open;
  return link == null ? placeNamed(location) : '$link';
}

const _safeLinks = 'safelinks.protection.outlook.com';

/// [day]'s meetings among [events] as a few lines of plain text: the day,
/// then a line for each meeting, the whole days first, with when and
/// where. A link in a place or a title is named, never written out (a Zoom
/// link's passcode stays on the phone); a meeting held online with no
/// place says Online. What Ron will not be at, declined or cancelled, is
/// left out, a meeting on two calendars is said once (see [_sameMeeting]),
/// and a private one says only that the time is taken, as its calendar
/// shows it to others: one private on either calendar too.
String dayText(
  DateTime day,
  Iterable<CalendarEvent> events, {
  required bool use24h,
}) {
  final from = DateTime(day.year, day.month, day.day);
  final to = DateTime(day.year, day.month, day.day + 1);
  String clock(DateTime t) => formatClock(t, use24h: use24h);
  String line(_DayLine l) {
    final e = l.first;
    final before = e.start.isBefore(from), after = e.end.isAfter(to);
    final when = e.allDay || (before && after)
        ? 'All day'
        : before
            ? 'Until ${clock(e.end)}'
            : after
                ? 'From ${clock(e.start)}'
                : '${clock(e.start)}–${clock(e.end)}';
    if (l.private) return '$when  Private';
    // A title may hold a link too, a Zoom one with its passcode: named.
    final title = placeNamed(e.title);
    return [
      '$when  ${title.isEmpty ? '(No title)' : title}',
      ?placeLine(e),
    ].join(' · ');
  }

  final folded = <_DayLine>[];
  for (final e in eventsOn(from, events)) {
    if (e.declined || e.cancelled) continue;
    final same = folded.where((l) => _sameMeeting(l, e)).firstOrNull;
    if (same == null) {
      folded.add(_DayLine(e));
    } else {
      same.calendars.add(_calendarOf(e));
      same.private = same.private || e.isPrivate;
    }
  }
  final lines = [for (final l in folded) line(l)];
  return [formatDay(from), if (lines.isEmpty) 'Nothing on.', ...lines]
      .join('\n');
}

/// One line of a day's list: a meeting, and the calendars it is on.
class _DayLine {
  _DayLine(this.first)
      : calendars = {_calendarOf(first)},
        private = first.isPrivate;

  final CalendarEvent first;
  final Set<String> calendars;

  /// Private on any of them.
  bool private;
}

String _calendarOf(CalendarEvent e) => '${e.accountId}\u0000${e.calendarId}';

/// Whether [e] is [line]'s meeting on another calendar: Hadco's copy of an
/// invitation Gmail has too, say. The events carry no id of the meeting's
/// own across calendars, so it is the same title and the same times, on a
/// calendar the line does not have yet. Two meetings on one calendar are
/// two, whatever they share.
bool _sameMeeting(_DayLine line, CalendarEvent e) {
  final first = line.first;
  return !line.calendars.contains(_calendarOf(e)) &&
      first.start == e.start &&
      first.end == e.end &&
      first.title.trim().toLowerCase() == e.title.trim().toLowerCase();
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
    // Copy and Share wait for the calendars to have read the day: what the
    // device kept may lack an account's meetings until then.
    final reading = load.value?.reading ?? true;
    final ready = text != null && !reading;
    final lines = [
      for (final line in (text ?? '').split('\n').skip(1))
        // "Nothing on." is not said until it is known.
        if (!reading || line != 'Nothing on.') line,
    ];
    final theme = Theme.of(context);
    final navigator = Navigator.of(context);
    // Had now: the box is gone by the time the share sheet is asked for.
    final bridge = ref.read(fileBridgeProvider);
    return AlertDialog(
      title: Text(formatDay(day)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Each line read the way the app it goes to will read it: by
            // its first letter, a Hebrew one from the right.
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  line,
                  textDirection: firstStrongDirection(line),
                ),
              ),
            if (reading)
              Text(
                'Reading…',
                key: const ValueKey('day-reading'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
          onPressed: !ready
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
          onPressed: !ready
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
