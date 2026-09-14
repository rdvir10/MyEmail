import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../data/sample/sample_mail_engine.dart';
import '../data/ui_state_store.dart';
import '../domain/account.dart';
import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import 'folder_tree.dart';

/// Swapped for the real IMAP engine in milestone 3. Everything above this line
/// stays unchanged when that happens, which is the point of the seam.
final mailEngineProvider = Provider<MailEngine>((ref) => SampleMailEngine());

/// Where expand state, favourites, ordering and the last folder are kept.
/// main() overrides this with the shared_preferences store; tests and the
/// bare default remember within one run only.
final uiStateStoreProvider =
    Provider<UiStateStore>((ref) => MemoryUiStateStore());

/// The configured accounts. Adding one verifies it with the engine first;
/// folders reload on their own because they watch this.
class Accounts extends AsyncNotifier<List<Account>> {
  @override
  Future<List<Account>> build() => ref.watch(mailEngineProvider).loadAccounts();

  Future<Account> add({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) async {
    final account = await ref.read(mailEngineProvider).addAccount(
          displayName: displayName,
          emailAddress: emailAddress,
          provider: provider,
          secret: secret,
        );
    state = AsyncData([...state.value ?? const [], account]);
    return account;
  }

  Future<void> remove(String accountId) async {
    await ref.read(mailEngineProvider).removeAccount(accountId);
    state = AsyncData([
      for (final a in state.value ?? const <Account>[])
        if (a.id != accountId) a,
    ]);
  }
}

final accountsProvider =
    AsyncNotifierProvider<Accounts, List<Account>>(Accounts.new);

/// Folders for every account, keyed by account id, and the only place that
/// mutates them.
///
/// Each mutation goes to the engine, remaps any UI state that referenced the
/// affected folder ids, then reloads that account's list. Reloading rather
/// than patching locally keeps this correct for the real IMAP engine, where a
/// rename can cascade in ways the client cannot fully predict. Optimistic
/// updates with rollback land here in milestone 4.
class Folders extends AsyncNotifier<Map<String, List<MailFolder>>> {
  @override
  Future<Map<String, List<MailFolder>>> build() async {
    final engine = ref.watch(mailEngineProvider);
    final accounts = await ref.watch(accountsProvider.future);
    // Accounts load in parallel: against a real server each one is a network
    // round trip, and there is no reason to wait on them one at a time.
    final lists = await Future.wait(
      accounts.map((a) => engine.loadFolders(a.id)),
    );
    return {
      for (final (i, account) in accounts.indexed) account.id: lists[i],
    };
  }

  Future<FolderRename> rename(String folderId, String newName) async {
    final result =
        await ref.read(mailEngineProvider).renameFolder(folderId, newName);
    _remapIds(result);
    await _reloadAccount(result.folder.accountId);
    return result;
  }

  Future<FolderRename> move(String folderId, String? newParentId) async {
    final result =
        await ref.read(mailEngineProvider).moveFolder(folderId, newParentId);
    _remapIds(result);
    await _reloadAccount(result.folder.accountId);
    return result;
  }

  Future<void> delete(String folderId) async {
    final folder = _current(folderId);
    if (folder == null) return;
    final doomed = _subtreeIds(folder);
    await ref.read(mailEngineProvider).deleteFolder(folderId);
    ref.read(expandedFoldersProvider.notifier).removeAll(doomed);
    ref.read(favoriteFoldersProvider.notifier).removeAll(doomed);
    ref.read(folderOrderProvider.notifier).removeAll(doomed);
    ref.read(recentMoveTargetsProvider.notifier).removeAll(doomed);
    final selected = ref.read(selectedFolderIdProvider);
    if (selected != null && doomed.contains(selected)) {
      ref.read(selectedFolderIdProvider.notifier).select(null);
    }
    await _reloadAccount(folder.accountId);
  }

  Future<MailFolder> create({
    required String accountId,
    required String name,
    String? parentId,
  }) async {
    final created = await ref.read(mailEngineProvider).createFolder(
          accountId: accountId,
          name: name,
          parentId: parentId,
        );
    if (parentId != null) {
      ref.read(expandedFoldersProvider.notifier).expand(parentId);
    }
    await _reloadAccount(accountId);
    return created;
  }

  Future<void> markAllRead(String folderId) async {
    final folder = _current(folderId);
    if (folder == null) return;
    await ref.read(mailEngineProvider).markAllRead(folderId);
    await _reloadAccount(folder.accountId);
  }

  Future<void> empty(String folderId) async {
    final folder = _current(folderId);
    if (folder == null) return;
    await ref.read(mailEngineProvider).emptyFolder(folderId);
    await _reloadAccount(folder.accountId);
  }

  /// Re-read one account's folders, e.g. after a flag change moved a count.
  Future<void> refreshAccount(String accountId) => _reloadAccount(accountId);

  // ---------------------------------------------------------------------------

  MailFolder? _current(String folderId) {
    for (final list in state.value?.values ?? const <List<MailFolder>>[]) {
      for (final f in list) {
        if (f.id == folderId) return f;
      }
    }
    return null;
  }

  Set<String> _subtreeIds(MailFolder root) {
    final prefix = '${root.path}/';
    return {
      root.id,
      for (final f in state.value?[root.accountId] ?? const <MailFolder>[])
        if (f.path.startsWith(prefix)) f.id,
    };
  }

  void _remapIds(FolderRename r) {
    ref.read(expandedFoldersProvider.notifier).remap(r);
    ref.read(favoriteFoldersProvider.notifier).remap(r);
    ref.read(folderOrderProvider.notifier).remap(r);
    ref.read(recentMoveTargetsProvider.notifier).remap(r);
    ref.read(selectedFolderIdProvider.notifier).remap(r);
  }

  Future<void> _reloadAccount(String accountId) async {
    final current = state.value;
    if (current == null) return;
    final fresh = await ref.read(mailEngineProvider).loadFolders(accountId);
    state = AsyncData({...current, accountId: fresh});
  }
}

final foldersProvider =
    AsyncNotifierProvider<Folders, Map<String, List<MailFolder>>>(Folders.new);

/// Every folder by id, including the synthetic unified Inbox when it applies.
/// One map built per change beats a linear scan on every lookup.
final folderIndexProvider = Provider<Map<String, MailFolder>>((ref) {
  final folders = ref.watch(foldersProvider).value ?? const {};
  final accounts = ref.watch(accountsProvider).value ?? const [];
  final index = <String, MailFolder>{
    for (final list in folders.values)
      for (final f in list) f.id: f,
  };
  if (accounts.length > 1) {
    index[kUnifiedInboxId] = buildUnifiedInbox(folders);
  }
  return index;
});

/// A set of folder ids that survives renames, deletes and restarts.
abstract class FolderIdSet extends Notifier<Set<String>> {
  String get storageKey;

  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeIds(storageKey, next));
    return store.readIds(storageKey);
  }

  void toggle(String folderId) {
    final next = Set<String>.from(state);
    if (!next.remove(folderId)) next.add(folderId);
    state = next;
  }

  bool contains(String folderId) => state.contains(folderId);

  void removeAll(Iterable<String> ids) => state = state.difference(ids.toSet());

  void remap(FolderRename r) => state = state.map(r.remap).toSet();
}

/// Which folders are expanded, remembered across restarts so the tree comes
/// back the way it was left.
class ExpandedFolders extends FolderIdSet {
  @override
  String get storageKey => UiStateKeys.expanded;

  void expand(String folderId) => state = {...state, folderId};

  void collapseAll() => state = <String>{};
}

final expandedFoldersProvider =
    NotifierProvider<ExpandedFolders, Set<String>>(ExpandedFolders.new);

class FavoriteFolders extends FolderIdSet {
  @override
  String get storageKey => UiStateKeys.favorites;
}

final favoriteFoldersProvider =
    NotifierProvider<FavoriteFolders, Set<String>>(FavoriteFolders.new);

/// Local ordering of user folders, by id. IMAP has no notion of folder order,
/// so this lives only on the device and overrides the engine's default.
class FolderOrder extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeOrder(UiStateKeys.order, next));
    return store.readOrder(UiStateKeys.order);
  }

  /// Fix the order of one sibling group. Every id in [orderedIds] gets its
  /// position; ids elsewhere are untouched.
  void setOrder(List<String> orderedIds) {
    state = {
      ...state,
      for (final (i, id) in orderedIds.indexed) id: i,
    };
  }

  void removeAll(Iterable<String> ids) {
    final gone = ids.toSet();
    state = {
      for (final e in state.entries)
        if (!gone.contains(e.key)) e.key: e.value,
    };
  }

  void remap(FolderRename r) =>
      state = {for (final e in state.entries) r.remap(e.key): e.value};
}

final folderOrderProvider =
    NotifierProvider<FolderOrder, Map<String, int>>(FolderOrder.new);

/// The last folders messages were moved into, most recent first.
///
/// Outlook's Move-to sheet puts these at the top, which is most of what
/// anyone ever uses. Capped at ten and persisted like the rest of the UI
/// state; ids that no longer exist are filtered when the sheet is built.
class RecentMoveTargets extends Notifier<List<String>> {
  static const maxEntries = 10;

  @override
  List<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) =>
        store.writeString(UiStateKeys.recentMoves, next.join(' ')));
    final raw = store.readString(UiStateKeys.recentMoves) ?? '';
    return raw.isEmpty ? const [] : raw.split(' ');
  }

  void record(String folderId) {
    state = [
      folderId,
      ...state.where((id) => id != folderId),
    ].take(maxEntries).toList();
  }

  void remap(FolderRename r) => state = [
        for (final id in state) r.remap(id),
      ];

  void removeAll(Iterable<String> ids) {
    final gone = ids.toSet();
    state = [
      for (final id in state)
        if (!gone.contains(id)) id,
    ];
  }
}

final recentMoveTargetsProvider =
    NotifierProvider<RecentMoveTargets, List<String>>(RecentMoveTargets.new);

/// The folder-search box contents.
class FolderSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

final folderSearchQueryProvider =
    NotifierProvider<FolderSearchQuery, String>(FolderSearchQuery.new);

/// The folder the user explicitly chose, remembered across restarts. Null
/// means "nothing chosen yet", in which case
/// [effectiveSelectedFolderIdProvider] supplies a default.
class SelectedFolderId extends Notifier<String?> {
  @override
  String? build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(UiStateKeys.selected, next));
    return store.readString(UiStateKeys.selected);
  }

  void select(String? folderId) => state = folderId;

  void remap(FolderRename r) {
    final current = state;
    if (current != null) state = r.remap(current);
  }
}

final selectedFolderIdProvider =
    NotifierProvider<SelectedFolderId, String?>(SelectedFolderId.new);

/// What to show when nothing has been chosen: the unified Inbox with several
/// accounts, otherwise the single account's Inbox found by role. Never by list
/// position, which the server does not promise.
final defaultFolderIdProvider = Provider<String?>((ref) {
  final accounts = ref.watch(accountsProvider).value ?? const [];
  final folders = ref.watch(foldersProvider).value;
  if (folders == null || folders.isEmpty) return null;
  if (accounts.length > 1) return kUnifiedInboxId;
  final list = accounts.isEmpty
      ? folders.values.first
      : folders[accounts.first.id] ?? folders.values.first;
  return list.firstWhereOrNull((f) => f.role == FolderRole.inbox)?.id ??
      list.firstOrNull?.id;
});

/// The folder actually shown: the user's choice if it still exists, otherwise
/// the default. Derived rather than assigned, so there is no listener to miss
/// the moment folders arrive, and a deleted selection falls back on its own.
final effectiveSelectedFolderIdProvider = Provider<String?>((ref) {
  final chosen = ref.watch(selectedFolderIdProvider);
  if (chosen != null && ref.watch(folderIndexProvider).containsKey(chosen)) {
    return chosen;
  }
  return ref.watch(defaultFolderIdProvider);
});

/// The rendered tree. Recomputed whenever folders, expand state, favourites,
/// ordering or the search query change.
final treeRowsProvider = Provider<List<TreeRow>>((ref) {
  final accounts = ref.watch(accountsProvider).value ?? const [];
  final folders = ref.watch(foldersProvider).value ?? const {};
  return buildTreeRows(
    FolderTreeInput(
      accounts: accounts,
      foldersByAccount: folders,
      expandedIds: ref.watch(expandedFoldersProvider),
      favoriteIds: ref.watch(favoriteFoldersProvider),
      orderOverrides: ref.watch(folderOrderProvider),
      searchQuery: ref.watch(folderSearchQueryProvider),
    ),
  );
});
