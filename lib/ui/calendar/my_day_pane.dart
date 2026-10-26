import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_event.dart';
import '../../domain/meeting_alerts.dart' show nextMeeting;
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_alert_providers.dart';
import '../messages/date_format.dart';
import 'calendar_screen.dart';
import 'next_meeting_bar.dart' show joinMeeting;

const _weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
  'Sunday',
];

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

/// Today's meetings beside the mail, New Outlook's My Day: in the folder
/// pane's place on a tablet, switched on and off from the bar over the
/// list, beside Hide folders. The next
/// meeting's Join at the top, each meeting's sheet a tap away, and the
/// whole calendar from the date. Tomorrow's meetings come after today's,
/// under a date of their own that opens the calendar on that day.
class MyDayPane extends ConsumerStatefulWidget {
  const MyDayPane({super.key});

  @override
  ConsumerState<MyDayPane> createState() => _MyDayPaneState();
}

class _MyDayPaneState extends ConsumerState<MyDayPane> {
  Timer? _ticking;

  @override
  void initState() {
    super.initState();
    // What is over and what is next moves on with the time.
    _ticking = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticking?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = ref.watch(meetingClockProvider)();
    final range = dayRange(now);
    final nextDay = dayRange(range.end);
    final load = ref.watch(calendarEventsProvider(range));
    final nextLoad = ref.watch(calendarEventsProvider(nextDay));
    final prefs = ref.watch(calendarPrefsProvider);
    final accounts = ref.watch(calendarAccountsProvider);
    final colours = {for (final a in accounts) a.id: Color(a.colorValue)};
    final events = shownEvents(load.value?.events ?? const [], prefs);
    final nextEvents = shownEvents(nextLoad.value?.events ?? const [], prefs);
    // Tomorrow's too, for the minutes before midnight.
    final next = nextMeeting([...events, ...nextEvents], now);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final today = range.start;
    final tomorrow = nextDay.start;

    /// One day's meetings, keyed '[name]:id', or a line saying it has none.
    List<Widget> meetings(
      AsyncValue<CalendarLoad> load,
      List<CalendarEvent> events, {
      required String name,
      required String none,
    }) =>
        [
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: load.isLoading || (load.value?.reading ?? false)
                  ? const Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Text(none, style: muted),
            ),
          for (final e in events)
            _MyDayEvent(
              tapKey: ValueKey('$name:${e.id}'),
              event: e,
              colour: colours[e.accountId] ?? theme.colorScheme.primary,
              over: !e.end.isAfter(now),
              next: identical(e, next),
              use24h: use24h,
              onTap: () => showEventDetails(
                context,
                ref,
                e,
                accounts.where((a) => a.id == e.accountId).firstOrNull,
              ),
            ),
        ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('my-day-date'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => CalendarScreen.open(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('My Day', style: theme.textTheme.labelMedium
                            ?.copyWith(color: theme.colorScheme.primary)),
                        Text(_dateOf(today),
                            style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('my-day-close'),
                tooltip: 'Show folders',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () =>
                    ref.read(myDayShownProvider.notifier).set(false),
              ),
            ],
          ),
        ),
        if (next?.joinUrl case final url?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: FilledButton.tonalIcon(
              key: const ValueKey('my-day-join'),
              icon: const Icon(Icons.videocam_outlined),
              label: Text(
                'Join ${_titleOf(next!)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: () => joinMeeting(url),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              ...meetings(load, events,
                  name: 'my-day-event', none: 'Nothing on today'),
              const Divider(height: 25, indent: 16, endIndent: 16),
              InkWell(
                key: const ValueKey('my-day-tomorrow-date'),
                onTap: () => CalendarScreen.open(context, day: tomorrow),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Tomorrow', style: theme.textTheme.labelMedium
                          ?.copyWith(color: theme.colorScheme.primary)),
                      Text(_dateOf(tomorrow),
                          style: theme.textTheme.titleSmall),
                    ],
                  ),
                ),
              ),
              ...meetings(nextLoad, nextEvents,
                  name: 'my-day-tomorrow', none: 'Nothing on tomorrow'),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Monday 26 October".
String _dateOf(DateTime day) =>
    '${_weekdayNames[day.weekday - 1]} ${day.day} ${_monthNames[day.month - 1]}';

String _titleOf(CalendarEvent e) =>
    e.title.trim().isEmpty ? '(No title)' : e.title.trim();

class _MyDayEvent extends StatelessWidget {
  const _MyDayEvent({
    required this.tapKey,
    required this.event,
    required this.colour,
    required this.over,
    required this.next,
    required this.use24h,
    required this.onTap,
  });

  /// Today's and tomorrow's apart: a meeting over midnight is in both.
  final Key tapKey;
  final CalendarEvent event;
  final Color colour;
  final bool over;
  final bool next;
  final bool use24h;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = event;
    final when = e.allDay
        ? 'All day'
        : '${formatClock(e.start, use24h: use24h)}–'
            '${formatClock(e.end, use24h: use24h)}';
    final place = e.location.trim().isNotEmpty
        ? e.location.trim()
        : e.joinUrl != null
            ? 'Online'
            : null;
    return Opacity(
      // What is over stays, faded, as the calendar shows a day gone by.
      opacity: over ? 0.5 : 1,
      child: InkWell(
        key: tapKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 36,
                decoration: BoxDecoration(
                  color: colour,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleOf(e),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: next ? FontWeight.w700 : FontWeight.w500,
                        decoration:
                            e.declined ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    Text(
                      [when, ?place].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
