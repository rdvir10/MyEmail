import 'package:flutter/material.dart';

/// The calendar's title, the month and year it is on, a tap from a month to
/// pick a day from (calendar idea #88): the longest of [forms] that fits
/// the room the bar's buttons leave it. On a tablet that is always the
/// first, "November 2026"; on a phone "Nov 2026", and at the largest text,
/// where even that has no room, "Nov".
class CalendarTitle extends StatelessWidget {
  const CalendarTitle({super.key, required this.forms, required this.onTap});

  /// Longest first. Where none fits, the last, cut.
  final List<String> forms;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          // A tap's height, though the words take less.
          constraints:
              const BoxConstraints(minHeight: kMinInteractiveDimension),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, box) => Text(
                      _fitting(context, box.maxWidth),
                      // Said whole, however short it is drawn.
                      semanticsLabel: forms.first,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
      );

  /// The first of [forms] whose words fit [width], in the bar's own
  /// letters at the text size in force, and bold where the phone's Bold
  /// text has every Text drawn bold.
  String _fitting(BuildContext context, double width) {
    var style = DefaultTextStyle.of(context).style;
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    for (final form in forms) {
      final painter = TextPainter(
        text: TextSpan(text: form, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final fits = painter.width <= width;
      painter.dispose();
      if (fits) return form;
    }
    return forms.last;
  }
}
