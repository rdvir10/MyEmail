import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/folder_tree.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/search_providers.dart';
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
    final (held, elsewhere) = _split(messages);
    try {
      if (held.isNotEmpty) {
        await ref
            .read(messagesProvider(listId).notifier)
            .move([for (final m in held) m.id], toFolderId);
      }
      if (elsewhere.isNotEmpty) {
        await ref
            .read(mailEngineProvider)
            .moveMessages([for (final m in elsewhere) m.id], toFolderId);
        await _afterEngineChange(elsewhere, touched: [toFolderId]);
      }
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
    final (held, elsewhere) = _split(messages);
    try {
      if (held.isNotEmpty) {
        await ref
            .read(messagesProvider(listId).notifier)
            .delete([for (final m in held) m.id]);
      }
      if (elsewhere.isNotEmpty) {
        await ref
            .read(mailEngineProvider)
            .deleteMessages([for (final m in elsewhere) m.id]);
        await _afterEngineChange(elsewhere);
      }
      if (context.mounted) _say(context, '${_count(messages.length)} deleted');
    } catch (e) {
      if (context.mounted) _say(context, 'Could not delete: $e');
    }
  }

  /// Read or unread, for several at once.
  Future<void> setRead(List<MailMessage> messages, bool isRead) async {
    final (held, elsewhere) = _split(messages);
    final notifier = ref.read(messagesProvider(listId).notifier);
    for (final m in held) {
      await notifier.setRead(m.id, isRead);
    }
    if (elsewhere.isNotEmpty) {
      final engine = ref.read(mailEngineProvider);
      for (final m in elsewhere) {
        await engine.setRead(m.id, isRead);
      }
      await _afterEngineChange(elsewhere);
    }
  }

  Future<void> setFlagged(List<MailMessage> messages, bool isFlagged) async {
    final (held, elsewhere) = _split(messages);
    final notifier = ref.read(messagesProvider(listId).notifier);
    for (final m in held) {
      await notifier.setFlagged(m.id, isFlagged);
    }
    if (elsewhere.isNotEmpty) {
      final engine = ref.read(mailEngineProvider);
      for (final m in elsewhere) {
        await engine.setFlagged(m.id, isFlagged);
      }
      await _afterEngineChange(elsewhere);
    }
  }

  /// The messages this list holds, and the rest.
  ///
  /// A search hit can live in any folder of any account, and the list's
  /// notifier only knows the rows it is showing: asked about a message it
  /// does not hold, it does nothing, quietly. Those go to the engine
  /// directly, and every list that might show them is re-read afterwards.
  (List<MailMessage>, List<MailMessage>) _split(List<MailMessage> messages) {
    final held = {
      for (final m in ref.read(messagesProvider(listId)).value ?? const [])
        m.id,
    };
    return (
      [for (final m in messages) if (held.contains(m.id)) m],
      [for (final m in messages) if (!held.contains(m.id)) m],
    );
  }

  Future<void> _afterEngineChange(
    List<MailMessage> changed, {
    List<String> touched = const [],
  }) async {
    for (final folderId in {
      ...changed.map((m) => m.folderId),
      ...touched,
      kUnifiedInboxId,
    }) {
      ref.invalidate(messagesProvider(folderId));
    }
    ref.invalidate(searchResultsProvider);
    for (final accountId in changed.map((m) => m.accountId).toSet()) {
      await ref.read(foldersProvider.notifier).refreshAccount(accountId);
    }
  }

  static String _count(int n) => n == 1 ? 'Message' : '$n messages';

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
