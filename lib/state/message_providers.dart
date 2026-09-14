import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import 'folder_tree.dart';
import 'providers.dart';

/// The messages shown for a folder, newest first.
///
/// The unified Inbox is not a server folder, so it is assembled here: each
/// account's Inbox is fetched in parallel and the lists are merged by date.
/// Milestone 4 turns this into a notifier that owns flag changes and moves;
/// for now it only reads.
final messagesProvider =
    FutureProvider.family<List<MailMessage>, String>((ref, folderId) async {
  final engine = ref.watch(mailEngineProvider);
  if (folderId != kUnifiedInboxId) return engine.loadMessages(folderId);

  final folders = await ref.watch(foldersProvider.future);
  final inboxes = <MailFolder>[
    for (final list in folders.values)
      for (final f in list)
        if (f.role == FolderRole.inbox) f,
  ];
  final lists = await Future.wait(inboxes.map((f) => engine.loadMessages(f.id)));
  return [for (final l in lists) ...l]..sort((a, b) => b.date.compareTo(a.date));
});

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
/// clears itself instead of needing to be cleared.
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
