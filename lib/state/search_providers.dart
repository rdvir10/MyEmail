import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:convert';

import '../data/mail_engine.dart';
import '../data/ui_state_store.dart';
import '../domain/mail_message.dart';
import '../domain/search_refinement.dart';
import 'folder_tree.dart';
import 'meeting_providers.dart' show workWeekProvider;
import 'providers.dart';

export '../domain/search_refinement.dart';

/// What the search box holds and where it looks.
class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

/// Bumped when something elsewhere wants the search box focused.
///
/// A counter rather than a flag: the ribbon's Search button has to work the
/// second time it is pressed, and a flag that is already true reports no
/// change. The search bar watches this and takes focus when it moves.
class SearchFocusRequests extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state = state + 1;
}

final searchFocusRequestsProvider =
    NotifierProvider<SearchFocusRequests, int>(SearchFocusRequests.new);

/// Whether the search box has been asked for.
///
/// Not until it is: by the magnifier in the title bar, the ribbon's Search
/// button, or Ctrl+F. A box above every list spent a row of mail's worth of
/// screen on something done now and then. See [searchShownProvider], which
/// also keeps it out while it holds a search.
class SearchOpen extends Notifier<bool> {
  @override
  bool build() => false;

  /// Out, and focused, so typing can start at once.
  void open() {
    state = true;
    ref.read(searchFocusRequestsProvider.notifier).request();
  }

  /// Away, and the search with it: a box put away with words still in it
  /// would leave the list showing hits with nothing on screen saying why.
  /// The words are kept among the recent searches, and the filters go.
  void close() {
    ref
        .read(recentSearchesProvider.notifier)
        .remember(ref.read(searchQueryProvider));
    state = false;
    ref.read(searchQueryProvider.notifier).clear();
    ref.read(searchRefinementsProvider.notifier).clear();
  }
}

final searchOpenProvider =
    NotifierProvider<SearchOpen, bool>(SearchOpen.new);

/// Whether the search box is on screen: asked for, or holding a search.
final searchShownProvider = Provider<bool>(
  (ref) =>
      ref.watch(searchOpenProvider) ||
      ref.watch(searchQueryProvider).isNotEmpty,
);

final searchQueryProvider =
    NotifierProvider<SearchQuery, String>(SearchQuery.new);

/// Which part of a message the search looks in: everything, or the sender,
/// the subject or the body alone. Kept for the session, like the scope.
class SearchFieldSelection extends Notifier<SearchField> {
  @override
  SearchField build() => SearchField.all;

  void set(SearchField value) => state = value;
}

final searchFieldProvider =
    NotifierProvider<SearchFieldSelection, SearchField>(
  SearchFieldSelection.new,
);

/// Which scope the user picked: this folder, this account, or everything.
enum SearchScopeChoice { folder, account, everywhere }

class SearchScopeSelection extends Notifier<SearchScopeChoice> {
  @override
  SearchScopeChoice build() => SearchScopeChoice.folder;

  void set(SearchScopeChoice value) => state = value;
}

final searchScopeChoiceProvider =
    NotifierProvider<SearchScopeSelection, SearchScopeChoice>(
  SearchScopeSelection.new,
);

/// The scope to search, resolved against the folder currently open.
///
/// The unified Inbox is not a server folder, so "this folder" there means
/// everywhere; there is nothing else it could sensibly mean.
final searchScopeProvider = Provider<SearchScope>((ref) {
  final choice = ref.watch(searchScopeChoiceProvider);
  final folderId = ref.watch(effectiveSelectedFolderIdProvider);
  if (folderId == null || isSyntheticList(folderId)) {
    return const SearchScope.everywhere();
  }
  return switch (choice) {
    SearchScopeChoice.folder => SearchScope.folder(folderId),
    SearchScopeChoice.account =>
      SearchScope.account(ref.read(folderIndexProvider)[folderId]!.accountId),
    SearchScopeChoice.everywhere => const SearchScope.everywhere(),
  };
});

/// The search filters chosen, under the box: see [SearchRefinement].
class SearchRefinements extends Notifier<Set<SearchRefinement>> {
  @override
  Set<SearchRefinement> build() => const {};

  void toggle(SearchRefinement r) =>
      state = state.contains(r) ? ({...state}..remove(r)) : {...state, r};

  void set(Set<SearchRefinement> value) => state = value;

  void clear() => state = const {};
}

final searchRefinementsProvider =
    NotifierProvider<SearchRefinements, Set<SearchRefinement>>(
  SearchRefinements.new,
);

/// The last searches, newest first, offered when the box opens empty, as
/// Outlook's recent searches. Kept on this device.
class RecentSearches extends Notifier<List<String>> {
  static const kept = 8;

  @override
  List<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((previous, next) {
      if (previous == null) return;
      store.writeString(UiStateKeys.recentSearches, jsonEncode(next));
    });
    final raw = store.readString(UiStateKeys.recentSearches);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final json = jsonDecode(raw);
      return [
        for (final q in json is List ? json : const [])
          if (q is String && q.trim().isNotEmpty) q,
      ];
    } on FormatException {
      return const [];
    }
  }

  /// [query] first, once; two letters or more.
  void remember(String query) {
    final q = query.trim();
    if (q.length < 2) return;
    state = [
      q,
      for (final s in state)
        if (s.toLowerCase() != q.toLowerCase()) s,
    ].take(kept).toList();
  }

  void forgetAll() => state = const [];
}

final recentSearchesProvider =
    NotifierProvider<RecentSearches, List<String>>(RecentSearches.new);

/// The searches kept to run again, in the tree's Saved searches: see
/// [SavedSearch]. In the backup.
class SavedSearches extends Notifier<List<SavedSearch>> {
  @override
  List<SavedSearch> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((previous, next) {
      if (previous == null) return;
      store.writeString(
        UiStateKeys.savedSearches,
        jsonEncode([for (final s in next) s.toJson()]),
      );
    });
    return SavedSearch.listFromJson(
        store.readString(UiStateKeys.savedSearches));
  }

  void add(SavedSearch search) => state = [...state, search];

  void rename(String id, String name) => state = [
        for (final s in state)
          if (s.id == id) s.renamed(name) else s,
      ];

  void remove(String id) => state = [
        for (final s in state)
          if (s.id != id) s,
      ];

  static String newId() =>
      'ss-${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}';
}

final savedSearchesProvider =
    NotifierProvider<SavedSearches, List<SavedSearch>>(SavedSearches.new);

/// The search as it stands, kept as [name]: the words, the field and the
/// filters, and the scope as chosen in [folderId]'s list.
SavedSearch currentSearchAs(WidgetRef ref, String name) {
  final scope = ref.read(searchScopeProvider);
  return SavedSearch(
    id: SavedSearches.newId(),
    name: name,
    query: ref.read(searchQueryProvider).trim(),
    field: ref.read(searchFieldProvider),
    refinements: ref.read(searchRefinementsProvider),
    accountId: scope.accountId,
    folderId: scope.folderId,
  );
}

/// [saved] run again: its folder opened where it was saved for one, and
/// the search box put out with its words, field, filters and scope.
void runSavedSearch(WidgetRef ref, SavedSearch saved) {
  final index = ref.read(folderIndexProvider);
  if (saved.folderId != null && index.containsKey(saved.folderId)) {
    ref.read(selectedFolderIdProvider.notifier).select(saved.folderId);
    ref.read(searchScopeChoiceProvider.notifier).set(SearchScopeChoice.folder);
  } else if (saved.accountId != null) {
    final inbox = index.values
        .where((f) => f.accountId == saved.accountId && !f.isSynthetic)
        .firstOrNull;
    if (inbox != null) {
      ref.read(selectedFolderIdProvider.notifier).select(inbox.id);
    }
    ref.read(searchScopeChoiceProvider.notifier).set(SearchScopeChoice.account);
  } else {
    ref
        .read(searchScopeChoiceProvider.notifier)
        .set(SearchScopeChoice.everywhere);
  }
  ref.read(searchFieldProvider.notifier).set(saved.field);
  ref.read(searchRefinementsProvider.notifier).set(saved.refinements);
  ref.read(searchQueryProvider.notifier).set(saved.query);
  ref.read(searchOpenProvider.notifier).open();
}

/// What the server found for the search, or null when the box is empty:
/// [searchResultsProvider] narrows it by the filters.
///
/// A search that fails, with no server to be reached or every account
/// needing a sign-in, is said at once and never run again by itself:
/// Riverpod would otherwise run it ten times more over half a minute, every
/// folder's search each time, with a spinner under the box throughout.
/// Changing the words or the scope, or Try again, asks again. Read again
/// after a change to the mail: invalidate this one, not the narrowing.
final searchHitsProvider = FutureProvider<List<MailMessage>?>((ref) async {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) return null;

  // Debounce here rather than in a provider chain: simpler, and a cancelled
  // wait means no request was ever made.
  final completer = Completer<void>();
  final timer = Timer(const Duration(milliseconds: 350), completer.complete);
  ref.onDispose(() {
    timer.cancel();
    if (!completer.isCompleted) completer.complete();
  });
  await completer.future;

  final scope = ref.watch(searchScopeProvider);
  final field = ref.watch(searchFieldProvider);
  return ref
      .watch(mailEngineProvider)
      .searchMessages(query, scope, field: field);
}, retry: (_, _) => null);

/// Search results, or null when the box is empty: what the server found,
/// as the filters under the box leave it. Changing a filter asks nothing
/// again.
final searchResultsProvider = FutureProvider<List<MailMessage>?>((ref) async {
  final hits = await ref.watch(searchHitsProvider.future);
  if (hits == null) return null;
  return refineSearch(
    hits,
    ref.watch(searchRefinementsProvider),
    now: DateTime.now(),
    workWeek: ref.watch(workWeekProvider),
  );
}, retry: (_, _) => null);
