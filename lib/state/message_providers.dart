import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import 'display_providers.dart';
import '../domain/message_sort.dart';
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

  /// How many messages one page of the list is. A folder loads this many
  /// to start with and [loadMore] adds this many at a time.
  static const pageSize = 50;

  @override
  Future<List<MailMessage>> build() async {
    final engine = ref.watch(mailEngineProvider);
    // Read, not watched: paging appends in place, and the depth is only
    // here so a refresh comes back as deep as the list had been scrolled
    // rather than snapping back to the first page.
    final limit = pageSize * ref.read(listDepthProvider(folderId)).pages;
    final lists = await Future.wait([
      for (final id in await _folderIds()) engine.loadMessages(id, limit: limit),
    ]);
    if (lists.length == 1) return lists.single;
    return [for (final l in lists) ...l]..sort(newestFirst);
  }

  /// The server folders behind this list: one, or every Inbox for the
  /// unified one.
  ///
  /// Watched for the set of Inboxes only. The folders provider changes
  /// every time an unread count does — marking one message read refreshes
  /// it — and a list that rebuilt on that would resync every account and
  /// redraw itself on each arrow key press, which is what it used to do.
  Future<List<String>> _folderIds() async {
    if (folderId != kUnifiedInboxId) return [folderId];
    final joined = await ref.watch(
      foldersProvider.selectAsync((folders) => inboxIdsOf(folders).join('\n')),
    );
    return joined.isEmpty ? const [] : joined.split('\n');
  }

  /// The next page of older messages, added under the ones shown.
  ///
  /// Each folder behind the list is asked for what follows the messages
  /// of its own already here, so a unified Inbox pages every account at
  /// once. Anything already shown is skipped: a sync between two pages can
  /// push new mail in at the top and shift what an offset means. A page
  /// with nothing new in it marks the list exhausted, which is how a stale
  /// folder total stops the list asking for ever.
  Future<void> loadMore() async {
    final depth = ref.read(listDepthProvider(folderId).notifier);
    if (state.value == null || !depth.begin()) return;
    try {
      final engine = ref.read(mailEngineProvider);
      final shown = state.value!;
      final pages = await Future.wait([
        for (final id in await _folderIds())
          engine.loadMessages(
            id,
            offset: shown.where((m) => m.folderId == id).length,
            limit: pageSize,
          ),
      ]);
      // The list may have been refreshed while the page was on its way.
      final current = state.value ?? shown;
      final have = {for (final m in current) m.id};
      final fresh = [
        for (final page in pages)
          for (final m in page)
            if (have.add(m.id)) m,
      ];
      if (fresh.isEmpty) {
        depth.end(exhausted: true);
        return;
      }
      final merged = [...current, ...fresh];
      if (folderId == kUnifiedInboxId) merged.sort(newestFirst);
      state = AsyncData(merged);
      depth.end(grew: true);
    } catch (_) {
      depth.end();
      rethrow;
    }
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

/// Every account's Inbox, in account order.
List<String> inboxIdsOf(Map<String, List<MailFolder>> folders) => [
      for (final list in folders.values)
        for (final f in list)
          if (f.role == FolderRole.inbox) f.id,
    ];

/// Newest first, and a fixed order among messages with the same date, so
/// two lists built from the same messages come out the same. Dart's sort
/// is not stable, and two accounts' sample mail shares timestamps: sorted
/// on date alone, rows swapped places on every rebuild.
int newestFirst(MailMessage a, MailMessage b) {
  final byDate = b.date.compareTo(a.date);
  if (byDate != 0) return byDate;
  final byAccount = a.accountId.compareTo(b.accountId);
  if (byAccount != 0) return byAccount;
  return b.uid.compareTo(a.uid);
}

/// A folder's messages in the order the list shows them.
///
/// One place, because the rows, the arrow keys and "select what is on
/// screen" have to agree about what order they are in: sorting only where
/// the rows are built would leave the keyboard walking the old one.
final sortedMessagesProvider =
    Provider.family<List<MailMessage>, String>((ref, folderId) {
  final messages = ref.watch(messagesProvider(folderId)).value ?? const [];
  final sort = ref.watch(displayProvider).sort;
  if (sort == MessageSort.dateNewest) {
    // What the engine already hands over, and what the paging appends to.
    return messages;
  }
  return sortMessages(messages, sort);
});

/// How far down a folder's list has been paged.
///
/// Kept apart from the list because the list is rebuilt on every refresh:
/// after a sync or a return to the app it re-reads the folder, and a depth
/// held inside it would be lost, snapping a list scrolled to page six back
/// to page one.
class ListDepthState {
  const ListDepthState({
    this.pages = 1,
    this.exhausted = false,
    this.loading = false,
  });

  /// How many pages of [Messages.pageSize] the list holds.
  final int pages;

  /// A page came back with nothing new: there is no older mail to fetch,
  /// whatever the folder's total says.
  final bool exhausted;

  /// A page is on its way. One at a time, or the same rows come twice.
  final bool loading;

  ListDepthState copyWith({int? pages, bool? exhausted, bool? loading}) =>
      ListDepthState(
        pages: pages ?? this.pages,
        exhausted: exhausted ?? this.exhausted,
        loading: loading ?? this.loading,
      );
}

class ListDepth extends Notifier<ListDepthState> {
  ListDepth(this.folderId);

  final String folderId;

  @override
  ListDepthState build() => const ListDepthState();

  /// Claims the next page. False if one is already loading or there is
  /// nothing more to load.
  bool begin() {
    if (state.loading || state.exhausted) return false;
    state = state.copyWith(loading: true);
    return true;
  }

  void end({bool grew = false, bool exhausted = false}) {
    state = state.copyWith(
      loading: false,
      pages: grew ? state.pages + 1 : null,
      exhausted: exhausted ? true : null,
    );
  }
}

final listDepthProvider =
    NotifierProvider.family<ListDepth, ListDepthState, String>(ListDepth.new);

/// Whether a folder's list has older messages left to fetch.
///
/// The folder's own total says so, until a page comes back empty. The
/// total is what the tree shows next to the folder, so the list and the
/// tree agree about whether there is more.
final listHasMoreProvider = Provider.family<bool, String>((ref, folderId) {
  final depth = ref.watch(listDepthProvider(folderId));
  if (depth.exhausted) return false;
  final shown = ref.watch(messagesProvider(folderId)).value;
  if (shown == null) return false;
  final total = ref.watch(folderIndexProvider)[folderId]?.totalCount ?? 0;
  return shown.length < total;
});

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

  /// Unticks these and leaves the rest; unticking a whole thread must not
  /// clear a message ticked elsewhere.
  void removeAll(Iterable<String> ids) {
    final gone = ids.toSet();
    state = {for (final id in state) if (!gone.contains(id)) id};
  }

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
