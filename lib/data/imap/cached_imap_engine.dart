import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../account_store.dart';
import '../cache/cache_store.dart';
import '../cache/folder_sync.dart';
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
  })  : folderLists = folderLists ?? MemoryFolderListStore(),
        _transportFactory = transportFactory ?? _defaultTransport;

  final AccountStore accountStore;
  final CredentialStore credentialStore;
  final CacheStore cache;
  final FolderListStore folderLists;
  final ImapTransport Function(Account account, String secret) _transportFactory;

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
      id: 'acct-${DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36)}',
      displayName: displayName,
      emailAddress: email,
      provider: provider,
      authMethod: AuthMethod.appPassword,
      colorValue: _palette[existing.length % _palette.length],
    );
    // Prove the credentials before storing anything: LIST is the cheapest
    // command that needs a successful login.
    final transport = _transportFactory(account, secret);
    try {
      await transport.listFolders();
    } catch (_) {
      await transport.close();
      rethrow;
    }
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
