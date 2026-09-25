import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../domain/mail_message.dart';
import 'folder_tree.dart';
import 'providers.dart';

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
  void close() {
    state = false;
    ref.read(searchQueryProvider.notifier).clear();
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
  if (folderId == null || folderId == kUnifiedInboxId) {
    return const SearchScope.everywhere();
  }
  return switch (choice) {
    SearchScopeChoice.folder => SearchScope.folder(folderId),
    SearchScopeChoice.account =>
      SearchScope.account(ref.read(folderIndexProvider)[folderId]!.accountId),
    SearchScopeChoice.everywhere => const SearchScope.everywhere(),
  };
});

/// Search results, or null when the box is empty.
final searchResultsProvider = FutureProvider<List<MailMessage>?>((ref) async {
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
  return ref.watch(mailEngineProvider).searchMessages(query, scope);
});
