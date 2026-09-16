import '../../domain/account.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/draft.dart';
import '../account_store.dart';
import '../cache/cache_store.dart';
import '../cache/folder_sync.dart';
import '../compose/smtp_sender.dart';
import '../credential_store.dart';
import '../folder_list_store.dart';
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
    ImapTransport Function(Account account, String secret)? transportFactory,
    this._senderFactory,
  })  : folderLists = folderLists ?? MemoryFolderListStore(),
        _transportFactory = transportFactory ?? _defaultTransport;

  final AccountStore accountStore;
  final CredentialStore credentialStore;
  final CacheStore cache;
  final FolderListStore folderLists;
  final ImapTransport Function(Account account, String secret) _transportFactory;
  final SmtpSender Function(Account account, String secret)? _senderFactory;

  final Map<String, ImapTransport> _transports = {};
  final Map<String, FolderSync> _syncs = {};

  static const _palette = [0xFF0F6CBD, 0xFF107C41, 0xFFB4009E, 0xFFCA5010];

  static ImapTransport _defaultTransport(Account account, String secret) =>
      EnoughMailTransport(
        host: imapHostFor(account.provider),
        user: account.emailAddress,
        secret: secret,
      );

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
      authMethod: AuthMethod.appPassword,
      colorValue: _palette[existing.length % _palette.length],
    );
    // Prove the credentials before storing anything: LIST is the cheapest
    // command that needs a successful login.
    final transport = _transportFactory(account, secret);
    final List<RemoteFolder> folders;
    try {
      folders = await transport.listFolders();
    } catch (_) {
      await transport.close();
      rethrow;
    }
    // Keep what the probe already fetched: the tree can then render, and a
    // search can pick its targets, without a second round trip.
    await folderLists.write(account.id, folders);
    _transports[account.id] = transport;
    await credentialStore.writeSecret(account.id, secret);
    await accountStore.write([...existing, account]);
    return account;
  }

  @override
  Future<void> removeAccount(String accountId) async {
    await _transports.remove(accountId)?.close();
    _syncs.remove(accountId);
    await credentialStore.deleteSecret(accountId);
    await cache.deleteAccount(accountId);
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
    return Future.any(waits).catchError((_) => false);
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
  Future<void> sendDraft(Draft draft) async {
    if (!draft.hasRecipients) {
      throw const SendFailed('Add at least one recipient.');
    }
    final account = accountStore.read().firstWhere(
          (a) => a.id == draft.accountId,
          orElse: () => throw StateError('Unknown account ${draft.accountId}'),
        );
    final secret = await credentialStore.readSecret(account.id);
    if (secret == null) {
      throw AuthenticationFailed(
        'No password is stored for ${account.emailAddress}.',
      );
    }

    final message = buildMimeMessage(draft: draft, account: account);
    await _senderFor(account, secret).send(message);

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

  static bool _needsSentCopy(MailProvider provider) =>
      provider != MailProvider.gmail;

  Future<String?> _folderPathForRole(String accountId, FolderRole role) async {
    final remote = folderLists.read(accountId);
    if (remote == null) return null;
    for (final f in remote) {
      if (f.role == role) return f.path;
    }
    return null;
  }

  SmtpSender _senderFor(Account account, String secret) =>
      _senderFactory?.call(account, secret) ??
      SmtpSender(
        host: SmtpSender.smtpHostFor(account.provider),
        user: account.emailAddress,
        secret: secret,
      );

  // --- plumbing --------------------------------------------------------------

  Future<ImapTransport> _transport(String accountId) async {
    final existing = _transports[accountId];
    if (existing != null) return existing;
    final account = accountStore.read().firstWhere(
          (a) => a.id == accountId,
          orElse: () => throw StateError('Unknown account $accountId'),
        );
    final secret = await credentialStore.readSecret(accountId);
    if (secret == null) {
      throw AuthenticationFailed(
        'No password is stored for ${account.emailAddress}. '
        'Remove the account and add it again.',
      );
    }
    return _transports[accountId] = _transportFactory(account, secret);
  }

  FolderSync _sync(String accountId, ImapTransport transport) =>
      _syncs.putIfAbsent(
        accountId,
        () => FolderSync(transport: transport, store: cache, accountId: accountId),
      );
}
