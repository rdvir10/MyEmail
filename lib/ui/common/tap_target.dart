import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// [child], a button as the app's compact look draws it, answering a tap
/// over at least 48 dp of height, as Android asks (calendar idea #90).
///
/// The compact density (theme/app_theme.dart) leaves a text, outlined or
/// filled button 40 dp to tap. This grows only the area that answers: the
/// button is drawn as it was, in the middle, and a tap above or below it
/// is a tap on it, at that point across, as Material's own padding round a
/// button sends one to it. Nothing about how it looks changes; what is
/// round it moves up to 4 dp further off.
///
/// For one button ([oneButton]), what a screen reader is told is the
/// button's, over the whole area. A row of buttons in one, the view
/// switcher's segments, keeps each segment's own.
class TapTarget extends StatelessWidget {
  const TapTarget({super.key, this.oneButton = true, required this.child});

  final bool oneButton;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padded = _TapPadding(child: child);
    return oneButton ? MergeSemantics(child: padded) : padded;
  }
}

class _TapPadding extends SingleChildRenderObjectWidget {
  const _TapPadding({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTapPadding();
}

class _RenderTapPadding extends RenderShiftedBox {
  _RenderTapPadding() : super(null);

  static const _least = kMinInteractiveDimension;

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(super.computeMinIntrinsicHeight(width), _least);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(super.computeMaxIntrinsicHeight(width), _least);

  Size _sizeFor(BoxConstraints constraints, Size? child) => constraints
      .constrain(Size(child?.width ?? 0, math.max(child?.height ?? 0, _least)));

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _sizeFor(constraints, child?.getDryLayout(constraints));

  @override
  void performLayout() {
    final child = this.child;
    child?.layout(constraints, parentUsesSize: true);
    size = _sizeFor(constraints, child?.size);
    if (child != null) {
      (child.parentData! as BoxParentData).offset =
          Alignment.center.alongOffset(size - child.size as Offset);
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (super.hitTest(result, position: position)) return true;
    final child = this.child;
    if (child == null) return false;
    // Above or below the button: the button at that point across, half
    // way down.
    final at = (child.parentData! as BoxParentData).offset;
    final target = Offset(
      (position.dx - at.dx).clamp(0.0, math.max(0.0, child.size.width - 1)),
      child.size.height / 2,
    );
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(target),
      position: target,
      hitTest: (result, position) => child.hitTest(result, position: target),
    );
  }
}
