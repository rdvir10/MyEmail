import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../account_store.dart';
import '../credential_store.dart';
import '../mail_engine.dart';
import 'imap_mapping.dart';

/// The real engine: IMAP over TLS via enough_mail, one connection per
/// account, opened on first use and reopened after a dropped socket.
///
/// Commands on one connection are serialised through [_Session.run], because
/// an IMAP connection has a single selected mailbox and interleaving SELECTs
/// from concurrent callers would fetch from the wrong folder.
///
/// This is deliberately thin: every translation between server types and
/// the domain lives in imap_mapping.dart where it can be unit tested. What is
/// left here is exercised against a live account.
class ImapMailEngine implements MailEngine {
  ImapMailEngine({
    required this.accountStore,
    required this.credentialStore,
    this.isLogEnabled = false,
  });

  final AccountStore accountStore;
  final CredentialStore credentialStore;

  /// enough_mail's protocol log. It scrambles passwords itself.
  final bool isLogEnabled;

  final Map<String, _Session> _sessions = {};

  static const imapPort = 993;

  static String imapHostFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => 'imap.gmail.com',
        MailProvider.outlook => 'outlook.office365.com',
      };

  static const _palette = [0xFF0F6CBD, 0xFF107C41, 0xFFB4009E, 0xFFCA5010];

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
    // Prove the credentials before storing anything.
    final client = await _connectAndLogin(account, secret);
    _sessions[account.id] = _Session(client);
    await credentialStore.writeSecret(account.id, secret);
    await accountStore.write([...existing, account]);
    return account;
  }

  @override
  Future<void> removeAccount(String accountId) async {
    await _sessions.remove(accountId)?.close();
    await credentialStore.deleteSecret(accountId);
    await accountStore.write([
      for (final a in accountStore.read())
        if (a.id != accountId) a,
    ]);
  }

  // --- folders ---------------------------------------------------------------

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    final s = await _session(accountId);
    return s.run(() => _listFolders(s, accountId));
  }

  @override
  Future<FolderRename> renameFolder(String folderId, String newName) async {
    final (accountId, path) = _splitFolderId(folderId);
    final cut = path.lastIndexOf('/');
    final newPath = cut < 0 ? newName : '${path.substring(0, cut)}/$newName';
    return _relocate(accountId, path, newPath);
  }

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) async {
    final (accountId, path) = _splitFolderId(folderId);
    final name = MailFolder.nameFor(path);
    final newPath = newParentId == null
        ? name
        : '${_splitFolderId(newParentId).$2}/$name';
    return _relocate(accountId, path, newPath);
  }

  Future<FolderRename> _relocate(
    String accountId,
    String path,
    String newPath,
  ) async {
    final s = await _session(accountId);
    return s.run(() async {
      final box = await _box(s, accountId, path);
      if (s.boxes.containsKey(newPath)) {
        throw FolderNameConflict(accountId, newPath);
      }
      await s.client.renameMailbox(box, toServerPath(newPath, s.delimiter));
      final folders = await _listFolders(s, accountId);
      final moved = folders.firstWhere(
        (f) => f.path == newPath,
        orElse: () => throw StateError('Renamed folder not listed: $newPath'),
      );
      return FolderRename(
        folder: moved,
        oldId: MailFolder.idFor(accountId, path),
        newId: moved.id,
      );
    });
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    final (accountId, path) = _splitFolderId(folderId);
    final s = await _session(accountId);
    await s.run(() async {
      final box = await _box(s, accountId, path);
      await s.client.deleteMailbox(box);
      s.boxes.remove(path);
    });
  }

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) async {
    final path = parentId == null ? name : '${_splitFolderId(parentId).$2}/$name';
    final s = await _session(accountId);
    return s.run(() async {
      if (s.boxes.containsKey(path)) throw FolderNameConflict(accountId, path);
      await s.client.createMailbox(toServerPath(path, s.delimiter));
      final folders = await _listFolders(s, accountId);
      return folders.firstWhere(
        (f) => f.path == path,
        orElse: () => throw StateError('Created folder not listed: $path'),
      );
    });
  }

  @override
  Future<void> markAllRead(String folderId) async {
    final (accountId, path) = _splitFolderId(folderId);
    final s = await _session(accountId);
    await s.run(() async {
      final box = await _select(s, accountId, path);
      if (box.messagesExists == 0) return;
      await s.client.store(
        em.MessageSequence.fromAll(),
        [em.MessageFlags.seen],
        action: em.StoreAction.add,
        silent: true,
      );
    });
  }

  @override
  Future<void> emptyFolder(String folderId) async {
    final (accountId, path) = _splitFolderId(folderId);
    final s = await _session(accountId);
    await s.run(() async {
      final box = await _select(s, accountId, path);
      if (box.messagesExists == 0) return;
      await s.client.store(
        em.MessageSequence.fromAll(),
        [em.MessageFlags.deleted],
        action: em.StoreAction.add,
        silent: true,
      );
      await s.client.expunge();
    });
  }

  // --- messages --------------------------------------------------------------

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final (accountId, path) = _splitFolderId(folderId);
    final s = await _session(accountId);
    return s.run(() async {
      final box = await _select(s, accountId, path);
      final page = pageSequence(
        exists: box.messagesExists,
        offset: offset,
        limit: limit,
      );
      if (page == null) return const [];
      final result = await s.client.fetchMessages(
        em.MessageSequence.fromRange(page.start, page.end),
        '(UID FLAGS ENVELOPE BODYSTRUCTURE)',
      );
      final messages = [
        for (final m in result.messages)
          if (m.uid != null)
            messageFromMime(accountId: accountId, folderId: folderId, m: m),
      ]..sort((a, b) => b.uid.compareTo(a.uid));
      return messages;
    });
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    final hash = messageId.lastIndexOf('#');
    final folderId = messageId.substring(0, hash);
    final uid = int.parse(messageId.substring(hash + 1));
    final (accountId, path) = _splitFolderId(folderId);
    final s = await _session(accountId);
    return s.run(() async {
      await _select(s, accountId, path);
      final result = await s.client.uidFetchMessage(uid, 'BODY.PEEK[]');
      if (result.messages.isEmpty) {
        throw StateError('Message $messageId no longer exists');
      }
      return bodyFromMime(result.messages.first);
    });
  }

  // --- plumbing --------------------------------------------------------------

  /// `<accountId>:<path>`; account ids never contain a colon.
  (String, String) _splitFolderId(String folderId) {
    final i = folderId.indexOf(':');
    if (i < 0) throw ArgumentError('Not a folder id: $folderId');
    return (folderId.substring(0, i), folderId.substring(i + 1));
  }

  Future<_Session> _session(String accountId) async {
    final existing = _sessions[accountId];
    if (existing != null &&
        existing.client.isConnected &&
        existing.client.isLoggedIn) {
      return existing;
    }
    await existing?.close();
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
    final client = await _connectAndLogin(account, secret);
    return _sessions[accountId] = _Session(client);
  }

  Future<em.ImapClient> _connectAndLogin(Account account, String secret) async {
    final client = em.ImapClient(isLogEnabled: isLogEnabled);
    final host = imapHostFor(account.provider);
    try {
      await client.connectToServer(host, imapPort, isSecure: true);
    } on Exception catch (e) {
      throw ConnectionFailed('Could not reach $host. Check the connection. ($e)');
    }
    try {
      await client.login(account.emailAddress, secret);
    } on em.ImapException catch (e) {
      await _quietly(client.disconnect);
      throw AuthenticationFailed(_loginMessage(e.message));
    }
    return client;
  }

  static String _loginMessage(String? raw) {
    final text = raw ?? '';
    if (text.contains('AUTHENTICATIONFAILED') ||
        text.toLowerCase().contains('invalid credentials')) {
      return 'Google refused the sign-in. Check the address, and use an app '
          'password rather than the normal account password.';
    }
    return 'Sign-in failed: ${text.isEmpty ? 'the server gave no reason' : text}';
  }

  Future<List<MailFolder>> _listFolders(_Session s, String accountId) async {
    List<em.Mailbox> boxes;
    try {
      // LIST-STATUS gives counts in one round trip. Gmail supports it.
      boxes = await s.client.listMailboxes(
        recursive: true,
        returnOptions: [
          em.ReturnOption.status(['MESSAGES', 'UNSEEN']),
        ],
      );
    } on em.ImapException {
      boxes = await s.client.listMailboxes(recursive: true);
      for (final b in boxes) {
        if (!b.isNotSelectable) {
          await s.client.statusMailbox(
            b,
            [em.StatusFlags.messages, em.StatusFlags.unseen],
          );
        }
      }
    }

    s.boxes = {
      for (final b in boxes) toModelPath(b.path, b.pathSeparator): b,
    };
    if (boxes.isNotEmpty) s.delimiter = boxes.first.pathSeparator;
    final selectable = {
      for (final b in boxes)
        if (!b.isNotSelectable) toModelPath(b.path, b.pathSeparator),
    };

    final folders = <MailFolder>[];
    for (final b in boxes) {
      final f = folderFromMailbox(
        accountId: accountId,
        provider: _providerOf(accountId),
        box: b,
        selectableModelPaths: selectable,
        sortIndex: folders.length,
      );
      if (f != null) folders.add(f);
    }
    return folders;
  }

  MailProvider _providerOf(String accountId) => accountStore
      .read()
      .firstWhere((a) => a.id == accountId,
          orElse: () => throw StateError('Unknown account $accountId'))
      .provider;

  Future<em.Mailbox> _box(_Session s, String accountId, String path) async {
    if (!s.boxes.containsKey(path)) await _listFolders(s, accountId);
    final box = s.boxes[path];
    if (box == null) throw StateError('No such folder on the server: $path');
    return box;
  }

  /// SELECT the folder (again) so EXISTS and the flags are current.
  Future<em.Mailbox> _select(_Session s, String accountId, String path) async {
    final box = await _box(s, accountId, path);
    final selected = await s.client.selectMailbox(box);
    s.selectedPath = path;
    return selected;
  }

  static Future<void> _quietly(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {
      // Best effort only.
    }
  }
}

class _Session {
  _Session(this.client);

  final em.ImapClient client;
  Map<String, em.Mailbox> boxes = {};
  String delimiter = '/';
  String? selectedPath;
  Future<void> _tail = Future.value();

  /// Run [op] after everything queued before it. A dropped connection marks
  /// the session dead so the next call reconnects instead of failing again.
  Future<T> run<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await op());
      } on SocketException catch (e, st) {
        await close();
        completer.completeError(ConnectionFailed('Connection lost: $e'), st);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> close() async {
    try {
      if (client.isLoggedIn) await client.logout();
    } catch (_) {}
    try {
      await client.disconnect();
    } catch (_) {}
  }
}
