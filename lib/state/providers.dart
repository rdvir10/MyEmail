import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../data/sample/sample_mail_engine.dart';
import '../domain/account.dart';
import '../domain/mail_folder.dart';
import 'folder_tree.dart';

/// Swapped for the real IMAP engine in milestone 3. Everything above this line
/// stays unchanged when that happens, which is the point of the seam.
final mailEngineProvider = Provider<MailEngine>((ref) => SampleMailEngine());

final accountsProvider = FutureProvider<List<Account>>((ref) async {
  return ref.watch(mailEngineProvider).loadAccounts();
});

/// Folders for every account, keyed by account id.
final foldersProvider =
    FutureProvider<Map<String, List<MailFolder>>>((ref) async {
  final engine = ref.watch(mailEngineProvider);
  final accounts = await ref.watch(accountsProvider.future);
  final result = <String, List<MailFolder>>{};
  for (final account in accounts) {
    result[account.id] = await engine.loadFolders(account.id);
  }
  return result;
});

/// Which folders are expanded.
///
/// In-memory for now. Milestone 3 persists this to Drift, along with the last
/// selected folder, so the tree comes back the way it was left.
class ExpandedFolders extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void toggle(String folderId) {
    final next = Set<String>.from(state);
    if (!next.remove(folderId)) next.add(folderId);
    state = next;
  }

  void expand(String folderId) => state = {...state, folderId};

  void collapseAll() => state = <String>{};
}

final expandedFoldersProvider =
    NotifierProvider<ExpandedFolders, Set<String>>(ExpandedFolders.new);

class FavoriteFolders extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void toggle(String folderId) {
    final next = Set<String>.from(state);
    if (!next.remove(folderId)) next.add(folderId);
    state = next;
  }

  bool contains(String folderId) => state.contains(folderId);
}

final favoriteFoldersProvider =
    NotifierProvider<FavoriteFolders, Set<String>>(FavoriteFolders.new);

/// The folder-search box contents.
class FolderSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

final folderSearchQueryProvider =
    NotifierProvider<FolderSearchQuery, String>(FolderSearchQuery.new);

/// The folder whose messages are shown. Null until folders have loaded, at
/// which point it defaults to the unified Inbox or the single account's Inbox.
class SelectedFolderId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? folderId) => state = folderId;
}

final selectedFolderIdProvider =
    NotifierProvider<SelectedFolderId, String?>(SelectedFolderId.new);

/// The rendered tree. Recomputed whenever folders, expand state, favourites or
/// the search query change.
final treeRowsProvider = Provider<List<TreeRow>>((ref) {
  final accounts = ref.watch(accountsProvider).value ?? const [];
  final folders = ref.watch(foldersProvider).value ?? const {};
  return buildTreeRows(
    FolderTreeInput(
      accounts: accounts,
      foldersByAccount: folders,
      expandedIds: ref.watch(expandedFoldersProvider),
      favoriteIds: ref.watch(favoriteFoldersProvider),
      searchQuery: ref.watch(folderSearchQueryProvider),
    ),
  );
});

/// Look up a folder by id across all accounts, including the synthetic
/// unified Inbox.
final folderByIdProvider = Provider.family<MailFolder?, String>((ref, id) {
  final folders = ref.watch(foldersProvider).value ?? const {};
  if (id == kUnifiedInboxId) return buildUnifiedInbox(folders);
  for (final list in folders.values) {
    for (final f in list) {
      if (f.id == id) return f;
    }
  }
  return null;
});
