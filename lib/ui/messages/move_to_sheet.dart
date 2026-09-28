import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_folder.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../folder_tree/folder_tile.dart' show folderIconFor;

/// Pick a destination for a message move.
///
/// Recent destinations come first, as in Outlook, because that is what gets
/// used; the account's folders follow as a tree, drawn the way the folder
/// pane draws them and opened where the pane has them open. Only folders
/// that can actually take a message can be chosen, which rules out Gmail's
/// Drafts, Sent and All Mail; a parent that cannot is still drawn, greyed,
/// so what is inside it keeps its place.
///
/// Returns the chosen folder id, or null if dismissed.
Future<String?> showMoveToSheet(
  BuildContext context, {
  required String accountId,
  required String fromFolderId,
  required int messageCount,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MoveToSheet(
      accountId: accountId,
      fromFolderId: fromFolderId,
      messageCount: messageCount,
    ),
  );
}

class _MoveToSheet extends ConsumerStatefulWidget {
  const _MoveToSheet({
    required this.accountId,
    required this.fromFolderId,
    required this.messageCount,
  });

  final String accountId;
  final String fromFolderId;
  final int messageCount;

  @override
  ConsumerState<_MoveToSheet> createState() => _MoveToSheetState();
}

class _MoveToSheetState extends ConsumerState<_MoveToSheet> {
  /// What has been typed. A mailbox at work holds hundreds of folders, and
  /// scrolling a list that long to find one is the slow way to do a thing
  /// people do twenty times a day.
  String _query = '';

  /// The branches open in the tree, starting as the folder pane has them:
  /// the tree is the one already known, open where it is usually open.
  /// Opening one here opens it here only.
  late final Set<String> _open = {...ref.read(expandedFoldersProvider)};

  String get accountId => widget.accountId;
  String get fromFolderId => widget.fromFolderId;
  int get messageCount => widget.messageCount;

  bool _takes(MailFolder f) =>
      f.capabilities.canAcceptMessages && f.id != fromFolderId;

  void _toggle(String folderId) => setState(() {
        if (!_open.remove(folderId)) _open.add(folderId);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    final all = ref.watch(foldersProvider).value?[accountId] ?? const [];
    final compare = folderComparator(ref.watch(folderOrderProvider));

    // Recents, filtered to this account and to folders that still exist.
    final recents = <MailFolder>[
      for (final id in ref.watch(recentMoveTargetsProvider))
        if (index[id] case final f?)
          if (f.accountId == accountId && _takes(f)) f,
    ];

    final query = _query.trim().toLowerCase();
    // A search is a flat list with each folder's path, since the parents
    // may not be in it; everything else is the tree.
    final matches = query.isEmpty
        ? const <MailFolder>[]
        : [
            for (final f in _inTreeOrder(all, compare))
              if (_takes(f) &&
                  (f.displayName.toLowerCase().contains(query) ||
                      _pathOf(f, index).toLowerCase().contains(query)))
                f,
          ];
    final tree = query.isEmpty ? _treeRows(all, compare) : const <_TreeEntry>[];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                messageCount == 1
                    ? 'Move to'
                    : 'Move $messageCount messages to',
                style: theme.textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  hintText: 'Search folders',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _query = ''),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (query.isNotEmpty) ...[
                    for (final f in matches)
                      _FolderOption(folder: f, path: _pathOf(f, index)),
                    if (matches.isEmpty)
                      ListTile(
                        enabled: false,
                        title: Text('No folder matches “$_query”.'),
                      ),
                  ] else ...[
                    // Recents are the answer most of the time, so they stay
                    // at the top, each with where it lives.
                    if (recents.isNotEmpty) ...[
                      _SheetHeading(text: 'Recent', theme: theme),
                      for (final f in recents)
                        _FolderOption(folder: f, path: _pathOf(f, index)),
                      const Divider(height: 1),
                      _SheetHeading(text: 'All folders', theme: theme),
                    ],
                    for (final entry in tree)
                      _TreeRow(
                        entry: entry,
                        open: _open.contains(entry.folder.id),
                        here: entry.folder.id == fromFolderId,
                        onToggle: () => _toggle(entry.folder.id),
                      ),
                    if (!all.any(_takes))
                      const ListTile(
                        enabled: false,
                        title: Text('Nowhere to move it to.'),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The rows of the tree, top to bottom: every folder that can take the
  /// message or is where it is now, and every parent of one, in the tree's
  /// order, under the branches that are open.
  List<_TreeEntry> _treeRows(
    List<MailFolder> all,
    Comparator<MailFolder> compare,
  ) {
    final ids = {for (final f in all) f.id};
    final children = <String, List<MailFolder>>{};
    final roots = <MailFolder>[];
    for (final f in all) {
      final parentId = f.parentId;
      if (parentId == null || !ids.contains(parentId)) {
        roots.add(f);
      } else {
        children.putIfAbsent(parentId, () => []).add(f);
      }
    }

    // Whether a folder is drawn at all: one that can take the message, the
    // one it is in, or a parent of either. Remembered, and bounded, so a
    // parent chain that loops cannot hang the sheet.
    final drawn = <String, bool>{};
    bool isDrawn(MailFolder f, int depth) {
      final known = drawn[f.id];
      if (known != null) return known;
      if (depth > 32) return false;
      drawn[f.id] = false;
      final result = _takes(f) ||
          f.id == fromFolderId ||
          (children[f.id] ?? const <MailFolder>[])
              .any((c) => isDrawn(c, depth + 1));
      return drawn[f.id] = result;
    }

    final rows = <_TreeEntry>[];
    final seen = <String>{};
    void walk(List<MailFolder> level, int depth) {
      for (final f in [...level]..sort(compare)) {
        if (!seen.add(f.id) || !isDrawn(f, 0)) continue;
        final kids = [
          for (final c in children[f.id] ?? const <MailFolder>[])
            if (isDrawn(c, 0)) c,
        ];
        rows.add(_TreeEntry(f, depth, hasChildren: kids.isNotEmpty));
        if (kids.isNotEmpty && _open.contains(f.id)) walk(kids, depth + 1);
      }
    }

    walk(roots, 0);
    return rows;
  }
}

/// One line of the tree: a folder, how deep it sits, and whether it has
/// anything under it to open.
class _TreeEntry {
  const _TreeEntry(this.folder, this.depth, {required this.hasChildren});

  final MailFolder folder;
  final int depth;
  final bool hasChildren;
}

/// Where a folder lives, in the names the app shows: "Deleted › Invoices"
/// rather than "Deleted Items › Invoices", since Deleted is what the row
/// above it is called.
String _pathOf(MailFolder folder, Map<String, MailFolder> index) {
  final parts = <String>[folder.displayName];
  var cursor = folder;
  for (var depth = 0; depth < 8; depth++) {
    final parentId = cursor.parentId;
    if (parentId == null) break;
    final parent = index[parentId];
    if (parent == null) break;
    parts.insert(0, parent.displayName);
    cursor = parent;
  }
  return parts.join(' › ');
}

/// The account's folders in the order the tree draws them: each folder
/// followed by what is inside it, every level in the tree's own order.
///
/// A folder whose parent is missing from the list is treated as a root, so
/// nothing is dropped by an unusual mailbox.
List<MailFolder> _inTreeOrder(
  List<MailFolder> all,
  Comparator<MailFolder> compare,
) {
  final ids = {for (final f in all) f.id};
  final children = <String, List<MailFolder>>{};
  final roots = <MailFolder>[];
  for (final f in all) {
    final parentId = f.parentId;
    if (parentId == null || !ids.contains(parentId)) {
      roots.add(f);
    } else {
      children.putIfAbsent(parentId, () => []).add(f);
    }
  }

  final ordered = <MailFolder>[];
  final seen = <String>{};
  void walk(List<MailFolder> level) {
    for (final f in level..sort(compare)) {
      // A cycle in the parent chain would otherwise loop for ever.
      if (!seen.add(f.id)) continue;
      ordered.add(f);
      final kids = children[f.id];
      if (kids != null) walk(kids);
    }
  }

  walk(roots);
  // Anything a cycle kept out still belongs on the list.
  for (final f in all) {
    if (seen.add(f.id)) ordered.add(f);
  }
  return ordered;
}

class _SheetHeading extends StatelessWidget {
  const _SheetHeading({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A folder with where it lives under its name: the recent ones, and a
/// search's matches, whose parents may not be on the list.
class _FolderOption extends StatelessWidget {
  const _FolderOption({required this.folder, required this.path});

  final MailFolder folder;
  final String path;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('move-option-${folder.id}'),
      leading: Icon(folderIconFor(folder)),
      title: Text(folder.displayName),
      subtitle: path != folder.displayName
          ? Text(path, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: () => Navigator.of(context).pop(folder.id),
    );
  }
}

/// A line of the tree, as the folder pane draws one: the arrow that opens
/// what is under it, the folder's own icon, its name, indented by depth.
/// Greyed where a message cannot go: the folder it is in now, and a parent
/// that cannot take mail but holds folders that can.
class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.entry,
    required this.open,
    required this.here,
    required this.onToggle,
  });

  final _TreeEntry entry;
  final bool open;
  final bool here;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = entry.folder;
    final takes = folder.capabilities.canAcceptMessages && !here;
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return InkWell(
      key: ValueKey('move-tree-${folder.id}'),
      onTap: takes ? () => Navigator.of(context).pop(folder.id) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: EdgeInsets.only(left: 12.0 + entry.depth * 20, right: 16),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: entry.hasChildren
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 40,
                        ),
                        iconSize: 20,
                        tooltip: open ? 'Collapse' : 'Expand',
                        icon: AnimatedRotation(
                          turns: open ? 0.25 : 0,
                          duration: const Duration(milliseconds: 120),
                          child: const Icon(Icons.chevron_right),
                        ),
                        onPressed: onToggle,
                      )
                    : null,
              ),
              Icon(
                folderIconFor(folder, open: open && entry.hasChildren),
                size: 20,
                color: takes ? theme.colorScheme.onSurfaceVariant : muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  folder.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: takes ? null : muted),
                ),
              ),
              if (here)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'Here now',
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
