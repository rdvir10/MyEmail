import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/text_direction.dart';

/// What a meeting's block on the hours of Day and Week says, in the room
/// it has: only lines that fit whole. The title first, on as many lines
/// as fit, broken between words and ending in "…" where it does not all
/// fit; then the place, or "Online"; then the start time, which the hours
/// down the side say too. A block too short for a line of its letters
/// gets one line of slightly smaller ones. Its title and start time are
/// what a screen reader hears, whatever is shown.
class BlockText extends StatelessWidget {
  const BlockText({
    super.key,
    required this.title,
    required this.place,
    required this.time,
    required this.style,
  });

  final String title;

  /// The meeting's place, "Online" for one held online with none, or null.
  final String? place;

  /// When it starts, as the phone's clock writes it.
  final String time;
  final TextStyle style;

  /// The letters of a block too short for a line of [style]'s.
  static TextStyle smaller(TextStyle style) => style.copyWith(
        fontSize: (style.fontSize ?? 12) - 1,
        height: 1.2,
      );

  /// Above and below the words in a block.
  static const padding = EdgeInsets.symmetric(horizontal: 4, vertical: 2);

  /// The least height a block is drawn at, however short its meeting: a
  /// line of its smaller letters, and never under 24 dp, the least a tap
  /// target may be (WCAG 2.2's minimum). At the usual height of an hour a
  /// quarter-hour meeting is 14 dp; drawn at 24 it reads and takes a tap.
  /// The hours never draw it past half an hour's height, though: pinched
  /// small, an ordinary day of half hours keeps its layout.
  static double minHeight(BuildContext context, TextStyle style) {
    final line = _lineHeight(
      DefaultTextStyle.of(context).style.merge(smaller(style)),
      MediaQuery.textScalerOf(context),
    );
    return math.max(24, line + padding.vertical);
  }

  static double _lineHeight(TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$title\n$time',
        excludeSemantics: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final base = DefaultTextStyle.of(context).style.merge(style);
            final scaler = MediaQuery.textScalerOf(context);
            // A Hebrew title, or place, reads from the right, by its first
            // letter as the place link decides it. The block's lines share
            // one side, the title's: the place and the time keep their own
            // order there.
            final titleDirection = firstStrongDirection(title);
            final rightToLeft = titleDirection == TextDirection.rtl;
            final lines = blockLines(
              title: title,
              place: place,
              time: time,
              style: base,
              small: base.merge(smaller(style)),
              scaler: scaler,
              width: box.maxWidth,
              height: box.maxHeight,
              direction: titleDirection ?? Directionality.of(context),
            );
            Widget line(
              String words,
              TextStyle style,
              int maxLines, {
              TextDirection? direction,
              TextAlign? align,
            }) =>
                Text(
                  words,
                  style: style,
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                  textDirection: direction,
                  textAlign: align,
                );
            // Laid out as measured, clipped by the block: the sums can be
            // a hair over the room, never a line.
            return OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (lines.small)
                    line(title, base.merge(smaller(style)), 1,
                        direction: titleDirection)
                  else if (lines.title > 0)
                    line(title, base, lines.title, direction: titleDirection),
                  if (lines.place > 0)
                    line(place!, base, lines.place,
                        direction: firstStrongDirection(place!),
                        align: rightToLeft ? TextAlign.right : TextAlign.left),
                  if (lines.time)
                    line(time, base, 1,
                        align: rightToLeft ? TextAlign.right : null),
                ],
              ),
            );
          },
        ),
      );
}

/// How a block [width] by [height] (inside its padding) spends its lines:
/// how many on the title, whether in the smaller letters, how many on the
/// place, and whether the start time has one. In turn: the title, then a
/// line for the place, then one for the time where it fits whole (cut
/// short, it says less than the hours down the side); then whatever lines
/// are left go to what still waits, the rest of the place and then the
/// time even cut short, so no line is left empty while something waits.
@visibleForTesting
({int title, bool small, int place, bool time}) blockLines({
  required String title,
  required String? place,
  required String time,
  required TextStyle style,
  required TextStyle small,
  required TextScaler scaler,
  required double width,
  required double height,
  TextDirection direction = TextDirection.ltr,
}) {
  final painter = TextPainter(
    text: TextSpan(text: title, style: style),
    textDirection: direction,
    textScaler: scaler,
  )..layout(maxWidth: width);
  final metrics = painter.computeLineMetrics();
  final line =
      metrics.isEmpty ? painter.preferredLineHeight : metrics.first.height;
  final room = (height / line + 1e-6).floor();
  if (room == 0) {
    painter.dispose();
    final smallLine = BlockText._lineHeight(small, scaler);
    final fits = smallLine <= height + 1e-6;
    return (title: fits ? 1 : 0, small: fits, place: 0, time: false);
  }
  // Whole words: a line that would end inside a word is the title's last,
  // ended with "…" instead.
  final shown = math.min(_wholeWordLines(painter, title), room);
  var left = room - shown;
  // The place, broken between words as the title is.
  var placeWanted = 0;
  if (place != null) {
    painter
      ..text = TextSpan(text: place, style: style)
      ..textDirection = firstStrongDirection(place) ?? direction
      ..layout(maxWidth: width);
    placeWanted = _wholeWordLines(painter, place);
  }
  var placeLines = 0;
  if (placeWanted > 0 && left > 0) {
    placeLines = 1;
    left--;
  }
  painter
    ..text = TextSpan(text: time, style: style)
    ..textDirection = TextDirection.ltr
    ..layout();
  final timeFits = painter.width <= width + 1e-6;
  painter.dispose();
  var timeShown = left > 0 && timeFits;
  if (timeShown) left--;
  final more = math.min(left, placeWanted - placeLines);
  placeLines += more;
  left -= more;
  if (!timeShown && left > 0) timeShown = true;
  return (
    title: shown,
    small: false,
    place: placeLines,
    time: timeShown,
  );
}

/// How many lines of [text], laid out in [painter], to show for whole
/// words: all of them, or up to the first that ends inside a word (as a
/// word too long for the width is broken), which is then the last, ended
/// with "…".
int _wholeWordLines(TextPainter painter, String text) {
  final lines = painter.computeLineMetrics().length;
  final broken = _firstLineBrokenInWord(painter, text, lines);
  return broken == null ? lines : broken + 1;
}

final _wordLetter = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

/// The first of [painter]'s [lines] (but the last) that ends inside a word,
/// as a word too long for the width is broken, or null.
int? _firstLineBrokenInWord(TextPainter painter, String text, int lines) {
  var start = 0;
  for (var i = 0; i < lines - 1; i++) {
    final end = painter.getLineBoundary(TextPosition(offset: start)).end;
    if (end <= start || end >= text.length) return null;
    if (_wordLetter.hasMatch(text[end - 1]) &&
        _wordLetter.hasMatch(text[end])) {
      return i;
    }
    start = end;
    while (start < text.length && text[start].trim().isEmpty) {
      start++;
    }
  }
  return null;
}
