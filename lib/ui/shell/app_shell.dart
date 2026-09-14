import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../folder_tree/folder_tree_panel.dart';

/// Phone shows the tree in a slide-out drawer like Outlook mobile; a tablet in
/// landscape shows it as a permanent pane. The breakpoint is on width alone, so
/// rotating a tablet moves between the two without any state being rebuilt.
///
/// There is deliberately no logic here about which folder to show first: that
/// is derived in [effectiveSelectedFolderIdProvider], so nothing has to be
/// listening at the right moment for the default to take.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const double tabletBreakpoint = 840;
  static const double treePaneWidth = 300;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= tabletBreakpoint;
    return isWide ? const _WideLayout() : const _NarrowLayout();
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: AppShell.treePaneWidth,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const FolderTreePanel(),
              ),
            ),
            const VerticalDivider(width: 1),
            const Expanded(child: _MessageListPlaceholder()),
          ],
        ),
      ),
    );
  }
}

class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(effectiveSelectedFolderIdProvider);
    final folder = selectedId == null
        ? null
        : ref.watch(folderIndexProvider)[selectedId];

    return Scaffold(
      appBar: AppBar(
        title: Text(folder?.displayName ?? 'MailTree'),
        centerTitle: false,
      ),
      drawer: Drawer(
        child: SafeArea(
          // Builder gives a context below the Scaffold, so the drawer can be
          // closed through the Scaffold's own API rather than by popping
          // whatever happens to be on the navigator.
          child: Builder(
            builder: (drawerContext) => FolderTreePanel(
              onFolderSelected: (_) =>
                  Scaffold.of(drawerContext).closeDrawer(),
            ),
          ),
        ),
      ),
      body: const _MessageListPlaceholder(),
    );
  }
}

/// Milestone 3 replaces this with the real message list. It shows the selected
/// folder so that tree selection is visibly wired end to end.
class _MessageListPlaceholder extends ConsumerWidget {
  const _MessageListPlaceholder();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selectedId = ref.watch(effectiveSelectedFolderIdProvider);
    final folder = selectedId == null
        ? null
        : ref.watch(folderIndexProvider)[selectedId];

    if (folder == null) {
      return Center(
        child: Text('Select a folder', style: theme.textTheme.bodySmall),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(folder.displayName, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              folder.isSynthetic ? 'Across all accounts' : displayPath(folder),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            Text(
              '${folder.totalCount} messages, ${folder.unreadCount} unread',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Text(
              'The message list arrives in milestone 3.',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
