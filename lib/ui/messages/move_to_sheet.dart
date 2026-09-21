import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_folder.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';

/// Pick a destination for a message move.
///
/// Recent destinations come first, as in Outlook, because that is what gets
/// used; the rest of the account's folders follow in tree order. Only
/// folders that can actually take a message are offered, which rules out
/// Gmail's Drafts, Sent and All Mail.
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

  String get accountId => widget.accountId;
  String get fromFolderId => widget.fromFolderId;
  int get messageCount => widget.messageCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    final all = ref.watch(foldersProvider).value?[accountId] ?? const [];
    final overrides = ref.watch(folderOrderProvider);

    // In the order the tree draws them: a folder, then what is inside it.
    // Sorting the flat list instead put every subfolder of Deleted Items
    // in the middle of the user folders, a screen away from the parent
    // whose name their path was quoting.
    final candidates = [
      for (final f in _inTreeOrder(all, folderComparator(overrides)))
        if (f.capabilities.canAcceptMessages && f.id != fromFolderId) f,
    ];

    // Recents, filtered to this account and to folders that still exist.
    final recents = <MailFolder>[
      for (final id in ref.watch(recentMoveTargetsProvider))
        if (index[id] case final f?)
          if (f.accountId == accountId &&
              f.id != fromFolderId &&
              f.capabilities.canAcceptMessages)
            f,
    ];
    final recentIds = {for (final f in recents) f.id};

    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? candidates
        : [
            for (final f in candidates)
              if (f.displayName.toLowerCase().contains(query) ||
                  _pathOf(f, index).toLowerCase().contains(query))
                f,
          ];

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
                  // Recents are the answer most of the time, so they stay
                  // at the top — but not while searching, where the point
                  // is to find the one folder that was typed for.
                  if (recents.isNotEmpty && query.isEmpty) ...[
                    _SheetHeading(text: 'Recent', theme: theme),
                    for (final f in recents)
                      _FolderOption(folder: f, path: _pathOf(f, index)),
                    const Divider(height: 1),
                    _SheetHeading(text: 'All folders', theme: theme),
                  ],
                  for (final f in matches)
                    if (query.isNotEmpty || !recentIds.contains(f.id))
                      _FolderOption(
                        folder: f,
                        // Indented to its place in the tree, so a folder is
                        // read as where it lives. The path underneath would
                        // then be saying the same thing twice, so it is kept
                        // for the search, where the list is flat and the
                        // parents may not be in it.
                        depth: query.isEmpty ? _depthOf(f, index) : 0,
                        path: query.isEmpty ? null : _pathOf(f, index),
                      ),
                  if (matches.isEmpty)
                    ListTile(
                      enabled: false,
                      title: Text(
                        query.isEmpty
                            ? 'Nowhere to move it to.'
                            : 'No folder matches “$_query”.',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// How deep a folder sits, by walking the parents the tree itself uses.
///
/// Not by counting slashes in the path: Gmail's Trash is `[Gmail]/Trash`
/// and sits at the top of the tree, so counting would indent it under a
/// folder that is not shown at all.
int _depthOf(MailFolder folder, Map<String, MailFolder> index) {
  var depth = 0;
  var cursor = folder;
  while (depth < 4) {
    final parentId = cursor.parentId;
    if (parentId == null) break;
    final parent = index[parentId];
    if (parent == null) break;
    cursor = parent;
    depth++;
  }
  return depth;
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

class _FolderOption extends StatelessWidget {
  const _FolderOption({
    required this.folder,
    this.path,
    this.depth = 0,
  });

  final MailFolder folder;

  /// Where it lives, shown under the name. Null where the indentation
  /// already says it.
  final String? path;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final where = path;
    return ListTile(
      contentPadding: EdgeInsets.only(left: 16.0 + depth * 18, right: 16),
      leading: Icon(
        depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right,
        size: depth == 0 ? 24 : 18,
      ),
      title: Text(folder.displayName),
      subtitle: where != null && where != folder.displayName
          ? Text(where, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: () => Navigator.of(context).pop(folder.id),
    );
  }
}
