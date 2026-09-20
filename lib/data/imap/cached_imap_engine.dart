import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:collection/collection.dart';
import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/account.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_credentials.dart';
import '../../domain/mail_folder.dart';
import '../../domain/address_suggestions.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../../domain/draft.dart';
import '../account_store.dart';
import '../auth/microsoft_oauth.dart';
import '../auth/oauth_config.dart';
import '../auth/oauth_token.dart';
import '../auth/oauth_token_repository.dart';
import '../cache/cache_store.dart';
import '../cache/folder_sync.dart';
import '../compose/graph_sender.dart';
import '../compose/smtp_sender.dart';
import '../credential_store.dart';
import '../folder_list_store.dart';
import '../graph/graph_id_map.dart';
import '../graph/graph_mail_api.dart';
import '../graph/graph_transport.dart';
import '../mail_engine.dart';
import 'enough_mail_transport.dart';
import 'imap_mapping.dart';
import 'imap_transport.dart';

/// The engine that ships: an [ImapTransport] per account, a [FolderSync] per
/// account keeping the [CacheStore] current, and reads served from the cache.
///
/// If the server cannot be reached, the folder list, message lists and
/// bodies still come from whatever was cached, so the app opens and is
/// readable offline.
class CachedImapEngine implements MailEngine {
  CachedImapEngine({
    required this.accountStore,
    required this.credentialStore,
    required this.cache,
    FolderListStore? folderLists,
    OAuthTokenRepository? oauthTokens,
    this.graphIdMap,
    ImapTransport Function(Account account, MailCredentials credentials)?
        transportFactory,
    this.senderFactory,
    this.graphSenderFactory,
  })  : folderLists = folderLists ?? MemoryFolderListStore(),
        _injectedOAuthTokens = oauthTokens,
        _injectedTransportFactory = transportFactory;

  final AccountStore accountStore;
  final CredentialStore credentialStore;
  final CacheStore cache;
  final FolderListStore folderLists;
  /// Supplied by tests, which hand back an in-memory server. Null in the app,
  /// where [_buildTransport] chooses by provider.
  final ImapTransport Function(Account account, MailCredentials credentials)?
      _injectedTransportFactory;

  ImapTransport _transportFactory(
    Account account,
    MailCredentials credentials,
  ) =>
      _injectedTransportFactory?.call(account, credentials) ??
      _buildTransport(account, credentials);

  /// How to build the SMTP sender. Public and named, so a test can supply one
  /// that sends nothing: it was private, which made the seam unreachable from
  /// outside this library and left the send path opening a real socket in any
  /// test that touched it.
  final SmtpSender Function(Account account, MailCredentials credentials)?
      senderFactory;

  /// The same seam for the Graph route, so a test can prove a Microsoft
  /// account sends that way without a network.
  final GraphSender Function(Account account, MailCredentials credentials)?
      graphSenderFactory;

  final OAuthTokenRepository? _injectedOAuthTokens;

  /// Where Graph message numbering is remembered. Null on a build with no
  /// database behind it — the browser preview, and the tests that do not
  /// exercise a Microsoft account — in which case an in-memory one is used
  /// and the numbering lasts as long as the process.
  final GraphIdMap? graphIdMap;

  /// Late so the default can see [credentialStore], which an initializer list
  /// cannot.
  late final OAuthTokenRepository oauthTokens = _injectedOAuthTokens ??
      OAuthTokenRepository(
        credentialStore: credentialStore,
        oauthClient: () => MicrosoftOAuth(clientId: microsoftClientId),
      );

  final Map<String, ImapTransport> _transports = {};
  final Map<String, FolderSync> _syncs = {};

  static const _palette = [0xFF0F6CBD, 0xFF107C41, 0xFFB4009E, 0xFFCA5010];

  late final GraphIdMap _graphIds = graphIdMap ?? MemoryGraphIdMap();

  /// Which wire to use for an account.
  ///
  /// Microsoft accounts go over Graph. IMAP would be the smaller change, and
  /// it is not an option: Microsoft counts IMAP as legacy authentication,
  /// switches it off by default on new tenants, and blocks it outright
  /// wherever security defaults are on — which is every new tenant. A work
  /// mailbox often cannot be reached over IMAP at all, and no amount of
  /// client-side care changes that.
  ///
  /// Gmail stays on IMAP, where an app password works and IDLE gives real
  /// push that Graph has no equivalent of on a device with no public address.
  ImapTransport _buildTransport(Account account, MailCredentials credentials) {
    if (account.provider == MailProvider.outlook &&
        credentials is OAuthCredentials) {
      return GraphTransport(
        accountId: account.id,
        idMap: _graphIds,
        api: GraphMailApi(
          accessToken: ({bool force = false}) =>
              oauthTokens.accessToken(account.id, force: force),
        ),
      );
    }
    return EnoughMailTransport(
      host: imapHostFor(account.provider),
      user: account.emailAddress,
      credentials: credentials,
    );
  }

  static String imapHostFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => 'imap.gmail.com',
        MailProvider.outlook => 'outlook.office365.com',
      };

  /// An id no existing account holds.
  ///
  /// The clock alone is not enough. Two accounts added in the same
  /// millisecond get the same id, and everything downstream is keyed on it:
  /// the secret in the Keystore, the cached folders and messages, the
  /// notification watermarks. Adding a second mailbox immediately after the
  /// first would have silently shared all of it with the first.
  static String _newAccountId(Set<String> taken) {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
    var id = 'acct-$stamp';
    var suffix = 1;
    while (taken.contains(id)) {
      id = 'acct-$stamp-$suffix';
      suffix++;
    }
    return id;
  }

  // --- accounts --------------------------------------------------------------

  @override
  Future<List<Account>> loadAccounts() async => accountStore.read();

  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) =>
      _add(
        displayName: displayName,
        emailAddress: emailAddress,
        provider: provider,
        authMethod: AuthMethod.appPassword,
        credentials: PasswordCredentials(secret),
        storedSecret: secret,
      );

  @override
  /// Finish an OAuth sign-in by turning its token into an account.
  ///
  /// [emailAddress] is what the person typed, and the probe below is what
  /// checks it: the XOAUTH2 handshake sends the address alongside the token,
  /// and the server refuses the pair if they belong to different mailboxes.
  /// Signing in as one account while typing another's address therefore fails
  /// here rather than becoming an account that can never connect.
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
  }) =>
      _add(
        displayName: displayName,
        emailAddress: emailAddress,
        provider: provider,
        authMethod: AuthMethod.oauth,
        // The probe runs before anything is stored, so the token cannot come
        // from the repository yet; it is handed over directly and only
        // written once the server has accepted it.
        credentials:
            OAuthCredentials(({bool force = false}) async => token.accessToken),
        storedSecret: token.toStoredJson(),
      );

  Future<Account> _add({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required AuthMethod authMethod,
    required MailCredentials credentials,
    required String storedSecret,
  }) async {
    final email = emailAddress.trim();
    final existing = accountStore.read();
    if (existing.any((a) => a.emailAddress.toLowerCase() == email.toLowerCase())) {
      throw AuthenticationFailed('$email is already set up.');
    }
    final account = Account(
      id: _newAccountId(existing.map((a) => a.id).toSet()),
      displayName: displayName,
      emailAddress: email,
      provider: provider,
      authMethod: authMethod,
      colorValue: _palette[existing.length % _palette.length],
    );
    // The secret goes in before the probe, not after.
    //
    // A Microsoft account's transport does not take its token as a parameter:
    // it reads the stored one, because the token it needs is fetched per
    // request and refreshed as it goes. Probing before the write therefore
    // found nothing and reported a sign-in that had just succeeded as "this
    // account is not signed in" — the check failing, not the sign-in.
    //
    // Anything written here is removed again if the probe fails, so a refused
    // credential leaves nothing behind.
    await credentialStore.writeSecret(account.id, storedSecret);

    final transport = _transportFactory(account, credentials);
    final List<RemoteFolder> folders;
    try {
      folders = await transport.listFolders();
    } catch (_) {
      await credentialStore.deleteSecret(account.id);
      await transport.close();
      rethrow;
    }
    // Keep what the probe already fetched: the tree can then render, and a
    // search can pick its targets, without a second round trip.
    await folderLists.write(account.id, folders);
    await accountStore.write([...existing, account]);
    // Only now, with the secret stored, is the cached transport safe to keep:
    // the OAuth one built above closes over a token that will expire, whereas
    // one built from _credentialsFor can refresh itself.
    if (authMethod == AuthMethod.oauth) {
      await transport.close();
    } else {
      _transports[account.id] = transport;
    }
    return account;
  }

  @override
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,
  }) async {
    final accounts = accountStore.read();
    final existing = accounts.where((a) => a.id == accountId).firstOrNull;
    if (existing == null) throw StateError('Unknown account $accountId');

    final trimmed = displayName?.trim();
    final updated = existing.copyWith(
      // An empty name would leave a blank heading in the tree with no way to
      // tell which mailbox it is, so it falls back rather than being stored.
      displayName: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      colorValue: colorValue,
    );
    await accountStore.write([
      for (final a in accounts) a.id == accountId ? updated : a,
    ]);
    // No transport is rebuilt: nothing here changes how the account connects.
    return updated;
  }

  @override
  Future<void> updateAppPassword({
    required String accountId,
    required String secret,
  }) =>
      _replaceSecret(
        accountId: accountId,
        credentials: PasswordCredentials(secret),
        storedSecret: secret,
      );

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
  }) =>
      _replaceSecret(
        accountId: accountId,
        // As in addOAuthAccount: the probe runs before anything is stored, so
        // the token cannot come from the repository yet.
        credentials:
            OAuthCredentials(({bool force = false}) async => token.accessToken),
        storedSecret: token.toStoredJson(),
      );

  Future<void> _replaceSecret({
    required String accountId,
    required MailCredentials credentials,
    required String storedSecret,
  }) async {
    final account = accountStore
        .read()
        .where((a) => a.id == accountId)
        .firstOrNull;
    if (account == null) throw StateError('Unknown account $accountId');

    // In place first, then proved. A Microsoft account's transport reads the
    // stored secret rather than taking one, so probing before the write would
    // test the credential being replaced instead of the new one — and report
    // the new sign-in as stale, which is exactly what it was meant to fix.
    final previous = await credentialStore.readSecret(accountId);
    await credentialStore.writeSecret(accountId, storedSecret);

    final probe = _transportFactory(account, credentials);
    try {
      await probe.listFolders();
    } catch (_) {
      // Put back what worked, or at least what was there. Replacing a
      // credential the server refused would swap one broken sign-in for
      // another and lose the last known-good one on the way.
      if (previous == null) {
        await credentialStore.deleteSecret(accountId);
      } else {
        await credentialStore.writeSecret(accountId, previous);
      }
      rethrow;
    } finally {
      await probe.close();
    }

    // Drop the cached transport and the sync built on it. A password
    // transport closes over the secret it was built with, so keeping it would
    // mean the account carried on failing with the old password until the app
    // was restarted, which looks exactly like the fix not having worked.
    await _transports.remove(accountId)?.close();
    _syncs.remove(accountId);
  }

  @override
  Future<void> removeAccount(String accountId) async {
    await _transports.remove(accountId)?.close();
    _syncs.remove(accountId);
    await credentialStore.deleteSecret(accountId);
    await cache.deleteAccount(accountId);
    // The numbering goes with the cache it keyed. Leaving it would hand the
    // same numbers to a different mailbox if this address were added again.
    await _graphIds.forgetAccount(accountId);
    await folderLists.delete(accountId);
    await accountStore.write([
      for (final a in accountStore.read())
        if (a.id != accountId) a,
    ]);
  }

  /// Wait until any of [folderIds] has something new, or [timeout] passes.
  ///
  /// One IDLE per account, raced. The losers are left waiting rather than
  /// cancelled: each is idling its own connection, and a connection already
  /// held open costs nothing more to keep until its own timeout. Cancelling
  /// them would mean a round trip per account for no gain.
  ///
  /// Returns true if a server spoke. False means the timeout was reached, or
  /// no folder could be watched at all, and the caller should treat both the
  /// same way: it is simply time to sync again.
  Future<bool> awaitNewMail(
    List<String> folderIds, {
    required Duration timeout,
  }) async {
    if (folderIds.isEmpty) return false;
    final waits = <Future<bool>>[];
    for (final folderId in folderIds) {
      final (accountId, path) = splitFolderId(folderId);
      try {
        final t = await _transport(accountId);
        waits.add(t.awaitChanges(path, timeout: timeout));
      } catch (_) {
        // This account cannot be watched right now. The others still can, and
        // the next ordinary pass will pick this one up.
      }
    }
    if (waits.isEmpty) {
      await Future<void>.delayed(timeout);
      return false;
    }
    // Any of them waking is reason enough to sync every account: the pass is
    // cheap against the cache and sorting out which one spoke is not.
    debugPrint('[myemail] watching ${waits.length} of ${folderIds.length} inboxes');
    final woke = await Future.any(waits).catchError((e) {
      debugPrint('[myemail] watch failed: $e');
      return false;
    });
    debugPrint('[myemail] watch ended, woke=$woke');
    return woke;
  }

  /// Drop every open connection. Not part of [MailEngine]: the app holds one
  /// engine for its whole life and has nothing to close it for. The background
  /// pass does — it runs in an isolate Android tears down afterwards, and a
  /// socket left open there is a wakelock nobody asked for.
  Future<void> close() async {
    final open = _transports.values.toList();
    _transports.clear();
    _syncs.clear();
    for (final t in open) {
      try {
        await t.close();
      } catch (_) {
        // Already gone. Closing is best-effort by definition.
      }
    }
  }

  // --- folders ---------------------------------------------------------------

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    List<RemoteFolder> remote;
    try {
      final t = await _transport(accountId);
      remote = await t.listFolders();
      await folderLists.write(accountId, remote);
    } on ConnectionFailed {
      final cached = folderLists.read(accountId);
      if (cached == null) rethrow;
      remote = cached;
    }
    final paths = {for (final r in remote) r.path};
    return [
      for (final (i, r) in remote.indexed)
        folderFromRemote(
          accountId: accountId,
          provider: _providerFor(accountId),
          remote: r,
          allPaths: paths,
          sortIndex: i,
        ),
    ];
  }

  @override
  Future<FolderRename> renameFolder(String folderId, String newName) {
    final (accountId, path) = splitFolderId(folderId);
    final cut = path.lastIndexOf('/');
    final newPath = cut < 0 ? newName : '${path.substring(0, cut)}/$newName';
    return _relocate(accountId, path, newPath);
  }

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) {
    final (accountId, path) = splitFolderId(folderId);
    final name = MailFolder.nameFor(path);
    final newPath =
        newParentId == null ? name : '${splitFolderId(newParentId).$2}/$name';
    return _relocate(accountId, path, newPath);
  }

  Future<FolderRename> _relocate(
    String accountId,
    String path,
    String newPath,
  ) async {
    if (newPath == path) {
      final folders = await loadFolders(accountId);
      final same = folders.firstWhere((f) => f.path == path);
      return FolderRename(folder: same, oldId: same.id, newId: same.id);
    }
    final t = await _transport(accountId);
    final before = await t.listFolders();
    if (before.any((r) => r.path.toLowerCase() == newPath.toLowerCase())) {
      throw FolderNameConflict(accountId, newPath);
    }
    await t.renameFolder(path, newPath);
    await cache.renameFolder(accountId, path, newPath);
    final folders = await loadFolders(accountId);
    final moved = folders.firstWhere(
      (f) => f.path == newPath,
      orElse: () => throw StateError('Renamed folder not listed: $newPath'),
    );
    return FolderRename(
      folder: moved,
      oldId: MailFolder.idFor(accountId, path),
      newId: moved.id,
    );
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await t.deleteFolder(path);
    await cache.deleteFolder(accountId, path);
  }

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) async {
    final path = parentId == null ? name : '${splitFolderId(parentId).$2}/$name';
    final t = await _transport(accountId);
    final before = await t.listFolders();
    if (before.any((r) => r.path.toLowerCase() == path.toLowerCase())) {
      throw FolderNameConflict(accountId, path);
    }
    await t.createFolder(path);
    final folders = await loadFolders(accountId);
    return folders.firstWhere(
      (f) => f.path == path,
      orElse: () => throw StateError('Created folder not listed: $path'),
    );
  }

  @override
  Future<void> markAllRead(String folderId) async {
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await t.storeFlagOnAll(path, flag: MessageFlag.seen, set: true);
    // The flag sweep on the next sync brings the cache in line.
    await _sync(accountId, t).sync(path);
  }

  @override
  Future<void> emptyFolder(String folderId) async {
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await t.storeFlagOnAll(path, flag: MessageFlag.deleted, set: true);
    await t.expunge(path);
    await cache.clearFolder(accountId, path);
  }

  // --- messages --------------------------------------------------------------

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final (accountId, path) = splitFolderId(folderId);
    try {
      final t = await _transport(accountId);
      final sync = _sync(accountId, t);
      await sync.sync(path);
      await sync.ensureCached(path, offset + limit);
    } on ConnectionFailed {
      // Offline: whatever is cached is what there is.
    }
    final rows = await cache.readMessages(
      accountId,
      path,
      offset: offset,
      limit: limit,
    );
    return [
      for (final r in rows) r.toMailMessage(accountId: accountId, folderId: folderId),
    ];
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final cached = await cache.readMessage(accountId, path, uid);
    if (cached != null && cached.bodyText != null) {
      return MailBody(text: cached.bodyText!, html: cached.bodyHtml);
    }
    final t = await _transport(accountId);
    return _sync(accountId, t).body(path, uid);
  }

  @override
  Future<List<AddressSuggestion>> recentAddresses() async =>
      historyFrom(await cache.recentAddresses());

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    return t.listAttachments(path, uid);
  }

  @override
  Future<Uint8List> fetchAttachment(
    String messageId,
    String attachmentId,
  ) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    return t.fetchAttachment(path, uid, attachmentId);
  }

  @override
  Future<void> setRead(String messageId, bool isRead) =>
      _setFlag(messageId, MessageFlag.seen, isRead);

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) =>
      _setFlag(messageId, MessageFlag.flagged, isFlagged);

  @override
  Future<void> moveMessages(List<String> messageIds, String toFolderId) async {
    if (messageIds.isEmpty) return;
    final (toAccount, toPath) = splitFolderId(toFolderId);
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, fromPath) = splitFolderId(group.key);
      if (accountId != toAccount) {
        throw FolderOperationNotSupported(
          group.key,
          'move messages between accounts',
        );
      }
      if (fromPath == toPath) continue;
      final t = await _transport(accountId);
      await t.moveMessages(fromPath, group.value, toPath);
      await cache.deleteUids(accountId, fromPath, group.value.toSet());
      // The destination picks the new messages up on its next sync; it may
      // not be cached at all yet, and guessing UIDs would be worse.
      await _syncIfCached(accountId, t, toPath);
    }
  }

  @override
  Future<void> deleteMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, fromPath) = splitFolderId(group.key);
      final t = await _transport(accountId);
      final trash = await _trashPath(accountId, t);

      if (trash == null || fromPath == trash) {
        // Already in Trash, or the account has none: delete for good.
        await t.storeFlag(fromPath,
            uids: group.value, flag: MessageFlag.deleted, set: true);
        await t.expunge(fromPath);
      } else {
        await t.moveMessages(fromPath, group.value, trash);
        await _syncIfCached(accountId, t, trash);
      }
      await cache.deleteUids(accountId, fromPath, group.value.toSet());
    }
  }

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
  }) async {
    if (query.trim().isEmpty) return const [];
    final targets = await _searchTargets(scope);
    final results = await Future.wait([
      for (final (accountId, path) in targets)
        _searchOneFolder(accountId, path, query, limit),
    ]);
    final merged = [for (final r in results) ...r]
      ..sort((a, b) => b.date.compareTo(a.date));
    return merged.take(limit).toList();
  }

  Future<List<MailMessage>> _searchOneFolder(
    String accountId,
    String path,
    String query,
    int limit,
  ) async {
    try {
      final t = await _transport(accountId);
      final uids = await t.searchUids(path, query, limit: limit);
      if (uids.isEmpty) return const [];
      final folderId = MailFolder.idFor(accountId, path);

      // Anything already cached needs no round trip, and brings its preview
      // along; only the rest is fetched.
      final rows = <MailMessage>[];
      final missing = <int>[];
      for (final uid in uids) {
        final cached = await cache.readMessage(accountId, path, uid);
        if (cached != null) {
          rows.add(cached.toMailMessage(accountId: accountId, folderId: folderId));
        } else {
          missing.add(uid);
        }
      }
      if (missing.isNotEmpty) {
        final headers = await t.fetchHeadersByUids(path, missing);
        for (final h in headers) {
          rows.add(
            MailMessage(
              id: MailMessage.idFor(folderId, h.uid),
              accountId: accountId,
              folderId: folderId,
              uid: h.uid,
              subject: h.subject,
              from: h.from,
              to: h.to,
              date: h.date,
              preview: '',
              isRead: h.isRead,
              isFlagged: h.isFlagged,
              hasAttachments: h.hasAttachments,
            ),
          );
        }
      }
      return rows;
    } on ConnectionFailed {
      // One unreachable account should not sink a search across the others.
      return const [];
    }
  }

  /// The (account, folder path) pairs a scope covers.
  Future<List<(String, String)>> _searchTargets(SearchScope scope) async {
    if (scope.folderId != null) {
      final (accountId, path) = splitFolderId(scope.folderId!);
      return [(accountId, path)];
    }
    final accountIds = scope.accountId != null
        ? [scope.accountId!]
        : [for (final a in accountStore.read()) a.id];
    final targets = <(String, String)>[];
    for (final accountId in accountIds) {
      List<RemoteFolder> remote;
      final cached = folderLists.read(accountId);
      if (cached != null) {
        remote = cached;
      } else {
        try {
          remote = await (await _transport(accountId)).listFolders();
        } on ConnectionFailed {
          // One unreachable account contributes nothing rather than sinking
          // a search across the others.
          continue;
        }
      }
      for (final f in remote) {
        // All Mail holds a copy of everything, so including it would double
        // every hit; Spam and Trash are not what "search my mail" means.
        if (f.role == FolderRole.archive ||
            f.role == FolderRole.junk ||
            f.role == FolderRole.deleted) {
          continue;
        }
        targets.add((accountId, f.path));
      }
    }
    return targets;
  }

  /// Message ids grouped by the folder they live in, so one folder is one
  /// server round trip rather than one per message.
  static Map<String, List<int>> _groupByFolder(List<String> messageIds) {
    final byFolder = <String, List<int>>{};
    for (final id in messageIds) {
      final (folderId, uid) = splitMessageId(id);
      (byFolder[folderId] ??= []).add(uid);
    }
    return byFolder;
  }

  Future<String?> _trashPath(String accountId, ImapTransport t) async {
    final remote = folderLists.read(accountId) ?? await t.listFolders();
    for (final f in remote) {
      if (f.role == FolderRole.deleted) return f.path;
    }
    return null;
  }

  /// Sync a folder only if something is already cached for it; an untouched
  /// folder is left to its first open.
  Future<void> _syncIfCached(
    String accountId,
    ImapTransport t,
    String path,
  ) async {
    if (await cache.readFolderState(accountId, path) == null) return;
    await _sync(accountId, t).sync(path);
  }

  Future<void> _setFlag(String messageId, MessageFlag flag, bool set) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await t.storeFlag(path, uids: [uid], flag: flag, set: set);
    final cached = await cache.readMessage(accountId, path, uid);
    if (cached != null) {
      await cache.updateFlags(accountId, path, {
        uid: (
          isRead: flag == MessageFlag.seen ? set : cached.isRead,
          isFlagged: flag == MessageFlag.flagged ? set : cached.isFlagged,
        ),
      });
    }
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    final account = accountStore.read().firstWhere(
          (a) => a.id == draft.accountId,
          orElse: () => throw StateError('Unknown account ${draft.accountId}'),
        );
    final draftsPath = await _folderPathForRole(account.id, FolderRole.drafts);
    if (draftsPath == null) return null;

    final message = buildMimeMessage(draft: draft, account: account);
    final t = await _transport(account.id);

    // Append before deleting the old copy. The other order loses the draft
    // outright if the append then fails, and a duplicate is a far better
    // failure than a message that no longer exists anywhere.
    await t.appendMessage(draftsPath, message.renderMessage(), draft: true);
    await _dropPreviousDraft(draft.savedAs);

    // Resync so the new copy is in the cache, then find it: APPEND does not
    // reliably report the UID it landed on, and UIDPLUS is not universal.
    await _sync(account.id, t).sync(draftsPath);
    final newest = await cache.uidRange(account.id, draftsPath);
    if (newest == null) return null;
    return MailMessage.idFor(
      MailFolder.idFor(account.id, draftsPath),
      newest.max,
    );
  }

  /// Remove the copy a draft was opened from, so saving twice does not leave
  /// two. Best-effort: a draft that failed to delete is untidy, not broken.
  Future<void> _dropPreviousDraft(String? savedAs) async {
    if (savedAs == null) return;
    try {
      final (folderId, uid) = splitMessageId(savedAs);
      final (accountId, path) = splitFolderId(folderId);
      final t = await _transport(accountId);
      await t.storeFlag(path, uids: [uid], flag: MessageFlag.deleted, set: true);
      await t.expunge(path);
      await cache.deleteUids(accountId, path, {uid});
    } catch (_) {
      // Already gone, or the server refused. Either way the new copy is safe.
    }
  }

  @override
  Future<void> sendDraft(Draft draft) async {
    if (!draft.hasRecipients) {
      throw const SendFailed('Add at least one recipient.');
    }
    final account = accountStore.read().firstWhere(
          (a) => a.id == draft.accountId,
          orElse: () => throw StateError('Unknown account ${draft.accountId}'),
        );
    final credentials = await _credentialsFor(account);

    final message = buildMimeMessage(draft: draft, account: account);
    await _send(account, credentials, message);

    // It is away, so the copy in Drafts is now a duplicate of sent mail.
    await _dropPreviousDraft(draft.savedAs);

    // Gmail files sent mail into Sent itself, so appending would leave two
    // copies. Other providers do not, hence the per-provider check.
    if (_needsSentCopy(account.provider)) {
      final sentPath = await _folderPathForRole(account.id, FolderRole.sent);
      if (sentPath != null) {
        try {
          final t = await _transport(account.id);
          await t.appendMessage(sentPath, message.renderMessage());
        } catch (_) {
          // The message is already away; failing to file a copy is not worth
          // telling the user the send failed.
        }
      }
    }

    // Mark the message being answered as \Answered, which is what makes
    // other clients show the reply arrow.
    final originalId = draft.originalMessageId;
    if (originalId != null && draft.kind != ComposeKind.forward) {
      try {
        final (folderId, uid) = splitMessageId(originalId);
        final (accountId, path) = splitFolderId(folderId);
        final t = await _transport(accountId);
        await t.storeFlag(path, uids: [uid], flag: MessageFlag.answered,
            set: true);
      } catch (_) {
        // Cosmetic; never fail a successful send over it.
      }
    }
  }

  /// Whether the app must file its own copy of a sent message.
  ///
  /// Both providers we support file it themselves, so appending would leave
  /// two copies of everything in Sent. Gmail has always done this. Microsoft
  /// does it for mail submitted over SMTP AUTH, which is the path this app
  /// uses.
  ///
  /// If a sent message ever fails to appear in Sent for some provider, this
  /// is the switch: return true for it and the engine appends the copy
  /// itself.
  static bool _needsSentCopy(MailProvider provider) => switch (provider) {
        MailProvider.gmail => false,
        MailProvider.outlook => false,
      };

  Future<String?> _folderPathForRole(String accountId, FolderRole role) async {
    final remote = folderLists.read(accountId);
    if (remote == null) return null;
    for (final f in remote) {
      if (f.role == role) return f.path;
    }
    return null;
  }

  /// Put the message on the wire by whichever route the provider actually
  /// supports.
  ///
  /// Microsoft goes through Graph. SMTP submission is off by default for every
  /// tenant, Microsoft recommends against turning it on, and a tenant with
  /// security defaults enabled blocks it outright — so an app that only speaks
  /// SMTP cannot send from a work mailbox at all, and often not from a
  /// personal one either.
  ///
  /// Gmail stays on SMTP, where an app password works and there is nothing to
  /// gain from changing it.
  Future<void> _send(
    Account account,
    MailCredentials credentials,
    em.MimeMessage message,
  ) async {
    final injected = senderFactory?.call(account, credentials);
    if (injected != null) return injected.send(message);

    if (account.provider == MailProvider.outlook &&
        credentials is OAuthCredentials) {
      final sender = graphSenderFactory?.call(account, credentials) ??
          GraphSender(
            accessToken: ({bool force = false}) =>
                oauthTokens.accessToken(account.id, force: force),
          );
      return sender.send(message);
    }

    return SmtpSender.forProvider(
      provider: account.provider,
      user: account.emailAddress,
      credentials: credentials,
    ).send(message);
  }

  // --- plumbing --------------------------------------------------------------

  Future<ImapTransport> _transport(String accountId) async {
    final existing = _transports[accountId];
    if (existing != null) return existing;
    final account = accountStore.read().firstWhere(
          (a) => a.id == accountId,
          orElse: () => throw StateError('Unknown account $accountId'),
        );
    return _transports[accountId] =
        _transportFactory(account, await _credentialsFor(account));
  }

  /// Which service an account talks to, for the folder mapping.
  ///
  /// Gmail if the account has gone missing, which cannot normally happen:
  /// this is only reached for an account whose folders are being listed. The
  /// fallback keeps a folder list rendering rather than throwing from a
  /// mapping function.
  MailProvider _providerFor(String accountId) =>
      accountStore
          .read()
          .where((a) => a.id == accountId)
          .firstOrNull
          ?.provider ??
      MailProvider.gmail;

  /// How this account signs in, ready to be used when a connection opens.
  ///
  /// The OAuth branch reads nothing now on purpose. A token fetched here
  /// would be stale by the time a long-lived transport reconnected hours
  /// later, so what the transport gets is the means of asking, and the
  /// asking happens per connection.
  Future<MailCredentials> _credentialsFor(Account account) async {
    switch (account.authMethod) {
      case AuthMethod.oauth:
        return OAuthCredentials(
          ({bool force = false}) =>
              oauthTokens.accessToken(account.id, force: force),
        );
      case AuthMethod.appPassword:
        final secret = await credentialStore.readSecret(account.id);
        if (secret == null) {
          throw AuthenticationFailed(
            'No password is stored for ${account.emailAddress}. '
            'Remove the account and add it again.',
          );
        }
        return PasswordCredentials(secret);
    }
  }

  FolderSync _sync(String accountId, ImapTransport transport) =>
      _syncs.putIfAbsent(
        accountId,
        () => FolderSync(transport: transport, store: cache, accountId: accountId),
      );
}
