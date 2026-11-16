import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/text_direction.dart';
import '../../domain/text_links.dart';
import '../messages/html_body_view.dart' show openExternally;
import 'tap_target.dart';

/// Plain text with what it links to a tap away (#43), as a message's links
/// are: a web address opens in the browser and a phone number in the
/// dialler, each through the gate a message's links go through
/// ([openExternally]), and an email address is a new message ([onEmail]).
/// Hebrew text reads from the right. With [foldAfter], text longer than
/// that many lines is folded to them, under Show more.
class LinkedText extends StatefulWidget {
  const LinkedText(
    this.text, {
    super.key,
    this.links = const [],
    this.style,
    this.foldAfter,
    this.onEmail,
  });

  final String text;

  /// Links the text has as words, a page's named links, where they are in
  /// it: each its words a tap from its address, before any link found in
  /// the text itself.
  final List<TextLink> links;
  final TextStyle? style;
  final int? foldAfter;

  /// A new message to an address tapped; null hands it to Android as a
  /// mailto: link.
  final void Function(String address)? onEmail;

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  /// One per link, let go of when the text is built again.
  final List<TapGestureRecognizer> _taps = [];

  /// Unfolded, with Show more.
  bool _open = false;

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

  void _follow(TextLink link) {
    final onEmail = widget.onEmail;
    if (link.kind == TextLinkKind.email && onEmail != null) {
      onEmail(link.target.path);
    } else {
      openExternally(link.target);
    }
  }

  TextSpan _span(BuildContext context) {
    _letGo();
    final scheme = Theme.of(context).colorScheme;
    final linked = TextStyle(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary,
    );
    final text = widget.text;
    final named = [
      for (final l in widget.links)
        if (l.start >= 0 && l.start < l.end && l.end <= text.length) l,
    ];
    final links = [
      ...named,
      for (final l in linksInText(text))
        if (!named.any((n) => l.start < n.end && n.start < l.end)) l,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final spans = <InlineSpan>[];
    var at = 0;
    for (final link in links) {
      if (link.start < at) continue;
      if (link.start > at) {
        spans.add(TextSpan(text: text.substring(at, link.start)));
      }
      final tap = TapGestureRecognizer()..onTap = () => _follow(link);
      _taps.add(tap);
      spans.add(TextSpan(
        text: text.substring(link.start, link.end),
        style: linked,
        recognizer: tap,
      ));
      at = link.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    // The style laid out to measure the fold is the one drawn.
    return TextSpan(
      style: DefaultTextStyle.of(context).style.merge(widget.style),
      children: spans,
    );
  }

  @override
  Widget build(BuildContext context) {
    final span = _span(context);
    final direction =
        firstStrongDirection(widget.text) ?? Directionality.of(context);
    final fold = widget.foldAfter;
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    return LayoutBuilder(builder: (context, box) {
      var long = false;
      if (fold != null && box.maxWidth.isFinite) {
        final painter = TextPainter(
          text: span,
          textDirection: direction,
          textScaler: scaler,
          maxLines: fold,
          locale: locale,
        )..layout(maxWidth: box.maxWidth);
        long = painter.didExceedMaxLines;
        painter.dispose();
      }
      final folded = long && !_open;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectionArea(
            child: Text.rich(
              span,
              key: const ValueKey('linked-text'),
              textDirection: direction,
              maxLines: folded ? fold : null,
              overflow: folded ? TextOverflow.ellipsis : null,
            ),
          ),
          if (long)
            Align(
              alignment: AlignmentDirectional.centerStart,
              // 48 to tap (#90), drawn as before.
              child: TapTarget(
                child: TextButton(
                  key: const ValueKey('linked-text-more'),
                  onPressed: () => setState(() => _open = !_open),
                  child: Text(_open ? 'Show less' : 'Show more'),
                ),
              ),
            ),
        ],
      );
    });
  }
}
