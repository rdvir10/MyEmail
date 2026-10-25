import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/found_dates.dart';

/// A plain-text message, its days and times dotted under as links, as the
/// HTML body underlines them: a tap on one makes a meeting then.
class DatedText extends StatefulWidget {
  const DatedText({
    super.key,
    required this.text,
    required this.dates,
    required this.onDate,
    this.style,
  });

  final String text;

  /// Where each date is in [text], as the finder read it.
  final List<FoundDate> dates;
  final void Function(DateTime at, bool allDay) onDate;
  final TextStyle? style;

  @override
  State<DatedText> createState() => _DatedTextState();
}

class _DatedTextState extends State<DatedText> {
  /// One per link, let go when the text or its dates change.
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    _letGo();
    super.dispose();
  }

  void _letGo() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  Widget build(BuildContext context) {
    _letGo();
    final text = widget.text;
    final dates = [
      for (final d in widget.dates)
        if (d.start >= 0 && d.end <= text.length && d.start < d.end) d,
    ]..sort((a, b) => a.start.compareTo(b.start));
    if (dates.isEmpty) return SelectableText(text, style: widget.style);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final d in dates) {
      if (d.start < at) continue;
      if (d.start > at) spans.add(TextSpan(text: text.substring(at, d.start)));
      final tap = TapGestureRecognizer()
        ..onTap = () => widget.onDate(d.at, !d.hasTime);
      _taps.add(tap);
      spans.add(TextSpan(
        text: text.substring(d.start, d.end),
        recognizer: tap,
        style: const TextStyle(
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
        ),
      ));
      at = d.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return SelectionArea(
      child: Text.rich(
        TextSpan(style: widget.style, children: spans),
        key: const ValueKey('dated-text'),
      ),
    );
  }
}
