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

  /// Move messages out of this list. The rows go at once and come back if
  /// the engine refuses, so a failed move never silently loses a message
  /// from view.
  Future<void> move(List<String> messageIds, String toFolderId) =>
      _removeThen(
        messageIds,
        () => ref.read(mailEngineProvider).moveMessages(messageIds, toFolderId),
        touchedFolderIds: [toFolderId],
      );

  Future<void> delete(List<String> messageIds) => _removeThen(
        messageIds,
        () => ref.read(mailEngineProvider).deleteMessages(messageIds),
      );

  Future<void> _removeThen(
    List<String> messageIds,
    Future<void> Function() op, {
    List<String> touchedFolderIds = const [],
  }) async {
    final current = state.value;
    if (current == null || messageIds.isEmpty) return;
    final ids = messageIds.toSet();
    final removed = [
      for (final m in current)
        if (ids.contains(m.id)) m,
    ];
    if (removed.isEmpty) return;

    state = AsyncData([
      for (final m in current)
        if (!ids.contains(m.id)) m,
    ]);
    try {
      await op();
    } catch (_) {
      state = AsyncData(current);
      rethrow;
    }

    for (final accountId in removed.map((m) => m.accountId).toSet()) {
      await ref.read(foldersProvider.notifier).refreshAccount(accountId);
    }
    // Every other list that showed these messages, and the destination.
    for (final folderId in {
      ...removed.map((m) => m.folderId),
      ...touchedFolderIds,
      kUnifiedInboxId,
    }) {
      if (folderId != this.folderId) ref.invalidate(messagesProvider(folderId));
    }
  }

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
/// Which message is open, and whether the person chose it.
///
/// The second half matters because opening a message marks it read. A folder
/// that opens with its newest message already selected would mark that message
/// read every time someone walked past the Inbox, which is a good way to lose
/// mail you meant to come back to. So a selection the app made for you shows
/// the message and leaves it unread; touching it in any way makes it yours,
/// and then it reads as opened.
class SelectedMessageId extends Notifier<String?> {
  @override
  String? build() => null;

  /// True when the person picked this message rather than the app landing on
  /// it for them.
  bool chosenByPerson = true;

  void select(String? id, {bool byPerson = true}) {
    chosenByPerson = byPerson;
    state = id;
  }

  /// The app's selection became the person's, because they acted on it.
  void claim() => chosenByPerson = true;
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

/// Where each folder was left, so coming back returns you to it.
///
/// In memory rather than on disk. A remembered id that no longer exists is
/// harmless — the lookup simply finds nothing — but carrying one across a
/// restart means carrying it across a resync too, and landing somewhere
/// arbitrary is worse than landing at the top.
class LastOpenedInFolder extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  void remember(String folderId, String messageId) =>
      state = {...state, folderId: messageId};

  void forget(String folderId) =>
      state = {for (final e in state.entries) if (e.key != folderId) e.key: e.value};
}

final lastOpenedInFolderProvider =
    NotifierProvider<LastOpenedInFolder, Map<String, String>>(
  LastOpenedInFolder.new,
);

/// The messages ticked for a bulk action, empty when not selecting.
///
/// Emptiness is the mode: there is no separate "in selection mode" flag to
/// fall out of step with what is ticked. Leaving the last one therefore ends
/// selection, which is what unticking everything already looks like.
class SelectedMessageIds extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String id) {
    final next = Set<String>.from(state);
    if (!next.remove(id)) next.add(id);
    state = next;
  }

  void start(String id) => state = {id};

  /// Adds to what is ticked rather than replacing it, so taking one
  /// screenful and then another leaves both ticked, and nothing anyone
  /// ticked by hand quietly disappears.
  void addAll(Iterable<String> ids) => state = {...state, ...ids};

  void clear() => state = const {};

  bool contains(String id) => state.contains(id);
}

final selectedMessageIdsProvider =
    NotifierProvider<SelectedMessageIds, Set<String>>(SelectedMessageIds.new);

/// Whether the list is showing checkboxes.
final isSelectingProvider =
    Provider<bool>((ref) => ref.watch(selectedMessageIdsProvider).isNotEmpty);

final messageBodyProvider =
    FutureProvider.family<MailBody, String>((ref, messageId) {
  return ref.watch(mailEngineProvider).loadMessageBody(messageId);
});
