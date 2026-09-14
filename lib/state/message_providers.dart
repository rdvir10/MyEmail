import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import 'folder_tree.dart';
import 'providers.dart';

/// The messages shown for a folder, newest first, and the flag changes made
/// to them.
///
/// The unified Inbox is not a server folder, so it is assembled here: each
/// account's Inbox is fetched in parallel and the lists are merged by date.
///
/// Flag changes are optimistic: the list updates first, the engine is told,
/// and the change is rolled back if the engine refuses. The folder tree's
/// unread count is refreshed afterwards, and any other list that shows the
/// same message (the real folder behind a unified-inbox row, or vice versa)
/// is invalidated so it re-reads from the cache.
class Messages extends AsyncNotifier<List<MailMessage>> {
  Messages(this.folderId);

  final String folderId;

  @override
  Future<List<MailMessage>> build() async {
    final engine = ref.watch(mailEngineProvider);
    if (folderId != kUnifiedInboxId) return engine.loadMessages(folderId);

    final folders = await ref.watch(foldersProvider.future);
    final inboxes = <MailFolder>[
      for (final list in folders.values)
        for (final f in list)
          if (f.role == FolderRole.inbox) f,
    ];
    final lists =
        await Future.wait(inboxes.map((f) => engine.loadMessages(f.id)));
    return [for (final l in lists) ...l]
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> setRead(String messageId, bool isRead) =>
      _setFlags(messageId, isRead: isRead);

  Future<void> setFlagged(String messageId, bool isFlagged) =>
      _setFlags(messageId, isFlagged: isFlagged);

  Future<void> _setFlags(
    String messageId, {
    bool? isRead,
    bool? isFlagged,
  }) async {
    final current = state.value;
    if (current == null) return;
    final index = current.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final before = current[index];
    final after = before.copyWith(isRead: isRead, isFlagged: isFlagged);
    if (after.isRead == before.isRead && after.isFlagged == before.isFlagged) {
      return;
    }

    state = AsyncData([...current]..[index] = after);
    try {
      final engine = ref.read(mailEngineProvider);
      if (isRead != null) await engine.setRead(messageId, isRead);
      if (isFlagged != null) await engine.setFlagged(messageId, isFlagged);
    } catch (_) {
      state = AsyncData(current);
      rethrow;
    }

    if (isRead != null) {
      await ref.read(foldersProvider.notifier).refreshAccount(after.accountId);
    }
    // Keep the other view of this message honest.
    if (folderId == kUnifiedInboxId) {
      ref.invalidate(messagesProvider(after.folderId));
    } else {
      ref.invalidate(messagesProvider(kUnifiedInboxId));
    }
  }
}

final messagesProvider =
    AsyncNotifierProvider.family<Messages, List<MailMessage>, String>(
  Messages.new,
);

/// The message the user opened, if any.
class SelectedMessageId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedMessageIdProvider =
    NotifierProvider<SelectedMessageId, String?>(SelectedMessageId.new);

/// The opened message, resolved against the current folder's list. Null when
/// nothing is open or the folder changed underneath it, so a stale selection
/// clears itself instead of needing to be cleared. Because it is looked up
/// live, flag changes made in the list show in the reading pane at once.
final selectedMessageProvider = Provider<MailMessage?>((ref) {
  final id = ref.watch(selectedMessageIdProvider);
  final folderId = ref.watch(effectiveSelectedFolderIdProvider);
  if (id == null || folderId == null) return null;
  final messages = ref.watch(messagesProvider(folderId)).value;
  if (messages == null) return null;
  for (final m in messages) {
    if (m.id == id) return m;
  }
  return null;
});

final messageBodyProvider =
    FutureProvider.family<MailBody, String>((ref, messageId) {
  return ref.watch(mailEngineProvider).loadMessageBody(messageId);
});
