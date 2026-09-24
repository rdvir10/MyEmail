import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import '../domain/message_move.dart';
import 'display_providers.dart';
import '../domain/message_sort.dart';
import 'folder_tree.dart';
import 'providers.dart';
import 'search_providers.dart';

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

  /// Counts the changes made to this list from here: a delete, a move, a
  /// flag, another page loaded.
  ///
  /// A refresh runs behind the list and answers a second or two later,
  /// from a folder read before any of that happened. Writing that answer
  /// over the top would undo it — a deleted message back on screen, a page
  /// of older mail gone again — so a refresh whose count has moved on is
  /// dropped instead.
  int _changes = 0;

  /// Messages taken off the list whose move or delete has not finished.
  /// The server still has them until it does, so a page loaded meanwhile
  /// must not put them back.
  final Set<String> _removing = {};

  @override
  Future<List<MailMessage>> build() async {
    final engine = ref.watch(mailEngineProvider);
    // False once this build is over, whether the list was thrown away or
    // merely rebuilt. A refresh started by an earlier build has nothing
    // useful left to say, and writing to a provider that is gone throws.
    var current = true;
    ref.onDispose(() => current = false);
    // Read, not watched: paging appends in place, and the depth is only
    // here so a refresh comes back as deep as the list had been scrolled
    // rather than snapping back to the first page.
    final limit = pageSize * ref.read(listDepthProvider(folderId)).pages;
    final ids = await _folderIds();

    // What is already known, which costs a database read and no network.
    // On a work account the sync behind [loadMessages] is a dozen separate
    // requests to Microsoft, and waiting for all of them before drawing
    // mail that is already on this device is seconds of blank screen for
    // nothing.
    final known = _merged(await Future.wait([
      for (final id in ids) engine.cachedMessages(id, limit: limit),
    ]));
    if (known.isEmpty) {
      // A folder opened for the first time, or an empty one: there is
      // nothing to show early, so the server is worth waiting for.
      final (lists, _) = await _loadEach({for (final id in ids) id: limit});
      return _merged(lists);
    }
    _refresh(ids, limit, _changes, () => current);
    return known;
  }

  /// Ask the server, and correct the list if the answer differs.
  ///
  /// Deliberately not awaited, and deliberately quiet about failure: the
  /// list on screen came from this device and is still worth showing when
  /// the network is not answering.
  void _refresh(
    List<String> ids,
    int limit,
    int changes,
    bool Function() current,
  ) {
    unawaited(() async {
      final List<MailMessage> fresh;
      try {
        final (lists, _) = await _loadEach({for (final id in ids) id: limit});
        fresh = _merged(lists);
      } catch (_) {
        return;
      }
      if (!current() || changes != _changes) return;
      if (!_sameList(state.value, fresh)) state = AsyncData(fresh);
    }());
  }

  /// Each folder's messages from the server, down to its limit, or what
  /// is stored for a folder whose account did not answer. The second half
  /// says whether any fell back like that.
  ///
  /// Not one Future.wait over the lot, which fails as a whole: a unified
  /// Inbox with one account whose sign-in had expired refreshed none of
  /// them, and opened with nothing stored it showed only that account's
  /// error. Throws only when every folder failed, which for a list of one
  /// folder is that folder's own error, as before.
  Future<(List<List<MailMessage>>, bool)> _loadEach(
    Map<String, int> limits,
  ) async {
    final engine = ref.read(mailEngineProvider);
    Object? error;
    StackTrace? trace;
    var failed = 0;
    final lists = await Future.wait([
      for (final MapEntry(key: id, value: limit) in limits.entries)
        () async {
          try {
            return await engine.loadMessages(id, limit: limit);
          } catch (e, st) {
            failed++;
            error ??= e;
            trace ??= st;
            try {
              return await engine.cachedMessages(id, limit: limit);
            } catch (_) {
              return const <MailMessage>[];
            }
          }
        }(),
    ]);
    if (failed > 0 && failed == limits.length) {
      Error.throwWithStackTrace(error!, trace!);
    }
    return (lists, failed > 0);
  }

  static List<MailMessage> _merged(List<List<MailMessage>> lists) {
    if (lists.length == 1) return lists.single;
    return [for (final l in lists) ...l]..sort(newestFirst);
  }

  /// Same messages in the same order and the same state. Compared so an
  /// unchanged folder does not redraw the list, which on a long list
  /// costs a frame and loses the keyboard's place in it.
  static bool _sameList(List<MailMessage>? a, List<MailMessage> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < b.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
  /// Each folder behind the list is asked for everything down to a page
  /// past the messages of its own already here, so a unified Inbox pages
  /// every account at once. From the top, not from an offset: the sync
  /// behind the page brings in whatever arrived since the list was loaded,
  /// which shifts every offset down. Asked from where the list ended, the
  /// page was mostly that new mail, and the newest of it never showed at
  /// all. Anything already shown is skipped, and so is anything on its way
  /// out, which the server still has. A page with nothing new in it marks
  /// the list exhausted, which is how a stale folder total stops the list
  /// asking for ever.
  Future<void> loadMore() async {
    final depth = ref.read(listDepthProvider(folderId).notifier);
    if (state.value == null || !depth.begin()) return;
    try {
      final shown = state.value!;
      final (pages, fellBack) = await _loadEach({
        for (final id in await _folderIds())
          id: shown.where((m) => m.folderId == id).length + pageSize,
      });
      // The list may have been refreshed while the page was on its way.
      final current = state.value ?? shown;
      final have = {for (final m in current) m.id, ..._removing};
      final fresh = [
        for (final page in pages)
          for (final m in page)
            if (have.add(m.id)) m,
      ];
      if (fresh.isEmpty) {
        // Nothing more is only the end when every account said so.
        depth.end(exhausted: !fellBack);
        return;
      }
      // New mail can be among it, and belongs at the top.
      final merged = [...current, ...fresh]..sort(newestFirst);
      _changes++;
      state = AsyncData(merged);
      depth.end(grew: true);
    } catch (_) {
      depth.end();
      rethrow;
    }
  }

  /// Whether this list has [messageId] in it right now.
  bool holds(String messageId) =>
      state.value?.any((m) => m.id == messageId) ?? false;

  Future<void> setRead(String messageId, bool isRead) =>
      _setFlags(messageId, isRead: isRead);

  Future<void> setFlagged(String messageId, bool isFlagged) =>
      _setFlags(messageId, isFlagged: isFlagged);

  /// Move messages out of this list. The rows go at once and come back if
  /// the engine refuses, so a failed move never silently loses a message
  /// from view.
  Future<List<MessageMove>> move(List<String> messageIds, String toFolderId) =>
      _removeThen(
        messageIds,
        () => ref.read(mailEngineProvider).moveMessages(messageIds, toFolderId),
        touchedFolderIds: [toFolderId],
      );

  Future<List<MessageMove>> delete(List<String> messageIds) => _removeThen(
        messageIds,
        () => ref.read(mailEngineProvider).deleteMessages(messageIds),
      );

  Future<List<MessageMove>> _removeThen(
    List<String> messageIds,
    Future<List<MessageMove>> Function() op, {
    List<String> touchedFolderIds = const [],
  }) async {
    final current = state.value;
    if (current == null || messageIds.isEmpty) return const [];
    final ids = messageIds.toSet();
    final removed = [
      for (final m in current)
        if (ids.contains(m.id)) m,
    ];
    if (removed.isEmpty) return const [];

    _changes++;
    state = AsyncData([
      for (final m in current)
        if (!ids.contains(m.id)) m,
    ]);
    final removing = [for (final m in removed) m.id];
    _removing.addAll(removing);
    final List<MessageMove> moves;
    try {
      moves = await op();
    } on PartialMove catch (part) {
      // Some went: those stay gone, and only the rest come back.
      final went = part.moved.toSet();
      _putBack([
        for (final m in removed)
          if (!went.contains(m.id)) m,
      ], current);
      _afterRemoval(
        [
          for (final m in removed)
            if (went.contains(m.id)) m,
        ],
        [...touchedFolderIds, for (final m in part.done) m.toFolderId],
      );
      rethrow;
    } catch (_) {
      _putBack(removed, current);
      rethrow;
    } finally {
      _removing.removeAll(removing);
    }
    // Where they went too, which for a delete only the engine knows: a
    // Trash list opened earlier otherwise lacked them until pulled, while
    // its count in the tree had already gone up.
    _afterRemoval(
      removed,
      [...touchedFolderIds, for (final m in moves) m.toFolderId],
    );
    return moves;
  }

  /// Put [rows] back where they were in [snapshot], into the list as it is
  /// now.
  ///
  /// Not the snapshot itself. Restoring that undid whatever else changed
  /// meanwhile: with two deletes on the way, the first failing brought the
  /// second's rows back as ghosts already in Trash, and the second failing
  /// took the first's back out, though it had never gone.
  void _putBack(List<MailMessage> rows, List<MailMessage> snapshot) {
    if (rows.isEmpty) return;
    final now = state.value ?? const <MailMessage>[];
    final back = {for (final m in rows) m.id};
    final nowById = {for (final m in now) m.id: m};
    final before = {for (final m in snapshot) m.id};
    state = AsyncData([
      for (final m in snapshot)
        if (back.contains(m.id)) m else ?nowById[m.id],
      for (final m in now)
        if (!before.contains(m.id)) m,
    ]);
  }

  void _afterRemoval(
    List<MailMessage> removed,
    List<String> touchedFolderIds,
  ) {
    if (removed.isEmpty) return;

    // The folder counts follow, but nothing on screen is waiting for them:
    // refreshing an account is another folder listing over the network, and
    // awaiting it here is why a delete took seconds to finish.
    for (final accountId in removed.map((m) => m.accountId).toSet()) {
      unawaited(ref
          .read(foldersProvider.notifier)
          .refreshAccount(accountId)
          .catchError((Object _) {}));
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

    _changes++;
    state = AsyncData([...current]..[index] = after);
    try {
      final engine = ref.read(mailEngineProvider);
      if (isRead != null) await engine.setRead(messageId, isRead);
      if (isFlagged != null) await engine.setFlagged(messageId, isFlagged);
    } catch (_) {
      // This message back as it was, and nothing else: the rest of the list
      // may have moved on meanwhile.
      final now = state.value;
      final at = now?.indexWhere((m) => m.id == messageId) ?? -1;
      if (now != null && at >= 0) {
        state = AsyncData([...now]
          ..[at] = now[at].copyWith(
            isRead: before.isRead,
            isFlagged: before.isFlagged,
          ));
      }
      rethrow;
    }

    // The count moves now, and the server's follows without anything
    // waiting for it. Awaited, marking thirty messages read was thirty
    // folder listings end to end.
    if (isRead != null) {
      final folders = ref.read(foldersProvider.notifier)
        ..countUnread(after.folderId, isRead ? -1 : 1);
      unawaited(
        folders.refreshAccount(after.accountId).catchError((Object _) {}),
      );
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
  // Newest first too, not left in the order the engine hands over. That is
  // arrival order in one folder, so a message undone, moved in or delivered
  // late sat at the top weeks old, under a day bar out of sequence, while
  // the unified Inbox and search had it where its date put it.
  return sortMessages(messages, ref.watch(displayProvider).sort);
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

/// The opened message, resolved against the current folder's list, then
/// against the search results. Null when nothing is open or the folder
/// changed underneath it, so a stale selection clears itself instead of
/// needing to be cleared. Because it is looked up live, flag changes made in
/// the list show in the reading pane at once.
///
/// The search results are the second place because a hit can live in any
/// folder of any account, or further back than the list has loaded. On the
/// tablet, where tapping a row selects it rather than opening a screen of its
/// own, such a hit resolved to nothing: the reading pane stayed empty and
/// the ribbon's actions greyed out. Clearing the search clears it the same
/// way changing folder does.
final selectedMessageProvider = Provider<MailMessage?>((ref) {
  final id = ref.watch(selectedMessageIdProvider);
  final folderId = ref.watch(effectiveSelectedFolderIdProvider);
  if (id == null || folderId == null) return null;
  final messages = ref.watch(messagesProvider(folderId)).value;
  for (final m in messages ?? const <MailMessage>[]) {
    if (m.id == id) return m;
  }
  final hits = ref.watch(searchResultsProvider).value;
  for (final m in hits ?? const <MailMessage>[]) {
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
  /// Emptied when another folder opens. The ticks are on rows of the list
  /// that was showing: carried over, the bar counted messages nobody could
  /// see, Delete found none of them in the new list, and ticking two more
  /// there made the bar say five and the delete say two.
  @override
  Set<String> build() {
    ref.watch(effectiveSelectedFolderIdProvider);
    return const {};
  }

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
