import 'package:flutter/material.dart';

/// [child], a text button, moved towards the start by the button's own
/// padding there, so that its icon ([icon], a TextButton.icon) or its
/// words (a plain TextButton) begin where the words around it do, rather
/// than about 12 dp in (calendar idea #93). The padding stays round it, and
/// the ripple, the focus and the tap move with it.
class LinedUp extends StatelessWidget {
  const LinedUp({super.key, this.icon = true, required this.child});

  /// Whether the button is a TextButton.icon, whose padding shrinks with
  /// larger text faster than a plain TextButton's.
  final bool icon;
  final Widget child;

  /// The start of a text button's padding at [context]'s text size, as
  /// Material 3 pads it: 12 at the usual size, less as the text grows;
  /// TextButton.icon's with [icon].
  static double startOf(BuildContext context, {bool icon = true}) {
    final size = Theme.of(context).textTheme.labelLarge?.fontSize ?? 14;
    final scale = MediaQuery.textScalerOf(context).scale(size) / 14;
    final padding = ButtonStyleButton.scaledPadding(
      const EdgeInsetsDirectional.only(start: 12),
      EdgeInsetsDirectional.only(start: icon ? 4 : 8),
      const EdgeInsetsDirectional.only(start: 4),
      scale,
    );
    return padding is EdgeInsetsDirectional ? padding.start : 12;
  }

  @override
  Widget build(BuildContext context) {
    final start = startOf(context, icon: icon);
    return Transform.translate(
      offset: Offset(
          Directionality.of(context) == TextDirection.rtl ? start : -start,
          0),
      child: child,
    );
  }
}
