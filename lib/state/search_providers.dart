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
