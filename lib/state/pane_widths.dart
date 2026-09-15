import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import 'providers.dart';

/// How wide the tree and list panes are, remembered per device.
///
/// A tablet is the only place this matters, and it matters there because the
/// right split depends on the mailbox: long folder paths want a wider tree,
/// long subject lines want a wider list. Fixed widths are a guess that is
/// wrong for somebody, so they are draggable and the drag is kept.
class PaneWidths extends Notifier<PaneLayout> {
  @override
  PaneLayout build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeOrder(UiStateKeys.paneWidths, {
          'tree': next.tree.round(),
          'list': next.list.round(),
        }));
    final saved = store.readOrder(UiStateKeys.paneWidths);
    return PaneLayout(
      tree: (saved['tree'] ?? PaneLayout.defaultTree).toDouble(),
      list: (saved['list'] ?? PaneLayout.defaultList).toDouble(),
    );
  }

  void dragTree(double delta) =>
      state = state.copyWith(tree: PaneLayout.clampTree(state.tree + delta));

  void dragList(double delta) =>
      state = state.copyWith(list: PaneLayout.clampList(state.list + delta));

  /// Back to the shipped split. Offered because a drag can leave the layout
  /// somewhere the user did not mean and there is no undo on a divider.
  void reset() => state = const PaneLayout();
}

final paneWidthsProvider =
    NotifierProvider<PaneWidths, PaneLayout>(PaneWidths.new);

class PaneLayout {
  const PaneLayout({this.tree = defaultTree, this.list = defaultList});

  final double tree;
  final double list;

  static const double defaultTree = 300;
  static const double defaultList = 380;

  /// Bounds, not preferences. Below the minimum a pane cannot show a folder
  /// name or a subject line; above the maximum it starves the one beside it.
  static const double minTree = 200;
  static const double maxTree = 460;
  static const double minList = 280;
  static const double maxList = 620;

  static double clampTree(double v) => v.clamp(minTree, maxTree);
  static double clampList(double v) => v.clamp(minList, maxList);

  /// The widths that actually fit in [available].
  ///
  /// The reading pane is last and has no width of its own, so without this a
  /// tablet rotated into a narrower landscape would give it nothing. It keeps
  /// [minReading] and the other two give the space back in proportion.
  static const double minReading = 320;

  PaneLayout fitted(double available, {required bool hasReadingPane}) {
    final needed = hasReadingPane ? minReading : 0.0;
    final spare = available - needed;
    final wanted = hasReadingPane ? tree + list : tree;
    if (wanted <= spare) return this;
    if (spare <= 0) return this;
    final scale = spare / wanted;
    return PaneLayout(
      tree: tree * scale,
      list: hasReadingPane ? list * scale : list,
    );
  }

  PaneLayout copyWith({double? tree, double? list}) =>
      PaneLayout(tree: tree ?? this.tree, list: list ?? this.list);

  @override
  bool operator ==(Object other) =>
      other is PaneLayout && other.tree == tree && other.list == list;

  @override
  int get hashCode => Object.hash(tree, list);

  @override
  String toString() => 'PaneLayout(tree: $tree, list: $list)';
}
