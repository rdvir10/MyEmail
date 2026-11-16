import 'package:flutter/material.dart';

/// The corner of the calendar's grid that its + button stands over, from
/// the bottom right: the regular button's 56 dp and its 16 dp margin, and
/// the phone's own bars below and beside it, which it is lifted over.
/// Nothing where the screen has no + button. Day and Week scroll their
/// last hours clear of it, and the month's last box keeps its lines out
/// of it.
({double width, double height}) plusButtonCorner(BuildContext context) {
  if (Scaffold.maybeOf(context)?.hasFloatingActionButton != true) {
    return (width: 0, height: 0);
  }
  final padding = MediaQuery.paddingOf(context);
  const button = 56 + kFloatingActionButtonMargin;
  return (width: button + padding.right, height: button + padding.bottom);
}
