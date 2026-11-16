import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/calendar_event.dart';

/// The words on a meeting drawn solid in its colour, which may be a
/// Google calendar's yellow as well as an account's dark blue: white, as
/// they always were, wherever white reaches 4.5 to 1 against [fill], and
/// black only where it does not, which then reaches more than 4.6.
Color inkOn(Color fill) {
  final onWhite = 1.05 / (fill.computeLuminance() + 0.05);
  return onWhite >= 4.5 ? Colors.white : Colors.black;
}

/// How a meeting is drawn on the hours of Day and Week and in the month:
/// solid in its colour, with black or white words; or, where it is
/// tentative, not answered, free or declined, faint: a tint of its colour
/// laid over the page, opaque so the grid's lines do not cross the words,
/// with the page's own words and an edge in its colour, dashed while the
/// answer is open (tentative, not answered) and solid otherwise.
@immutable
class MeetingLook {
  const MeetingLook._({
    required this.fill,
    required this.ink,
    required this.edge,
    required this.dashed,
  });

  /// [event] in [colour] on [scheme]'s page. A faint meeting's tint is
  /// [tint] of 255, or [declinedTint] for one declined.
  factory MeetingLook.of(
    CalendarEvent event,
    Color colour,
    ColorScheme scheme, {
    int tint = 40,
    int declinedTint = 20,
  }) {
    final faint = event.showAs == EventShowAs.free ||
        event.response == EventResponse.tentative ||
        event.response == EventResponse.notResponded ||
        event.declined;
    if (!faint) {
      return MeetingLook._(
        fill: colour,
        ink: inkOn(colour),
        edge: null,
        dashed: false,
      );
    }
    final open = !event.declined &&
        (event.response == EventResponse.tentative ||
            event.response == EventResponse.notResponded);
    return MeetingLook._(
      fill: Color.alphaBlend(
        colour.withAlpha(event.declined ? declinedTint : tint),
        scheme.surface,
      ),
      ink: scheme.onSurface,
      edge: open ? null : colour,
      dashed: open,
    );
  }

  final Color fill;
  final Color ink;

  /// A solid edge's colour, or null for none (a solid meeting, or a
  /// dashed one).
  final Color? edge;

  /// Drawn with a dashed edge in its colour.
  final bool dashed;
}

/// A rounded edge drawn in dashes: a meeting whose answer is still open,
/// tentative or not given, on the hours and in the month.
class DashedOutline extends CustomPainter {
  const DashedOutline({
    required this.colour,
    this.radius = 4,
    this.width = 1,
    this.dash = 4,
    this.gap = 3,
  });

  final Color colour;
  final double radius;
  final double width;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = Path()
      ..addRRect(RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(width / 2),
        Radius.circular(radius),
      ));
    final paint = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final metric in edge.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += dash + gap) {
        canvas.drawPath(
          metric.extractPath(at, math.min(at + dash, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(DashedOutline old) =>
      old.colour != colour ||
      old.radius != radius ||
      old.width != width ||
      old.dash != dash ||
      old.gap != gap;
}
