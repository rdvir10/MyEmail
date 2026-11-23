import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/calendar_event.dart';
import '../../domain/text_direction.dart' show firstStrongDirection;
import '../messages/date_format.dart' show formatClock;

/// Parts of the Agenda's row (calendar_screen.dart's `_AgendaRow`), which
/// the list of meetings waiting for an answer draws too: how wide its
/// times are, what is under its title, and its colour's bar when faint
/// (calendar idea #90).

/// The least the times are given: what they always had, so that on a
/// 24-hour clock at the usual text size the row looks as it did.
const _leastTimes = 64.0;

/// Between the widest time and the colour's bar.
const _clear = 8.0;

/// The colour's bar, and the room between it and the title.
const _bar = 4.0;
const _barToTitle = 12.0;

/// What a row is padded by at its start.
const agendaRowInset = 16.0;

final _widths = <Object, double>{};

/// How wide the Agenda's times are: the widest a time can be on this
/// phone's clock, at the text size in force, and a little room clear of the
/// colour's bar; never less than the 64 dp they always had. "10:00 AM"
/// filled those 64 to the bar, and at text size 1.3 each time wrapped onto
/// two lines. The same for every row, so that the bars line up.
double agendaTimesWidth(BuildContext context) {
  final theme = Theme.of(context);
  final first = theme.textTheme.bodyMedium;
  final second = theme.textTheme.bodySmall;
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  // Kept by what decides it, compared whole: a hash alone could match
  // another text size's.
  final key = (first, second, use24h, scaler, direction);
  final known = _widths[key];
  if (known != null) return known;

  double widest(TextStyle? style, Iterable<String> words) {
    var most = 0.0;
    for (final word in words) {
      final painter = TextPainter(
        text: TextSpan(text: word, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      most = math.max(most, painter.width);
      painter.dispose();
    }
    return most;
  }

  // The times with the most to them: two-figure hours, morning and night.
  final clocks = [
    for (final hour in const [0, 10, 11, 12, 20, 22, 23])
      for (final minute in const [0, 58])
        formatClock(DateTime(2000, 1, 1, hour, minute), use24h: use24h),
  ];
  final width = math.max(
    _leastTimes,
    math.max(
          widest(first, [...clocks, 'All day', 'Until', 'Now']),
          widest(second, [...clocks, '…']),
        ) +
        _clear,
  );
  if (_widths.length > 16) _widths.clear();
  return _widths[key] = width;
}

/// Where a row's title starts, from the row's edge: past its times and its
/// colour's bar. What the waiting list lines its answers up with.
double agendaTitleIndent(BuildContext context) =>
    agendaRowInset + agendaTimesWidth(context) + _bar + _barToTitle;

/// The room from a row's times to its title: the bar, and the room after.
const agendaBarAndRoom = _bar + _barToTitle;

/// Whether [e] is drawn pale in a list, as taking none of Ron's time: shown
/// as free (a holiday, a birthday, someone's day off) or declined. The
/// Agenda's bar, My Day's, the month's dots on a phone and the calendar
/// widget's colour.
bool paleInLists(CalendarEvent e) =>
    e.showAs == EventShowAs.free || e.declined;

/// A free or declined meeting's bar: its colour, faint. On the light page
/// that is the colour thinned over the page; on the dark page the same
/// thinning all but vanished, so there it is thinned over the theme's grey
/// instead: muted, and still seen.
Color agendaFaintBar(Color colour, ThemeData theme) =>
    theme.brightness == Brightness.dark
        ? Color.alphaBlend(colour.withAlpha(110), theme.colorScheme.outline)
        : colour.withAlpha(110);

/// Under a meeting's title in the Agenda: where it is, and how you
/// answered. The place gives way, cut short with "…"; the answer never
/// does, and where the two cannot share the line, the answer has a line of
/// its own. Read out as one line, as it was written before.
///
/// The line keeps to the side its title reads from ([reads], by the
/// title's first letter, #100): under a Hebrew title it starts at the
/// right, the place first and the answer after it, to its left. The place
/// is laid out by its own first letter, and the answer, the app's own
/// words, in the screen's.
class AgendaWhere extends StatelessWidget {
  const AgendaWhere({
    super.key,
    required this.place,
    required this.answer,
    this.reads,
    this.style,
  });

  final String place;
  final String answer;

  /// Which way the row reads: its title's. Null for the screen's own.
  final TextDirection? reads;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final screen = Directionality.of(context);
    final side = reads ?? screen;
    final align = side == TextDirection.rtl ? TextAlign.right : TextAlign.left;
    final placeReads = firstStrongDirection(place);
    // As wide as what is drawn of it, "…" and all, so that the answer
    // follows close.
    Text where() => Text(place,
        textDirection: placeReads,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textWidthBasis: TextWidthBasis.longestLine,
        style: style);
    if (answer.isEmpty) {
      // On its own, from the title's side (#100).
      return SizedBox(
        width: double.infinity,
        child: Text(place,
            textDirection: placeReads,
            textAlign: align,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style),
      );
    }
    if (place.isEmpty) {
      return SizedBox(
        width: double.infinity,
        child: Text(answer,
            textDirection: screen, textAlign: align, style: style),
      );
    }
    // After the place in the row's own way: to its right, or under a
    // Hebrew title to its left, the dot between them either way.
    final tail = side == TextDirection.rtl ? '$answer · ' : ' · $answer';
    return Semantics(
      label: '$place · $answer',
      excludeSemantics: true,
      child: LayoutBuilder(builder: (context, box) {
        double width(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: screen,
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final w = painter.width;
          painter.dispose();
          return w;
        }

        // On one line while the place keeps a fair share of it, or all of
        // itself.
        final room = box.maxWidth - width(tail);
        if (room >= math.min(width(place), box.maxWidth / 3)) {
          return Row(
            textDirection: side,
            children: [
              Flexible(child: where()),
              Text(tail,
                  textDirection: screen,
                  maxLines: 1,
                  softWrap: false,
                  style: style),
            ],
          );
        }
        return Column(
          textDirection: side,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            where(),
            Text(answer,
                textDirection: screen, textAlign: align, style: style),
          ],
        );
      }),
    );
  }
}
