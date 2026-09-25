import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/account_store.dart';
import '../data/credential_store.dart';
import '../data/auth/google_oauth.dart';
import '../data/auth/google_oauth_config.dart';
import '../data/auth/microsoft_oauth.dart';
import '../data/auth/oauth_config.dart';
import '../data/auth/oauth_redirects.dart';
import '../data/auth/oauth_token.dart';
import '../data/mail_engine.dart';
import '../data/sample/sample_mail_engine.dart';
import '../data/ui_state_store.dart';
import '../domain/account.dart';
import '../domain/error_report.dart';
import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import 'folder_tree.dart';
import 'quick_steps.dart';
import 'widget_providers.dart';

/// Swapped for the real IMAP engine in milestone 3. Everything above this line
/// stays unchanged when that happens, which is the point of the seam.
final mailEngineProvider = Provider<MailEngine>((ref) => SampleMailEngine());

/// Which Microsoft app registration this build signs in against.
///
/// Comes from [microsoftClientId], which is baked in at build time. It is a
/// provider anyway so that a widget test can supply one and exercise the
/// screens as a configured build sees them — otherwise every test would meet
/// the "not configured yet" branch and the real path would go uncovered.
final microsoftClientIdProvider = Provider<String>((ref) => microsoftClientId);

/// How the app signs in to Microsoft.
///
/// A provider rather than a constructor call so a widget test can drive the
/// sign-in screen without a network, and so a build can be pointed at a
/// different app registration.
final microsoftOAuthProvider = Provider<MicrosoftOAuth>((ref) {
  final oauth = MicrosoftOAuth(clientId: ref.watch(microsoftClientIdProvider));
  ref.onDispose(oauth.close);
  return oauth;
});

/// Which Google Cloud client this build signs in against; see
/// [microsoftClientIdProvider] for why it is a provider.
final googleClientIdProvider = Provider<String>((ref) => googleClientId);

/// How the app signs in to Google.
final googleOAuthProvider = Provider<GoogleOAuth>((ref) {
  final oauth = GoogleOAuth(clientId: ref.watch(googleClientIdProvider));
  ref.onDispose(oauth.close);
  return oauth;
});

/// The redirects Android hands the app after a sign-in in the browser. One
/// for the app: the channel it listens on has one handler.
final oauthRedirectsProvider = Provider<OAuthRedirects>((ref) => OAuthRedirects());

/// Opens a page in the phone's browser, as a tab over the app where the
/// browser offers that, and answers whether anything opened.
///
/// A provider so a widget test can see what would have opened and open
/// nothing. Google's sign-in page has to open here rather than in a
/// WebView, which Google refuses to sign anyone in from.
final openInBrowserProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => (uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
    } catch (_) {
      // No browser that takes a tab: the ordinary one, below.
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  },
);

/// Where account secrets live.
///
/// The engine has always had one; backup needs the same instance, because an
/// encrypted export reads the secrets straight out of it. main() overrides
/// this with the Keystore-backed store.
final credentialStoreProvider =
    Provider<CredentialStore>((ref) => MemoryCredentialStore());

/// The account records, as stored.
///
/// The engine has held this all along; it needed a provider of its own once
/// backup arrived, which reads and writes the account list without going
/// through the engine. main() overrides it with the shared_preferences store,
/// the same instance the engine was handed.
final accountStoreProvider =
    Provider<AccountStore>((ref) => MemoryAccountStore());

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

  /// Finish a Microsoft sign-in. The token has already been obtained; this
  /// is what proves it against the server and stores the account.
  Future<Account> addOAuth({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    final account = await ref.read(mailEngineProvider).addOAuthAccount(
          displayName: displayName,
          emailAddress: emailAddress,
          provider: provider,
          token: token,
          signedInAs: signedInAs,
        );
    state = AsyncData([...state.value ?? const [], account]);
    return account;
  }

  /// Rename or recolour an account.
  ///
  /// Named `edit` rather than `update`: AsyncNotifier already has an `update`
  /// with a different meaning, and overriding it with this signature is a
  /// compile error rather than something to discover at runtime.
  Future<Account> edit({
    required String accountId,
    String? displayName,
    int? colorValue,
    String? senderName,
  }) async {
    final updated = await ref.read(mailEngineProvider).updateAccount(
          accountId: accountId,
          displayName: displayName,
          colorValue: colorValue,
          senderName: senderName,
        );
    state = AsyncData([
      for (final a in state.value ?? const <Account>[])
        if (a.id == accountId) updated else a,
    ]);
    return updated;
  }

  /// Sign an account in again without losing anything cached under it.
  ///
  /// Invalidates the folder list afterwards so the tree reloads on a
  /// connection that now works, rather than sitting on whatever the last
  /// failed sync left behind.
  Future<void> signInAgain({
    required String accountId,
    String? appPassword,
    OAuthToken? token,
    String? signedInAs,
  }) async {
    final engine = ref.read(mailEngineProvider);
    if (token != null) {
      await engine.updateOAuthToken(
        accountId: accountId,
        token: token,
        signedInAs: signedInAs,
      );
      // An app-password account that just signed in with a token is an
      // OAuth account now, and the record says so; the list follows it.
      state = AsyncData(await engine.loadAccounts());
    } else if (appPassword != null) {
      await engine.updateAppPassword(
        accountId: accountId,
        secret: appPassword,
      );
    } else {
      throw ArgumentError('signInAgain needs either a password or a token');
    }
    // The tree is the caller's to refresh: it watches the accounts, so this
    // notifier cannot invalidate it (Riverpod refuses the circle, in a
    // debug build by throwing after the new sign-in was already stored).
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
  /// Counts the changes made to the tree from here, so a listing that was
  /// already on its way does not undo a rename or a new folder.
  int _changes = 0;

  @override
  Future<Map<String, List<MailFolder>>> build() async {
    final engine = ref.watch(mailEngineProvider);
    final accounts = await ref.watch(accountsProvider.future);
    var current = true;
    ref.onDispose(() => current = false);

    // The tree as it was last seen, which costs nothing. Listing a work
    // mailbox is several requests to Microsoft and everything waits on it:
    // no folders means no folder chosen, which means the phone shows
    // "Select a folder" for as long as the listing takes.
    final stored = await Future.wait([
      for (final a in accounts) engine.cachedFolders(a.id),
    ]);
    final known = {
      for (final (i, account) in accounts.indexed) account.id: stored[i],
    };
    if (known.values.any((folders) => folders.isNotEmpty)) {
      final changes = _changes;
      unawaited(() async {
        final (fresh, errors) = await _list(accounts);
        if (!current || changes != _changes) return;
        ref.read(folderLoadErrorsProvider.notifier).replace(errors);
        state = AsyncData(fresh);
      }());
      return known;
    }

    final (fresh, errors) = await _list(accounts);
    ref.read(folderLoadErrorsProvider.notifier).replace(errors);
    return fresh;
  }

  /// Every account's folders, from its server.
  ///
  /// In parallel, and each account's failure stays its own.
  ///
  /// This was a plain Future.wait over the lot, which rejects the moment any
  /// one of them does. One account with a stale sign-in therefore blanked
  /// the entire folder tree: every other account's folders vanished and the
  /// pane showed that one account's error, which reads as the app being
  /// broken for mailboxes that are working perfectly.
  Future<(Map<String, List<MailFolder>>, Map<String, AccountProblem>)> _list(
    List<Account> accounts,
  ) async {
    final engine = ref.read(mailEngineProvider);
    final errors = <String, AccountProblem>{};
    final lists = await Future.wait(
      accounts.map((a) async {
        try {
          return await engine.loadFolders(a.id);
        } catch (e) {
          errors[a.id] = AccountProblem(account: a, error: e);
          // The folders as last seen, under the error. An expired sign-in
          // used to empty the account a second after launch, taking its
          // mail out of the unified Inbox and the open folder with it.
          try {
            return await engine.cachedFolders(a.id);
          } catch (_) {
            return const <MailFolder>[];
          }
        }
      }),
    );
    return (
      {for (final (i, account) in accounts.indexed) account.id: lists[i]},
      errors,
    );
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
    ref.read(hiddenFoldersProvider.notifier).removeAll(doomed);
    ref.read(folderOrderProvider.notifier).removeAll(doomed);
    ref.read(recentMoveTargetsProvider.notifier).removeAll(doomed);
    ref.read(quickStepsProvider.notifier).dropFoldersIn(doomed);
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

  /// One message in [folderId] read (-1) or unread (+1), counted at once.
  /// The refresh after it puts the server's own count in its place.
  void countUnread(String folderId, int change) {
    final all = state.value;
    if (all == null) return;
    state = AsyncData({
      for (final MapEntry(:key, :value) in all.entries)
        key: [
          for (final f in value)
            f.id == folderId
                ? f.copyWith(
                    unreadCount: (f.unreadCount + change).clamp(0, 1 << 30),
                  )
                : f,
        ],
    });
  }

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
    // Without this a renamed folder quietly reappears: the set still holds the
    // id it had before, and nothing matches the new one.
    ref.read(hiddenFoldersProvider.notifier).remap(r);
    ref.read(folderOrderProvider.notifier).remap(r);
    ref.read(recentMoveTargetsProvider.notifier).remap(r);
    ref.read(quickStepsProvider.notifier).remapFolder(r);
    ref.read(selectedFolderIdProvider.notifier).remap(r);
    unawaited(_remapWidgets(r));
  }

  /// Home-screen widgets follow the folder too, and are redrawn under its
  /// new id. Not awaited: the tree has its answer, and a widget a moment
  /// behind is no worse than a rename that waits on the home screen.
  Future<void> _remapWidgets(FolderRename r) async {
    final store = ref.read(widgetStateStoreProvider);
    final widgets = ref.read(mailboxWidgetsProvider);
    final engine = ref.read(mailEngineProvider);
    try {
      if (await store.remapFolders(r.remap)) await widgets.refresh(engine);
    } catch (e) {
      debugPrint('[myemail] could not move a widget to the renamed folder: $e');
    }
  }

  Future<void> _reloadAccount(String accountId) async {
    if (state.value == null) return;
    _changes++;
    final fresh = await ref.read(mailEngineProvider).loadFolders(accountId);
    // The counts are refreshed without anything waiting for them, so the
    // tree may be gone by the time the server answers — a folder switched,
    // a window closed. Writing to a provider that has been disposed throws.
    if (!ref.mounted) return;
    // Into the tree as it is now, not as it was before the wait: two
    // accounts refreshing together each wrote back the other's old counts,
    // and an account removed meanwhile came back.
    final latest = state.value;
    final stillThere = (ref.read(accountsProvider).value ?? const <Account>[])
        .any((a) => a.id == accountId);
    if (latest == null || !stillThere) return;
    state = AsyncData({...latest, accountId: fresh});
  }
}

final foldersProvider =
    AsyncNotifierProvider<Folders, Map<String, List<MailFolder>>>(Folders.new);

/// One account's failure, kept whole.
///
/// The error object and not just its sentence, because what the app can offer
/// to do about it is decided by the type. Matching on message text instead
/// would mean a remedy silently stops being offered the day someone rewords a
/// sentence.
@immutable
class AccountProblem {
  const AccountProblem({required this.account, required this.error});

  final Account account;
  final Object error;

  /// The engine's own failures carry a sentence written for a person already.
  /// Anything else is a bug rather than a condition, and shows as itself.
  String get message => switch (error) {
        AuthenticationFailed(:final message) => message,
        ConnectionFailed(:final message) => message,
        _ => '$error',
      };

  ErrorRemedy get remedy => remedyFor(error);

  /// The same failure in the shape every screen shows.
  ProblemReport get asReport =>
      ProblemReport(doing: doing, error: error, account: account);

  /// What the app was doing. Used as the report's first line and as an
  /// issue title, so it reads as a sentence either way.
  String get doing => 'Loading the folders for ${account.displayName}';

  String report({
    String? appVersion,
    int? build,
    bool redactAddress = false,
  }) =>
      buildErrorReport(
        doing: doing,
        error: error,
        account: account,
        appVersion: appVersion,
        build: build,
        redactAddress: redactAddress,
      );
}

/// What went wrong for an account, by account id, or empty if nothing did.
///
/// Kept apart from [foldersProvider]'s own error state on purpose: an
/// AsyncValue has room for one error, and putting an account's failure there
/// would mean the whole tree is an error whenever any single account is. The
/// tree has to keep working for the accounts that are fine.
class FolderLoadErrors extends Notifier<Map<String, AccountProblem>> {
  @override
  Map<String, AccountProblem> build() => const {};

  void replace(Map<String, AccountProblem> errors) =>
      state = Map.unmodifiable(errors);
}

final folderLoadErrorsProvider =
    NotifierProvider<FolderLoadErrors, Map<String, AccountProblem>>(
  FolderLoadErrors.new,
);

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
/// Folders put out of the way. Persisted, unlike the reveal toggle: hiding is
/// a decision about the tree, and it should still hold tomorrow.
class HiddenFolders extends FolderIdSet {
  @override
  String get storageKey => UiStateKeys.hidden;

  /// Hide it, and drop it from Favourites on the way.
  ///
  /// A favourite you cannot see is a contradiction: the Favourites section
  /// would either show it, defeating the hiding, or silently skip it, leaving
  /// a favourite that exists nowhere. Better to unfavourite it outright, which
  /// is visible and undoable.
  void hide(String folderId) {
    ref.read(favoriteFoldersProvider.notifier).removeAll({folderId});
    if (!state.contains(folderId)) state = {...state, folderId};
  }

  void unhide(String folderId) => state = {
        for (final id in state)
          if (id != folderId) id,
      };
}

final hiddenFoldersProvider =
    NotifierProvider<HiddenFolders, Set<String>>(HiddenFolders.new);

/// Reveal hidden folders, dimmed, so there is a way back to them.
///
/// Not persisted, on purpose. This is a temporary look behind the curtain,
/// not a second preference: coming back tomorrow to find everything you hid
/// on screen again would make hiding pointless.
class ShowHiddenFolders extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void set(bool value) => state = value;
}

final showHiddenFoldersProvider =
    NotifierProvider<ShowHiddenFolders, bool>(ShowHiddenFolders.new);

/// How many folders the user has chosen to hide. Drives the row at the bottom
/// of the tree, which is the only way back; it is not shown when zero,
/// because a control for nothing is just noise.
final hiddenFolderCountProvider = Provider<int>((ref) {
  return countHiddenFolders(
    ref.watch(foldersProvider).value ?? const {},
    ref.watch(hiddenFoldersProvider),
  );
});

class ExpandedFolders extends FolderIdSet {
  @override
  String get storageKey => UiStateKeys.expanded;

  void expand(String folderId) => state = {...state, folderId};

  void collapseAll() => state = <String>{};
}

final expandedFoldersProvider =
    NotifierProvider<ExpandedFolders, Set<String>>(ExpandedFolders.new);

/// Accounts whose folders are folded away in the tree.
///
/// Holds account ids rather than folder ids, so it deliberately does not take
/// part in the folder-rename remapping the other sets do.
class CollapsedAccounts extends FolderIdSet {
  @override
  String get storageKey => UiStateKeys.collapsedAccounts;
}

final collapsedAccountsProvider =
    NotifierProvider<CollapsedAccounts, Set<String>>(CollapsedAccounts.new);

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

  /// What separates folder ids in the single string this list is stored as.
  ///
  /// NUL, because a folder id can contain very nearly anything a mail server
  /// allows in a path, and this is the one byte it cannot. Written as an
  /// escape on purpose: this was a literal NUL character in the source, which
  /// worked but made the file read as binary to grep and to editors, and left
  /// two invisible bytes that any tool touching the file could have quietly
  /// dropped, changing the separator and scrambling the stored list.
  static const recentMoveSeparator = '\u0000';

  @override
  List<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) =>
        store.writeString(UiStateKeys.recentMoves, next.join(recentMoveSeparator)));
    final raw = store.readString(UiStateKeys.recentMoves) ?? '';
    return raw.isEmpty ? const [] : raw.split(recentMoveSeparator);
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
  /// Off once [showOnly] has been used, for the rest of this copy of the app.
  var _remember = true;

  @override
  String? build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) {
      if (_remember) store.writeString(UiStateKeys.selected, next);
    });
    return store.readString(UiStateKeys.selected);
  }

  void select(String? folderId) => state = folderId;

  /// Shows [folderId] without making it the folder the app opens on.
  ///
  /// For a window opened on one message, whose folder is only the list its
  /// actions go through. Remembered like a choice, the next cold start
  /// opened on that message's folder instead of the one chosen in the app.
  void showOnly(String? folderId) {
    _remember = false;
    state = folderId;
  }

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
  final index = ref.watch(folderIndexProvider);
  final folder = chosen == null ? null : index[chosen];
  if (folder != null) {
    // Hiding the folder you are reading must not leave you staring at a list
    // whose folder is nowhere in the tree. Fall through to the default, unless
    // hidden folders are being shown, in which case it is still on screen and
    // keeping the selection is the less surprising thing.
    final hidden = !ref.watch(showHiddenFoldersProvider) &&
        isFolderHidden(folder, ref.watch(hiddenFoldersProvider), index);
    if (!hidden) return chosen;
  } else if (chosen != null && index.containsKey(chosen)) {
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
      collapsedAccountIds: ref.watch(collapsedAccountsProvider),
      accountErrors: {
        for (final e in ref.watch(folderLoadErrorsProvider).entries)
          e.key: e.value.message,
      },
      hiddenIds: ref.watch(hiddenFoldersProvider),
      showHidden: ref.watch(showHiddenFoldersProvider),
      orderOverrides: ref.watch(folderOrderProvider),
      searchQuery: ref.watch(folderSearchQueryProvider),
    ),
  );
});
