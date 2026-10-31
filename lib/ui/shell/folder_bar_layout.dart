import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The parts of the bar over a tablet's list.
enum FolderBarSlot { lead, filters, sort, actions }

/// The bar over a tablet's list, on one line where it all fits and on two
/// where it does not.
///
/// [lead] (the panes' buttons and the folder's name) and [actions] (unread,
/// Search, the menu) are its first line, [filters] (All, Unread, Filter)
/// and [sort] (By Date) its second. Where the list is wide, as Outlook's is
/// with no reading pane beside it, the four share one line, the filters
/// after the name and By Date before the unread count: Ron asked for the
/// two lines to be one, to give their height to the list. Narrower, the
/// second goes under the first with a line between, as the two bars were.
///
/// Whether it fits is asked of the parts themselves, at their own widths,
/// so a long folder name, a larger text size or a filter with a longer name
/// moves it to two lines rather than cutting anything short.
class FolderBarLayout
    extends SlottedMultiChildRenderObjectWidget<FolderBarSlot, RenderBox> {
  const FolderBarLayout({
    super.key,
    required this.lead,
    required this.actions,
    required this.lineColor,
    this.filters,
    this.sort,
  });

  final Widget lead;
  final Widget actions;

  /// Null while the list is selecting or searching, whose own bars take
  /// the filters' place over it.
  final Widget? filters;
  final Widget? sort;

  /// The line between the two lines, where there are two.
  final Color lineColor;

  @override
  Iterable<FolderBarSlot> get slots => FolderBarSlot.values;

  @override
  Widget? childForSlot(FolderBarSlot slot) => switch (slot) {
        FolderBarSlot.lead => lead,
        FolderBarSlot.filters => filters,
        FolderBarSlot.sort => sort,
        FolderBarSlot.actions => actions,
      };

  @override
  RenderFolderBar createRenderObject(BuildContext context) =>
      RenderFolderBar(lineColor);

  @override
  void updateRenderObject(BuildContext context, RenderFolderBar renderObject) {
    renderObject.lineColor = lineColor;
  }
}

class RenderFolderBar extends RenderBox
    with SlottedContainerRenderObjectMixin<FolderBarSlot, RenderBox> {
  RenderFolderBar(this._lineColor);

  Color get lineColor => _lineColor;
  Color _lineColor;
  set lineColor(Color value) {
    if (value == _lineColor) return;
    _lineColor = value;
    markNeedsPaint();
  }

  /// Between the folder's name and the filters, on one line.
  static const double gap = 12;

  /// Whether the last layout put everything on one line.
  bool get oneLine => _oneLine;
  bool _oneLine = true;

  /// Where the second line starts, where there is one.
  double _secondAt = 0;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _arrange(constraints, ChildLayoutHelper.dryLayoutChild, place: false);

  @override
  void performLayout() {
    size = _arrange(constraints, ChildLayoutHelper.layoutChild, place: true);
  }

  /// The bar's size under [constraints], with each part measured by
  /// [measure], and put where it goes when [place].
  Size _arrange(
    BoxConstraints constraints,
    ChildLayouter measure, {
    required bool place,
  }) {
    final width = constraints.maxWidth;
    final lead = childForSlot(FolderBarSlot.lead);
    final filters = childForSlot(FolderBarSlot.filters);
    final sort = childForSlot(FolderBarSlot.sort);
    final actions = childForSlot(FolderBarSlot.actions);

    double natural(RenderBox? part) =>
        part?.getMaxIntrinsicWidth(double.infinity) ?? 0;
    Size laid(RenderBox? part, double maxWidth) => part == null
        ? Size.zero
        : measure(part, BoxConstraints(maxWidth: math.max(0, maxWidth)));
    void at(RenderBox? part, double x, double y) {
      if (place && part != null) {
        (part.parentData! as BoxParentData).offset = Offset(x, y);
      }
    }

    // The filters' room on one line, the gaps either side of them included.
    final filtersRoom = filters == null ? 0.0 : gap + natural(filters) + gap;
    final one = (filters == null && sort == null) ||
        natural(lead) + filtersRoom + natural(sort) + natural(actions) <=
            width;
    if (place) _oneLine = one;

    final a = laid(actions, width);
    if (one) {
      final s = laid(sort, width - a.width);
      final l = laid(lead, width - a.width - s.width - filtersRoom);
      final f = laid(filters, width - l.width - s.width - a.width - 2 * gap);
      final height = [l.height, f.height, s.height, a.height].reduce(math.max);
      at(lead, 0, (height - l.height) / 2);
      at(filters, l.width + gap, (height - f.height) / 2);
      at(sort, width - a.width - s.width, (height - s.height) / 2);
      at(actions, width - a.width, (height - a.height) / 2);
      return constraints.constrain(Size(width, height));
    }

    // Two lines: the folder over its filters, a line between.
    final l = laid(lead, width - a.width);
    final first = math.max(l.height, a.height);
    final s = laid(sort, width);
    final f = laid(filters, width - s.width);
    final second = math.max(f.height, s.height);
    if (place) _secondAt = first;
    at(lead, 0, (first - l.height) / 2);
    at(actions, width - a.width, (first - a.height) / 2);
    at(filters, 0, first + 1 + (second - f.height) / 2);
    at(sort, width - s.width, first + 1 + (second - s.height) / 2);
    return constraints.constrain(Size(width, first + 1 + second));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in children) {
      context.paintChild(
        child,
        offset + (child.parentData! as BoxParentData).offset,
      );
    }
    if (!_oneLine) {
      context.canvas.drawRect(
        Rect.fromLTWH(offset.dx, offset.dy + _secondAt, size.width, 1),
        Paint()..color = lineColor,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in children) {
      final hit = result.addWithPaintOffset(
        offset: (child.parentData! as BoxParentData).offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}
