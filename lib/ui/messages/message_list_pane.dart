import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/folder_tree.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import 'message_tile.dart';

/// The list of messages in the selected folder.
///
/// Knows nothing about what happens when a message is opened: the phone
/// pushes a screen, the tablet fills the reading pane, and each host passes
/// the behaviour in through [onOpen].
class MessageListPane extends ConsumerWidget {
  const MessageListPane({super.key, required this.onOpen});

  final void Function(MailMessage message) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final folderId = ref.watch(effectiveSelectedFolderIdProvider);
    if (folderId == null) {
      return Center(
        child: Text('Select a folder', style: theme.textTheme.bodySmall),
      );
    }

    final folder = ref.watch(folderIndexProvider)[folderId];
    final isUnified = folderId == kUnifiedInboxId;
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final accountColors = {
      for (final a in accounts) a.id: Color(a.colorValue),
    };
    final selectedId = ref.watch(selectedMessageIdProvider);

    return ref.watch(messagesProvider(folderId)).when(
          loading: () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load messages.\n$e',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          data: (messages) {
            if (messages.isEmpty) {
              return Center(
                child: Text(
                  'Nothing in ${folder?.displayName ?? 'this folder'}',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            return ListView.separated(
              itemCount: messages.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 28),
              itemBuilder: (context, i) {
                final m = messages[i];
                return MessageTile(
                  key: ValueKey(m.id),
                  message: m,
                  isSelected: m.id == selectedId,
                  accountColor: isUnified ? accountColors[m.accountId] : null,
                  onTap: () {
                    ref.read(selectedMessageIdProvider.notifier).select(m.id);
                    onOpen(m);
                  },
                );
              },
            );
          },
        );
  }
}
