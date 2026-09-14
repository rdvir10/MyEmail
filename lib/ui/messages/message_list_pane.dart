import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/folder_drag.dart';
import '../../state/folder_tree.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';
import '../../state/search_providers.dart';
import '../quick_steps/quick_steps_screen.dart';
import 'message_actions.dart';
import 'message_tile.dart';
import 'search_bar.dart';

/// The list of messages in the selected folder.
///
/// Knows nothing about what happens when a message is opened: the phone
/// pushes a screen, the tablet fills the reading pane, and each host passes
/// the behaviour in through [onOpen].
///
/// Gestures per row: tap opens, swipe left deletes, swipe right moves (via
/// the Move-to sheet), long-press lifts the message so it can be dropped on
/// a folder in the tree, and a long-press menu is offered where there is no
/// tree to drop onto.
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
    final actions = MessageActions(ref, folderId);
    final searching = ref.watch(searchQueryProvider).trim().isNotEmpty;

    final body = searching
        ? _searchResults(context, ref, actions, accountColors, selectedId)
        : _folderList(context, ref, folderId, folder, isUnified,
            accountColors, selectedId, actions);

    return Column(
      children: [
        const MessageSearchBar(),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }

  /// Search hits, which may come from any folder, so each row shows where it
  /// lives. Swipe and drag are deliberately not offered here: the row's list
  /// is the search, not a folder, and moving out of a result set reads as a
  /// bug rather than a feature.
  Widget _searchResults(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    Map<String, Color> accountColors,
    String? selectedId,
  ) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    return ref.watch(searchResultsProvider).when(
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
              child: Text('Search failed.\n$e',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
            ),
          ),
          data: (results) {
            if (results == null) return const SizedBox.shrink();
            if (results.isEmpty) {
              return Center(
                child: Text('No messages found',
                    style: theme.textTheme.bodySmall),
              );
            }
            return ListView.separated(
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 28),
              itemBuilder: (context, i) {
                final m = results[i];
                return MessageTile(
                  key: ValueKey('search:${m.id}'),
                  message: m,
                  isSelected: m.id == selectedId,
                  accountColor: accountColors[m.accountId],
                  folderLabel: index[m.folderId]?.displayName,
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

  Widget _folderList(
    BuildContext context,
    WidgetRef ref,
    String folderId,
    dynamic folder,
    bool isUnified,
    Map<String, Color> accountColors,
    String? selectedId,
    MessageActions actions,
  ) {
    final theme = Theme.of(context);
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
                final tile = MessageTile(
                  message: m,
                  isSelected: m.id == selectedId,
                  accountColor: isUnified ? accountColors[m.accountId] : null,
                  onTap: () {
                    ref.read(selectedMessageIdProvider.notifier).select(m.id);
                    onOpen(m);
                  },
                  onLongPress: () => _showMessageMenu(context, ref, actions, m),
                );
                return _SwipeableRow(
                  key: ValueKey(m.id),
                  message: m,
                  actions: actions,
                  child: LongPressDraggable<DraggedMessages>(
                    data: DraggedMessages([m]),
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: _DragFeedback(message: m),
                    childWhenDragging: Opacity(opacity: 0.35, child: tile),
                    child: tile,
                  ),
                );
              },
            );
          },
        );
  }

  Future<void> _showMessageMenu(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    MailMessage message,
  ) async {
    final steps = ref.read(quickStepsProvider);
    final folderIndex = ref.read(folderIndexProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            for (final step in steps)
              ListTile(
                leading: Icon(iconForQuickStep(step)),
                title: Text(step.name),
                subtitle: Text(describeQuickStep(step, folderIndex)),
                onTap: () => Navigator.of(context).pop('qs:${step.id}'),
              ),
            if (steps.isNotEmpty) const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move to…'),
              onTap: () => Navigator.of(context).pop('move'),
            ),
            ListTile(
              leading: Icon(
                message.isRead
                    ? Icons.mark_email_unread_outlined
                    : Icons.mark_email_read_outlined,
              ),
              title: Text(
                message.isRead ? 'Mark as unread' : 'Mark as read',
              ),
              onTap: () => Navigator.of(context).pop('read'),
            ),
            ListTile(
              leading: Icon(
                message.isFlagged ? Icons.flag : Icons.flag_outlined,
              ),
              title: Text(message.isFlagged ? 'Remove flag' : 'Flag'),
              onTap: () => Navigator.of(context).pop('flag'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Delete'),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
            const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final notifier = ref.read(messagesProvider(actions.listId).notifier);

    if (choice.startsWith('qs:')) {
      final step = steps.firstWhere((s) => s.id == choice.substring(3));
      try {
        await runQuickStep(
          step: step,
          notifier: notifier,
          message: message,
          onMoved: (folderId) =>
              ref.read(recentMoveTargetsProvider.notifier).record(folderId),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('${step.name} applied')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
                SnackBar(content: Text('${step.name} failed: $e')));
        }
      }
      return;
    }

    switch (choice) {
      case 'move':
        await actions.moveWithPrompt(context, [message]);
      case 'read':
        await notifier.setRead(message.id, !message.isRead);
      case 'flag':
        await notifier.setFlagged(message.id, !message.isFlagged);
      case 'delete':
        await actions.delete(context, [message]);
    }
  }
}

/// Swipe right to move, swipe left to delete.
///
/// The move swipe opens the Move-to sheet and only removes the row once a
/// destination is chosen, so a dismissed sheet leaves the list as it was.
class _SwipeableRow extends StatelessWidget {
  const _SwipeableRow({
    super.key,
    required this.message,
    required this.actions,
    required this.child,
  });

  final MailMessage message;
  final MessageActions actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('swipe:${message.id}'),
      background: _SwipeBackground(
        alignment: Alignment.centerLeft,
        color: scheme.primaryContainer,
        foreground: scheme.onPrimaryContainer,
        icon: Icons.drive_file_move_outline,
        label: 'Move',
      ),
      secondaryBackground: _SwipeBackground(
        alignment: Alignment.centerRight,
        color: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
        icon: Icons.delete_outline,
        label: 'Delete',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          await actions.delete(context, [message]);
        } else {
          await actions.moveWithPrompt(context, [message]);
        }
        // The list state removes the row itself, so the widget never
        // dismisses; that keeps one source of truth for what is in the list.
        return false;
      },
      child: child,
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.foreground,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final Color foreground;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.message});

  final MailMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: const Offset(16, -28),
      child: Material(
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mail_outline, size: 18,
                    color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    message.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
