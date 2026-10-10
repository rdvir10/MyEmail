import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../folder_tree/folder_tile.dart' show folderIconFor;

/// Pick a destination for a message move.
///
/// Recent destinations come first, as in Outlook, because that is what gets
/// used; the folders follow as a tree, drawn the way the folder pane draws
/// them and opened where the pane has them open. Only folders that can
/// actually take a message can be chosen, which rules out Gmail's Drafts,
/// Sent and All Mail; a parent that cannot is still drawn, greyed, so what
/// is inside it keeps its place.
///
/// With more than one account, every mailbox is there under its own
/// heading, as in the pane: [accountId]'s, the one the message is in, open,
/// and the others shut until tapped, so a long list of another mailbox's
/// folders does not push its own off the screen. A recent folder or a
/// search's match in another mailbox says which.
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

  /// The mailboxes open in the tree, starting with the one the message is
  /// in.
  late final Set<String> _openMailboxes = {widget.accountId};

  String get accountId => widget.accountId;
  String get fromFolderId => widget.fromFolderId;
  int get messageCount => widget.messageCount;

  bool _takes(MailFolder f) =>
      f.capabilities.canAcceptMessages && f.id != fromFolderId;

  void _toggle(String folderId) => setState(() {
        if (!_open.remove(folderId)) _open.add(folderId);
      });

  void _toggleMailbox(String id) => setState(() {
        if (!_openMailboxes.remove(id)) _openMailboxes.add(id);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    final byAccount = ref.watch(foldersProvider).value ?? const {};
    final all = byAccount[accountId] ?? const <MailFolder>[];
    final compare = folderComparator(ref.watch(folderOrderProvider));

    // In the pane's order, and only those with folders to show: one still
    // loading, or that failed to, has nowhere to put anything yet.
    final mailboxes = [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if ((byAccount[a.id] ?? const <MailFolder>[]).isNotEmpty) a,
    ];
    // One mailbox is drawn as it always was, with no heading over it.
    final several =
        mailboxes.length > 1 && mailboxes.any((a) => a.id == accountId);
    final names = {for (final a in mailboxes) a.id: a.displayName};

    // Every folder a message could go to, the message's own mailbox first.
    final everywhere = [
      ..._inTreeOrder(all, compare),
      if (several)
        for (final a in mailboxes)
          if (a.id != accountId) ..._inTreeOrder(byAccount[a.id]!, compare),
    ];

    // Where a folder lives, with its mailbox in front where it is not the
    // message's own: "Gmail › Receipts".
    String where(MailFolder f) => f.accountId == accountId
        ? _pathOf(f, index)
        : '${names[f.accountId] ?? ''} › ${_pathOf(f, index)}';

    // Recents, filtered to folders that still exist, in mailboxes on the
    // sheet.
    final recents = <MailFolder>[
      for (final id in ref.watch(recentMoveTargetsProvider))
        if (index[id] case final f?)
          if ((f.accountId == accountId ||
                  (several && names.containsKey(f.accountId))) &&
              _takes(f))
            f,
    ];

    final query = _query.trim().toLowerCase();
    // A search is a flat list with each folder's path, since the parents
    // may not be in it; everything else is the tree.
    final matches = query.isEmpty
        ? const <MailFolder>[]
        : [
            for (final f in everywhere)
              if (_takes(f) &&
                  (f.displayName.toLowerCase().contains(query) ||
                      where(f).toLowerCase().contains(query)))
                f,
          ];

    _TreeRow treeRow(_TreeEntry entry) => _TreeRow(
          entry: entry,
          open: _open.contains(entry.folder.id),
          here: entry.folder.id == fromFolderId,
          onToggle: () => _toggle(entry.folder.id),
        );

    // The same height whatever is listed, so the search box stays near the
    // top of the screen and what it finds is listed under it. Sized to its
    // list, the sheet shrank to a handful of matches and sat them at the
    // bottom of the screen. Above the keyboard, not under it, and with its
    // top where it was before the keyboard came up.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        child: SizedBox(
          height: media.size.height * 0.85 - keyboard,
          child: Column(
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
              Expanded(
                child: ListView(
                  children: [
                    if (query.isNotEmpty) ...[
                      for (final f in matches)
                        _FolderOption(folder: f, path: where(f)),
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
                          _FolderOption(folder: f, path: where(f)),
                        const Divider(height: 1),
                        _SheetHeading(text: 'All folders', theme: theme),
                      ],
                      if (!several)
                        for (final entry in _treeRows(all, compare))
                          treeRow(entry)
                      else
                        for (final a in mailboxes) ...[
                          _MailboxRow(
                            account: a,
                            open: _openMailboxes.contains(a.id),
                            onToggle: () => _toggleMailbox(a.id),
                          ),
                          if (_openMailboxes.contains(a.id))
                            for (final entry
                                in _treeRows(byAccount[a.id]!, compare))
                              treeRow(entry),
                        ],
                      if (!everywhere.any(_takes))
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

/// A mailbox's heading in the tree, as the folder pane draws one: the arrow
/// that opens it, its colour, its name and address.
class _MailboxRow extends StatelessWidget {
  const _MailboxRow({
    required this.account,
    required this.open,
    required this.onToggle,
  });

  final Account account;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      key: ValueKey('move-mailbox-${account.id}'),
      onTap: onToggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: muted,
                semanticLabel: open ? 'Collapse' : 'Expand',
              ),
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Color(account.colorValue),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        account.displayName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: Text(
                        account.emailAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: muted.withValues(alpha: 0.7)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
