import 'package:flutter/material.dart';

import '../../domain/clock_text.dart';
import '../../domain/time_zones.dart' show wallClockIn;

/// An hour as the hours down the side of Day and Week write it: "10 AM"
/// on a 12-hour clock, the short form the phone's own calendar uses, so
/// the column stays narrow; "10:00" on a 24-hour one. A second zone's hour
/// that is not on the hour keeps its minutes: "8:30 PM".
String hourLabel(DateTime time, {required bool use24h}) {
  final t = time.toLocal();
  if (use24h || t.minute != 0) return formatClock(t, use24h: use24h);
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// The column of hours down the side of Day and Week, measured: as wide as
/// its widest label needs at the text size in force, "All day" among them,
/// with the second zone's hours beside the phone's where there is one.
@immutable
class HourScale {
  const HourScale._({
    required this.own,
    required this.second,
    required this.width,
    required this.lineHeight,
    required this.allDayWidth,
  });

  /// Room before the labels, between a second zone's and the phone's, and
  /// after the phone's, before the first day: enough there for the mark
  /// at the present time, which sits on the line between the two.
  static const start = 4.0;
  static const between = 8.0;
  static const end = 6.0;

  /// The fold arrow beside "All day", and the gap after it.
  static const arrow = 14.0;
  static const arrowGap = 2.0;

  /// The words over the all-day row.
  static const allDay = 'All day';

  /// Each hour's label, 1 to 23, by the phone's clock and by the second
  /// zone's (empty where there is none).
  final List<String> own;
  final List<String> second;

  /// The column's width, and the height of one label.
  final double width;
  final double lineHeight;

  /// How wide "All day" is written.
  final double allDayWidth;

  /// Whether the fold arrow fits beside "All day" on its line; where it
  /// does not, it goes under the words.
  bool get arrowBeside =>
      start + arrow + arrowGap + allDayWidth + end <= width + 0.01;

  /// How far the first hour sits below the top of the hours, so that the
  /// label on the line at the top of the screen shows whole: half a label.
  double get inset => (lineHeight / 2).ceilToDouble();

  static HourScale measure({
    required TextStyle style,
    required TextScaler scaler,
    required bool use24h,
    required DateTime day,
    String? zone,
  }) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    );
    double widthOf(String words) {
      painter.text = TextSpan(text: words, style: style);
      painter.layout();
      return painter.width;
    }

    final own = [
      for (var h = 1; h < 24; h++)
        hourLabel(DateTime(2000, 1, 1, h), use24h: use24h),
    ];
    final second = [
      if (zone != null)
        for (var h = 1; h < 24; h++)
          hourLabel(
            wallClockIn(DateTime(day.year, day.month, day.day, h), zone),
            use24h: use24h,
          ),
    ];
    double widest(List<String> labels) {
      var most = 0.0;
      for (final label in labels) {
        final width = widthOf(label);
        if (width > most) most = width;
      }
      return most;
    }

    final ownWidth = widest(own);
    final labels = second.isEmpty
        ? ownWidth
        : widest(second) + between + ownWidth;
    final allDayWidth = widthOf(allDay);
    final lineHeight = painter.preferredLineHeight;
    painter.dispose();
    final words = allDayWidth > labels ? allDayWidth : labels;
    return HourScale._(
      own: own,
      second: second,
      width: (start + words + end).ceilToDouble(),
      lineHeight: lineHeight,
      allDayWidth: allDayWidth,
    );
  }
}
