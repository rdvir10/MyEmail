import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/folder_drag.dart';
import '../../state/folder_tree.dart';
import '../../domain/error_report.dart';
import '../../state/providers.dart';
import '../common/problem_view.dart';
import '../settings/edit_account_screen.dart';
import '../messages/message_actions.dart';
import '../settings/settings_screen.dart';
import '../shell/pane_focus.dart';
import 'folder_actions.dart';
import 'folder_tile.dart';

/// The folder tree itself: search box on top, rows below.
///
/// Used as the drawer contents on a phone and as the left pane on a tablet, so
/// it knows nothing about how it is hosted.
class FolderTreePanel extends ConsumerWidget {
  const FolderTreePanel({super.key, this.onFolderSelected});

  /// Lets the phone layout close the drawer after a selection.
  final void Function(String folderId)? onFolderSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(treeRowsProvider);
    final selected = ref.watch(effectiveSelectedFolderIdProvider);
    final foldersAsync = ref.watch(foldersProvider);
    final node = ref.watch(paneFocusProvider).tree;

    return Focus(
      focusNode: node,
      onKeyEvent: (_, event) => _onKey(ref, rows, selected, event),
      child: PaneFocusFrame(
        node: node,
        child: Column(
      children: [
        const _FolderSearchField(),
        const Divider(height: 1),
        Expanded(
          child: foldersAsync.when(
            loading: () => const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (e, _) => _ErrorState(message: '$e'),
            data: (_) => rows.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: rows.length,
                    // Rows are keyed, and found again by key, so a row keeps
                    // its widget when the rows around it come and go: the
                    // heading being dragged is still the one that was picked
                    // up once the tree folds to headings alone beneath it.
                    findChildIndexCallback: (key) {
                      final i = rows.indexWhere((r) => ValueKey(r.key) == key);
                      return i < 0 ? null : i;
                    },
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return switch (row) {
                        SectionHeaderRow() => _SectionHeader(
                            key: ValueKey(row.key),
                            row: row,
                            problem: row.accountId == null
                                ? null
                                : ref.watch(folderLoadErrorsProvider)[
                                    row.accountId!],
                            onToggleCollapsed: row.accountId == null
                                ? null
                                : () => ref
                                    .read(collapsedAccountsProvider.notifier)
                                    .toggle(row.accountId!),
                            canAcceptRoot: row.accountId == null
                                ? null
                                : (d) => canDropOnRoot(d.folder, row.accountId!),
                            onDropToRoot: row.accountId == null
                                ? null
                                : (d) => _drop(
                                      context,
                                      ref,
                                      dragged: d,
                                      target: null,
                                      accountId: row.accountId!,
                                      zone: DropZone.into,
                                    ),
                            // Held, the heading lifts and the tree folds to
                            // the headings alone, so every place it could
                            // go is on screen; see draggingAccountProvider.
                            onDragStarted: row.accountId == null
                                ? null
                                : () => ref
                                    .read(draggingAccountProvider.notifier)
                                    .set(row.accountId),
                            onDragEnded: row.accountId == null
                                ? null
                                : () => ref
                                    .read(draggingAccountProvider.notifier)
                                    .set(null),
                            onDropAccount: row.accountId == null
                                ? null
                                : (dragged, zone) => performAccountDrop(
                                      ref,
                                      draggedId: dragged.accountId,
                                      targetId: row.accountId!,
                                      zone: zone,
                                    ),
                          ),
                        FolderRow() => FolderTile(
                            key: ValueKey(row.key),
                            row: row,
                            isSelected: selected == row.folder.id,
                            onTap: () {
                              ref
                                  .read(selectedFolderIdProvider.notifier)
                                  .select(row.folder.id);
                              onFolderSelected?.call(row.folder.id);
                            },
                            onToggleExpand: () => ref
                                .read(expandedFoldersProvider.notifier)
                                .toggle(row.folder.id),
                            onAutoExpand: () => ref
                                .read(expandedFoldersProvider.notifier)
                                .expand(row.folder.id),
                            onLongPress: () => showFolderActionsSheet(
                              context,
                              ref,
                              row.folder,
                            ),
                            onDrop: row.folder.isSynthetic
                                ? null
                                : (dragged, zone) => _drop(
                                      context,
                                      ref,
                                      dragged: dragged,
                                      target: row.folder,
                                      accountId: row.folder.accountId,
                                      zone: zone,
                                    ),
                            onDropMessages: row.folder.isSynthetic
                                ? null
                                : (dragged) => _dropMessages(
                                      context,
                                      ref,
                                      dragged,
                                      row.folder.id,
                                    ),
                            onDropFavorite: !row.inFavorites
                                ? null
                                : (dragged, zone) => performFavoriteDrop(
                                      ref,
                                      draggedId: dragged.folder.id,
                                      targetId: row.folder.id,
                                      zone: zone,
                                    ),
                          ),
                      };
                    },
                  ),
          ),
        ),
        const Divider(height: 1),
        // The only route back to something hidden, so it lives in the tree
        // rather than behind Settings. Absent when nothing is hidden: a
        // control for nothing is noise.
        const _HiddenFoldersRow(),
        // One entry, not four. Quick Steps, accounts and notifications all
        // live behind it now; the tree is for folders.
        ListTile(
          dense: true,
          leading: const Icon(Icons.settings_outlined, size: 20),
          title: const Text('Settings'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
        ),
      ),
    );
  }

  /// The arrow keys walk the folders as they are shown, opening each one as
  /// they land on it, the way Outlook's tree does. Right shows a folder's
  /// children; Left hides them, or with nothing to hide goes up a level.
  /// Only folder rows count: an account heading is not somewhere to be.
  KeyEventResult _onKey(
    WidgetRef ref,
    List<TreeRow> rows,
    String? selected,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // The tree's own search box: arrows there move the caret.
    if (focusIsInTextField()) return KeyEventResult.ignored;

    final folders = [for (final r in rows) if (r is FolderRow) r];
    if (folders.isEmpty) return KeyEventResult.ignored;
    // The row the keys are on, not just the folder: a favourite is in the
    // tree twice, and found by folder id Down went back to its first row
    // and round again, so nothing below it could be reached.
    final keyed = ref.read(_keyedRowProvider);
    var at = folders
        .indexWhere((r) => r.key == keyed && r.folder.id == selected);
    if (at < 0) at = folders.indexWhere((r) => r.folder.id == selected);
    final row = at < 0 ? null : folders[at];

    void pick(int i) {
      final target = folders[i.clamp(0, folders.length - 1)];
      ref.read(_keyedRowProvider.notifier).set(target.key);
      ref.read(selectedFolderIdProvider.notifier).select(target.folder.id);
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        pick(at < 0 ? 0 : at + 1);
      case LogicalKeyboardKey.arrowUp:
        pick(at < 0 ? 0 : at - 1);
      case LogicalKeyboardKey.home:
        pick(0);
      case LogicalKeyboardKey.end:
        pick(folders.length - 1);
      case LogicalKeyboardKey.arrowRight:
        if (row != null && row.hasChildren && !row.isExpanded) {
          ref.read(expandedFoldersProvider.notifier).expand(row.folder.id);
        }
      case LogicalKeyboardKey.arrowLeft:
        if (row == null) return KeyEventResult.ignored;
        if (row.hasChildren && row.isExpanded) {
          ref.read(expandedFoldersProvider.notifier).toggle(row.folder.id);
        } else if (!row.flat && row.depth > 0) {
          // The folder above: the nearest row upward one level shallower.
          for (var i = at - 1; i >= 0; i--) {
            if (!folders[i].flat && folders[i].depth == row.depth - 1) {
              pick(i);
              break;
            }
          }
        }
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (selected != null) onFolderSelected?.call(selected);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Messages dropped onto a folder are moved there. The action is the same
  /// one the swipe and the menu use, so the snackbar and the rollback on
  /// failure behave identically.
  Future<void> _dropMessages(
    BuildContext context,
    WidgetRef ref,
    DraggedMessages dragged,
    String toFolderId,
  ) async {
    final listId = ref.read(effectiveSelectedFolderIdProvider);
    if (listId == null) return;
    await MessageActions(ref, listId)
        .moveTo(context, dragged.messages, toFolderId);
  }

  Future<void> _drop(
    BuildContext context,
    WidgetRef ref, {
    required DraggedFolder dragged,
    required target,
    required String accountId,
    required DropZone zone,
  }) async {
    try {
      await performFolderDrop(
        ref,
        dragged: dragged.folder,
        target: target,
        accountId: accountId,
        zone: zone,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not move folder: $e')));
    }
  }
}

/// Which row the arrow keys last moved to, by its key.
class _KeyedRow extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String key) => state = key;
}

final _keyedRowProvider =
    NotifierProvider<_KeyedRow, String?>(_KeyedRow.new);

class _FolderSearchField extends ConsumerStatefulWidget {
  const _FolderSearchField();

  @override
  ConsumerState<_FolderSearchField> createState() => _FolderSearchFieldState();
}

class _FolderSearchFieldState extends ConsumerState<_FolderSearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(folderSearchQueryProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: 'Search folders',
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    _controller.clear();
                    ref.read(folderSearchQueryProvider.notifier).clear();
                  },
                ),
        ),
        onChanged: (value) =>
            ref.read(folderSearchQueryProvider.notifier).set(value),
      ),
    );
  }
}

/// A section heading. Account headers double as a drop target meaning "move
/// this folder to the top level of the account", and can be held and dragged
/// to put the account before or after another: Ron asked to arrange the
/// accounts from the list itself.
class _SectionHeader extends ConsumerStatefulWidget {
  const _SectionHeader({
    super.key,
    required this.row,
    this.problem,
    this.canAcceptRoot,
    this.onDropToRoot,
    this.onToggleCollapsed,
    this.onDragStarted,
    this.onDragEnded,
    this.onDropAccount,
  });

  final SectionHeaderRow row;

  /// The whole failure, when this account has one. The row's [row.error]
  /// carries the sentence; this carries what can be done about it.
  final AccountProblem? problem;

  final bool Function(DraggedFolder dragged)? canAcceptRoot;
  final void Function(DraggedFolder dragged)? onDropToRoot;

  /// Fold this account's folders away, or bring them back. Null for a heading
  /// that does not belong to an account.
  final VoidCallback? onToggleCollapsed;

  /// The heading picked up, and let go wherever it was let go. Null for a
  /// heading that is not an account's.
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;

  /// Called with an account heading dropped on this one, and whether it
  /// landed on the top half or the bottom. Null for a heading that is not
  /// an account's, which takes nothing.
  final void Function(DraggedAccount dragged, DropZone zone)? onDropAccount;

  @override
  ConsumerState<_SectionHeader> createState() => _SectionHeaderState();
}

class _SectionHeaderState extends ConsumerState<_SectionHeader> {
  /// Which half of this heading a dragged account is over, for the line
  /// that says where it would land.
  DropZone? _hoverZone;

  SectionHeaderRow get row => widget.row;
  AccountProblem? get problem => widget.problem;
  bool Function(DraggedFolder dragged)? get canAcceptRoot =>
      widget.canAcceptRoot;
  void Function(DraggedFolder dragged)? get onDropToRoot => widget.onDropToRoot;
  VoidCallback? get onToggleCollapsed => widget.onToggleCollapsed;

  DropZone? _zoneAt(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(global);
    return edgeZone((local.dy / box.size.height).clamp(0.0, 1.0));
  }

  /// Reload, or open the account so its sign-in can be replaced.
  Future<void> _remedy(
    BuildContext context,
    WidgetRef ref,
    AccountProblem problem,
  ) async {
    if (problem.remedy == ErrorRemedy.signInAgain) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditAccountScreen(account: problem.account),
        ),
      );
    }
    // Either way the folders are worth another try: not being able to load
    // them is the whole reason there is a message here.
    ref.invalidate(foldersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final collapsible = row.canCollapse && onToggleCollapsed != null;
    final isCollapsed = row.isCollapsed ?? false;

    Widget header = Padding(
      padding: EdgeInsets.fromLTRB(collapsible ? 4 : 12, 16, 12, 6),
      child: Row(
        children: [
          if (collapsible) ...[
            // Pointing down when open and right when shut, the same way the
            // folder rows do it, so one gesture reads the same at both levels.
            Icon(
              isCollapsed ? Icons.chevron_right : Icons.expand_more,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
          if (row.accentColor != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Color(row.accentColor!),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (row.subtitle != null)
                  Text(
                    row.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
          // A collapsed mailbox with nothing after its name is hard to tell
          // from one whose folders failed to load.
          if (isCollapsed && row.folderCount > 0)
            Text(
              '${row.folderCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );

    final error = row.error;
    if (error != null) {
      header = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline,
                    size: 14, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                      if (problem != null)
                        ProblemView(
                          problem: problem!.asReport,
                          // The tree is the one place with somewhere to go:
                          // it can reload itself, or open the account that
                          // needs attention.
                          onRemedy: () => _remedy(context, ref, problem!),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (collapsible) {
      header = Semantics(
        button: true,
        expanded: !isCollapsed,
        label: isCollapsed
            ? 'Show the folders in ${row.title}'
            : 'Hide the folders in ${row.title}',
        child: InkWell(
          onTap: onToggleCollapsed,
          child: header,
        ),
      );
    }

    if (canAcceptRoot != null && onDropToRoot != null) {
      final inner = header;
      header = DragTarget<DraggedFolder>(
        onWillAcceptWithDetails: (d) => canAcceptRoot!(d.data),
        onAcceptWithDetails: (d) => onDropToRoot!(d.data),
        builder: (context, candidates, _) => candidates.isEmpty
            ? inner
            : ColoredBox(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                child: inner,
              ),
      );
    }

    final accountId = row.accountId;
    final onDropAccount = widget.onDropAccount;
    if (accountId == null || onDropAccount == null) return header;

    // Held, the heading lifts; dropped on another heading's top half the
    // account goes before it, on the bottom half after. The tree folds to
    // headings alone for the length of the drag (the panel's doing, from
    // onDragStarted), so the place it is going is on screen.
    final draggable = LongPressDraggable<DraggedAccount>(
      data: DraggedAccount(accountId),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: DragFeedbackCard(
        label: row.title,
        leading: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: row.accentColor == null
                ? theme.colorScheme.primary
                : Color(row.accentColor!),
            shape: BoxShape.circle,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: header),
      onDragStarted: widget.onDragStarted,
      onDragEnd: (_) => widget.onDragEnded?.call(),
      child: header,
    );
    return DragTarget<DraggedAccount>(
      onWillAcceptWithDetails: (d) => d.data.accountId != accountId,
      onMove: (d) {
        // Its own drag passing over it is not a place it could land.
        if (d.data.accountId == accountId) return;
        final zone = _zoneAt(d.offset);
        if (zone != _hoverZone) setState(() => _hoverZone = zone);
      },
      onLeave: (_) {
        if (_hoverZone != null) setState(() => _hoverZone = null);
      },
      onAcceptWithDetails: (d) {
        final zone = _zoneAt(d.offset) ?? DropZone.after;
        setState(() => _hoverZone = null);
        onDropAccount(d.data, zone);
      },
      builder: (_, _, _) => dropIndicated(context, draggable, _hoverZone),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(folderSearchQueryProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          query.isEmpty ? 'No folders' : 'No folders match "$query"',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Could not load folders.\n$message',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// "3 hidden", and the switch that reveals them.
///
/// Reveal rather than a separate screen: the folders come back in place,
/// dimmed, so it is obvious where each one sits and a long press unhides it
/// exactly where it will reappear.
class _HiddenFoldersRow extends ConsumerWidget {
  const _HiddenFoldersRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(hiddenFolderCountProvider);
    if (count == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final showing = ref.watch(showHiddenFoldersProvider);
    return ListTile(
      dense: true,
      leading: Icon(
        showing ? Icons.visibility : Icons.visibility_off_outlined,
        size: 20,
        color: showing ? theme.colorScheme.primary : null,
      ),
      title: Text(
        count == 1 ? '1 hidden folder' : '$count hidden folders',
        style: showing
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              )
            : null,
      ),
      trailing: Text(
        showing ? 'Hide again' : 'Show',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
      onTap: () => ref.read(showHiddenFoldersProvider.notifier).toggle(),
    );
  }
}
