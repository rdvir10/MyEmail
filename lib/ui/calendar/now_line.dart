import 'package:flutter/material.dart';

import 'meeting_ticker.dart' show MeetingTicker;

// The present time on the hours of Day and Week: a red line across today,
// drawn under the meetings so it never crosses a title, and a mark where
// the hours meet the first day, which shows the time when a meeting covers
// the line. Both read the time from [NowClock], the grid's one
// [MeetingTicker] (the tick and the clock of the next meeting's "in 13
// min" over the mail), and only they are built again when the minute
// changes; nothing ticks once the grid has gone.

/// The grid's clock: one [MeetingTicker] over all its pages, handing the
/// time to the lines and marks below through a [NowScope]. [child] is the
/// same widget at every tick, so nothing under it is built again but what
/// reads the time.
class NowClock extends StatelessWidget {
  const NowClock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MeetingTicker(
        builder: (context, ref, now) => NowScope(now: now, child: child),
      );
}

/// The time on the hours, from the grid's [NowClock].
class NowScope extends InheritedWidget {
  const NowScope({super.key, required this.now, required super.child});

  final DateTime now;

  /// The time, or null where there is no clock above: no line then.
  static DateTime? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NowScope>()?.now;

  /// To the minute, as the line is drawn: a tick within the same minute
  /// moves nothing.
  @override
  bool updateShouldNotify(NowScope old) => _minute(old.now) != _minute(now);

  static DateTime _minute(DateTime t) {
    final local = t.toLocal();
    return DateTime(
        local.year, local.month, local.day, local.hour, local.minute);
  }
}

/// How far down a day [hourHeight] an hour tall [time] is, by the clock,
/// as the hours down the side are: on the days the clocks change, the
/// time since midnight is an hour more or less than that.
double _down(DateTime time, double hourHeight) {
  final t = time.toLocal();
  return (t.hour * 60 + t.minute) / 60 * hourHeight;
}

bool _on(DateTime time, DateTime day) {
  final t = time.toLocal();
  return t.year == day.year && t.month == day.month && t.day == day.day;
}

/// The line across [day]'s column, while it is today: a child of the
/// column's Stack, put before the meetings.
class NowLine extends StatelessWidget {
  const NowLine({super.key, required this.day, required this.hourHeight});

  final DateTime day;
  final double hourHeight;

  @override
  Widget build(BuildContext context) {
    final time = NowScope.of(context);
    if (time == null || !_on(time, day)) {
      return const Positioned.fill(child: SizedBox.shrink());
    }
    return Positioned(
      top: _down(time, hourHeight),
      left: 0,
      right: 0,
      height: 2,
      child: IgnorePointer(
        child: ColoredBox(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

/// The mark at the present time where the hours meet the first of [days],
/// [left] across, while one of them is today: a child of a Stack over the
/// hours and the days, put last, over the meetings.
class NowMark extends StatelessWidget {
  const NowMark({
    super.key,
    required this.days,
    required this.hourHeight,
    required this.left,
  });

  final List<DateTime> days;
  final double hourHeight;
  final double left;

  /// Across, the dot; it sits half on the hours' side of the line between
  /// them and the first day, in the room left there for it.
  static const size = 8.0;

  @override
  Widget build(BuildContext context) {
    final time = NowScope.of(context);
    if (time == null || !days.any((d) => _on(time, d))) {
      return const Positioned.fill(child: SizedBox.shrink());
    }
    return Positioned(
      top: _down(time, hourHeight) + 1 - size / 2,
      left: left - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('now-mark'),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
