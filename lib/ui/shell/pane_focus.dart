import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One focus node per pane, so the keyboard can be handed from the folder
/// tree to the list to the open message and back with F6.
///
/// Held above the layouts because the layouts come and go: turning the
/// tablet rebuilds the shell, and nodes created inside a layout would be
/// new nodes with nothing focused.
class PaneFocusNodes {
  final tree = FocusNode(debugLabel: 'Folder tree');
  final list = FocusNode(debugLabel: 'Message list');
  final reading = FocusNode(debugLabel: 'Open message');

  /// Left to right, the order F6 walks.
  List<FocusNode> get inOrder => [tree, list, reading];

  /// The pane after (or, with a negative [step], before) the one that
  /// holds the focus, among the panes that are on screen. A pane that is
  /// not built — the tree behind a phone's drawer, the reading pane when
  /// nothing is open — has no context and is skipped.
  FocusNode? neighbour(int step) {
    final shown = [for (final n in inOrder) if (n.context != null) n];
    if (shown.isEmpty) return null;
    final at = shown.indexWhere((n) => n.hasFocus);
    if (at < 0) return shown.first;
    return shown[(at + step) % shown.length];
  }

  void dispose() {
    for (final n in inOrder) {
      n.dispose();
    }
  }
}

final paneFocusProvider = Provider<PaneFocusNodes>((ref) {
  final nodes = PaneFocusNodes();
  ref.onDispose(nodes.dispose);
  return nodes;
});

/// Whether the focus is in something being typed into. Every key handler
/// asks this first: arrows in a search box move the caret, not the folder.
bool focusIsInTextField() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>() !=
    null;

/// Whether a hardware keyboard has been used this session.
///
/// The panes draw a line to say which of them has the keyboard, and that
/// line means nothing to someone with no keyboard, so it waits for the
/// first key.
class KeyboardInUse extends Notifier<bool> {
  @override
  bool build() => false;

  void noticed() {
    if (!state) state = true;
  }
}

final keyboardInUseProvider =
    NotifierProvider<KeyboardInUse, bool>(KeyboardInUse.new);

/// A thin line along the top of a pane while it holds the keyboard focus,
/// once a keyboard has been used. Without it F6 is invisible: the focus
/// moves and nothing on screen says where it went.
class PaneFocusFrame extends ConsumerWidget {
  const PaneFocusFrame({super.key, required this.node, required this.child});

  final FocusNode node;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inUse = ref.watch(keyboardInUseProvider);
    return Column(
      children: [
        ListenableBuilder(
          listenable: node,
          builder: (context, _) => Container(
            height: 2,
            color: inUse && node.hasFocus
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
