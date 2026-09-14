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

class _MoveToSheet extends ConsumerWidget {
  const _MoveToSheet({
    required this.accountId,
    required this.fromFolderId,
    required this.messageCount,
  });

  final String accountId;
  final String fromFolderId;
  final int messageCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    final all = ref.watch(foldersProvider).value?[accountId] ?? const [];
    final overrides = ref.watch(folderOrderProvider);

    final candidates = all
        .where((f) => f.capabilities.canAcceptMessages && f.id != fromFolderId)
        .toList()
      ..sort(folderComparator(overrides));

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
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (recents.isNotEmpty) ...[
                    _SheetHeading(text: 'Recent', theme: theme),
                    for (final f in recents)
                      _FolderOption(folder: f, showPath: true),
                    const Divider(height: 1),
                    _SheetHeading(text: 'All folders', theme: theme),
                  ],
                  for (final f in candidates)
                    if (!recentIds.contains(f.id))
                      _FolderOption(folder: f, showPath: f.parentId != null),
                  if (candidates.isEmpty)
                    const ListTile(
                      enabled: false,
                      title: Text('Nowhere to move it to.'),
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
  const _FolderOption({required this.folder, required this.showPath});

  final MailFolder folder;
  final bool showPath;

  @override
  Widget build(BuildContext context) {
    final path = displayPath(folder);
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(folder.displayName),
      subtitle: showPath && path != folder.displayName ? Text(path) : null,
      onTap: () => Navigator.of(context).pop(folder.id),
    );
  }
}
