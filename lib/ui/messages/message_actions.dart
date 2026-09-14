import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import 'move_to_sheet.dart';

/// Move and delete, shared by the swipe gestures, the message menu and the
/// drop-onto-a-folder gesture, so all three behave the same.
///
/// Each reports what happened in a snackbar, because the message leaves the
/// list and there is otherwise nothing to see. Failures put the row back and
/// say why.
class MessageActions {
  const MessageActions(this.ref, this.listId);

  final WidgetRef ref;

  /// The list the message is being acted on from: a folder, or the unified
  /// inbox. Not necessarily the folder the message lives in.
  final String listId;

  Future<void> moveWithPrompt(
    BuildContext context,
    List<MailMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    final accountId = messages.first.accountId;
    if (messages.any((m) => m.accountId != accountId)) {
      _say(context, 'Those messages are in different accounts.');
      return;
    }
    final target = await showMoveToSheet(
      context,
      accountId: accountId,
      fromFolderId: messages.first.folderId,
      messageCount: messages.length,
    );
    if (target == null || !context.mounted) return;
    await moveTo(context, messages, target);
  }

  Future<void> moveTo(
    BuildContext context,
    List<MailMessage> messages,
    String toFolderId,
  ) async {
    if (messages.isEmpty) return;
    final name = ref.read(folderIndexProvider)[toFolderId]?.displayName ?? '';
    try {
      await ref
          .read(messagesProvider(listId).notifier)
          .move([for (final m in messages) m.id], toFolderId);
      ref.read(recentMoveTargetsProvider.notifier).record(toFolderId);
      if (context.mounted) {
        _say(context, '${_count(messages.length)} moved to $name');
      }
    } catch (e) {
      if (context.mounted) _say(context, 'Could not move: $e');
    }
  }

  Future<void> delete(
    BuildContext context,
    List<MailMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    try {
      await ref
          .read(messagesProvider(listId).notifier)
          .delete([for (final m in messages) m.id]);
      if (context.mounted) _say(context, '${_count(messages.length)} deleted');
    } catch (e) {
      if (context.mounted) _say(context, 'Could not delete: $e');
    }
  }

  static String _count(int n) => n == 1 ? 'Message' : '$n messages';

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
