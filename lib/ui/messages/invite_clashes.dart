import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_event.dart';
import '../../domain/calendar_finding.dart';
import '../../domain/calendar_invite.dart';
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_alert_providers.dart' show dayRange;
import '../calendar/event_colours.dart';
import 'date_format.dart';

/// What else is on while an invitation's meeting would be (#34), under its
/// time on the card, as Outlook's "Conflicts with another event": "Clashes
/// with Weekly sync, 14:00–15:00", and that part of the day drawn with the
/// new meeting over it. Nothing where there is no clash, or no calendar to
/// look in.
class InviteClashes extends ConsumerWidget {
  const InviteClashes({super.key, required this.invite});

  final CalendarInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!invite.isRequest || invite.isAllDay || !invite.timeIsKnown) {
      return const SizedBox.shrink();
    }
    final accounts = ref.watch(calendarAccountsProvider);
    if (accounts.isEmpty) return const SizedBox.shrink();
    final start = invite.start.toLocal();
    final end = (invite.end ?? invite.start.add(const Duration(hours: 1)))
        .toLocal();
    final load = ref.watch(calendarEventsProvider(dayRange(start))).value;
    final clashes =
        clashesWith(load?.events ?? const [], start, end, title: invite.summary);
    if (clashes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => formatClock(t, use24h: use24h);
    String titleOf(CalendarEvent e) =>
        e.title.trim().isEmpty ? '(No title)' : e.title.trim();
    final first = clashes.first;
    final line = clashes.length == 1
        ? 'Clashes with ${titleOf(first)}, '
            '${clock(first.start)}–${clock(first.end)}'
        : 'Clashes with ${clashes.length} meetings: '
            '${clashes.map(titleOf).join(', ')}';
    final colours = EventColours(
      accounts: {for (final a in accounts) a.id: Color(a.colorValue)},
      calendars: load?.calendars ?? const {},
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  line,
                  key: const ValueKey('invite-clashes'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _DayStrip(
            start: start,
            end: end,
            clashes: clashes,
            colours: colours,
          ),
        ],
      ),
    );
  }
}

/// The part of the day around the meeting: what is on, in its colours, and
/// the meeting asked for drawn over it, outlined.
class _DayStrip extends StatelessWidget {
  const _DayStrip({
    required this.start,
    required this.end,
    required this.clashes,
    required this.colours,
  });

  final DateTime start;
  final DateTime end;
  final List<CalendarEvent> clashes;
  final EventColours colours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var from = start;
    var to = end;
    for (final e in clashes) {
      if (e.start.isBefore(from)) from = e.start;
      if (e.end.isAfter(to)) to = e.end;
    }
    // Half an hour either side, on the hour's half.
    from = DateTime(from.year, from.month, from.day, from.hour,
            from.minute < 30 ? 0 : 30)
        .subtract(const Duration(minutes: 30));
    to = DateTime(to.year, to.month, to.day, to.hour, 0)
        .add(Duration(minutes: to.minute == 0 ? 30 : 60 + 30));
    final span = math.max(1, to.difference(from).inMinutes);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    return SizedBox(
      key: const ValueKey('invite-clash-strip'),
      height: 40,
      child: LayoutBuilder(builder: (context, box) {
        double x(DateTime t) =>
            box.maxWidth * t.difference(from).inMinutes.clamp(0, span) / span;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            for (final e in clashes)
              Positioned(
                left: x(e.start),
                width: math.max(2, x(e.end) - x(e.start)),
                top: 4,
                bottom: 14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: (colours[e] ?? theme.colorScheme.primary)
                        .withAlpha(160),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            Positioned(
              left: x(start),
              width: math.max(2, x(end) - x(start)),
              top: 1,
              bottom: 11,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.error, width: 2),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Positioned(
              left: 4,
              bottom: 0,
              child: Text(formatClock(from, use24h: use24h),
                  style: theme.textTheme.labelSmall),
            ),
            Positioned(
              right: 4,
              bottom: 0,
              child: Text(formatClock(to, use24h: use24h),
                  style: theme.textTheme.labelSmall),
            ),
          ],
        );
      }),
    );
  }
}
