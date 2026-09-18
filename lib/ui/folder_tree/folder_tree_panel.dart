import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/folder_drag.dart';
import '../../state/folder_tree.dart';
import '../../domain/error_report.dart';
import '../../state/providers.dart';
import '../../state/update_providers.dart';
import '../settings/edit_account_screen.dart';
import '../messages/message_actions.dart';
import '../settings/settings_screen.dart';
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

    return Column(
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
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return switch (row) {
                        SectionHeaderRow() => _SectionHeader(
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
    );
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
        ..showSnackBar(SnackBar(content: Text('Could not move folder: $e')));
    }
  }
}

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
/// this folder to the top level of the account".
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.row,
    this.problem,
    this.canAcceptRoot,
    this.onDropToRoot,
    this.onToggleCollapsed,
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
                      if (problem != null) _ProblemActions(problem: problem!),
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

    if (canAcceptRoot == null || onDropToRoot == null) return header;

    return DragTarget<DraggedFolder>(
      onWillAcceptWithDetails: (d) => canAcceptRoot!(d.data),
      onAcceptWithDetails: (d) => onDropToRoot!(d.data),
      builder: (context, candidates, _) => candidates.isEmpty
          ? header
          : ColoredBox(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
              child: header,
            ),
    );
  }
}

/// What the app offers to do about an account's failure.
///
/// A remedy only where one is genuinely one tap and genuinely likely to work.
/// An offer that fails leaves someone worse off than no offer: they have tried
/// the fix, it did not work, and now they have nothing else to try.
///
/// Copy is always offered. It puts the build number, the account and the real
/// error on the clipboard, which is one paste instead of a screenshot and a
/// conversation — and it works when the mail itself does not, which is exactly
/// when it is needed.
class _ProblemActions extends ConsumerWidget {
  const _ProblemActions({required this.problem});

  final AccountProblem problem;

  Future<void> _copy(BuildContext context, WidgetRef ref) async {
    final version = ref.read(installedVersionValueProvider).value;
    await Clipboard.setData(ClipboardData(
      text: problem.report(
        appVersion: version?.version,
        build: version?.build,
      ),
    ));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Problem details copied. Paste them anywhere.'),
      ));
  }

  /// File it on GitHub, where it stays and can be answered.
  ///
  /// The repository is public, so the address is masked on this path. The
  /// clipboard keeps the whole thing: that goes wherever the person puts it,
  /// which is their decision to make. This one is published the moment they
  /// press the button on the page, so the app makes it for them.
  Future<void> _report(BuildContext context, WidgetRef ref) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Report this on GitHub?'),
        content: const Text(
          'This opens a new issue with the details filled in. You can read it '
          'over and change anything before submitting.\n\n'
          'The repository is public, so your email address is shortened to '
          'its first letter and domain. Nothing else about your mail is '
          'included — no message, no subject, no password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open GitHub'),
          ),
        ],
      ),
    );
    if (agreed != true || !context.mounted) return;

    final version = ref.read(installedVersionValueProvider).value;
    final url = IssueTracker.newIssueUrl(
      title: IssueTracker.titleFor(
        doing: problem.doing,
        error: problem.error,
      ),
      report: problem.report(
        appVersion: version?.version,
        build: version?.build,
        redactAddress: true,
      ),
    );

    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Could not open a browser. Use Copy details instead.'),
        ));
    }
  }

  Future<void> _act(BuildContext context, WidgetRef ref) async {
    switch (problem.remedy) {
      case ErrorRemedy.retry:
        ref.invalidate(foldersProvider);
      case ErrorRemedy.signInAgain:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => EditAccountScreen(account: problem.account),
          ),
        );
        // Whatever happened in there, the folders are worth another try: the
        // whole reason to go was that they could not be loaded.
        ref.invalidate(foldersProvider);
      case ErrorRemedy.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 4,
      children: [
        if (problem.remedy.isOffered)
          TextButton(
            onPressed: () => _act(context, ref),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(problem.remedy.label),
          ),
        TextButton(
          onPressed: () => _copy(context, ref),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Copy details'),
        ),
        TextButton(
          onPressed: () => _report(context, ref),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Report'),
        ),
      ],
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
