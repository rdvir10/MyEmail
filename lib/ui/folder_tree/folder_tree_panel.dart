import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/folder_tree.dart';
import '../../state/providers.dart';
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
                        SectionHeaderRow() => _SectionHeader(row: row),
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
                          ),
                      };
                    },
                  ),
          ),
        ),
      ],
    );
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.row});

  final SectionHeaderRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Row(
        children: [
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
        ],
      ),
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
