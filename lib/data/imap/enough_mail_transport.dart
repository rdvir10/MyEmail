import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/mail_message.dart';
import '../mail_engine.dart';
import 'imap_mapping.dart';
import 'imap_transport.dart';

/// [ImapTransport] over a real IMAP/TLS connection via enough_mail.
///
/// One instance per account. The connection opens on first use and reopens
/// after a dropped socket. Commands are serialised: an IMAP connection has a
/// single selected mailbox, so two callers interleaving SELECTs would fetch
/// from the wrong folder.
class EnoughMailTransport implements ImapTransport {
  EnoughMailTransport({
    required this.host,
    required this.user,
    required this.secret,
    this.port = 993,
    this.isLogEnabled = false,
  });

  final String host;
  final String user;
  final String secret;
  final int port;

  /// enough_mail's protocol log. It scrambles passwords itself.
  final bool isLogEnabled;

  em.ImapClient? _client;
  Map<String, em.Mailbox> _boxes = {};
  String _delimiter = '/';
  String? _selectedPath;
  Future<void> _tail = Future.value();

  static const _headerCriteria = '(UID FLAGS ENVELOPE BODYSTRUCTURE)';

  // --- ImapTransport ---------------------------------------------------------

  @override
  Future<List<RemoteFolder>> listFolders() => _run((c) async {
        final boxes = await _listMailboxes(c);
        return [for (final b in boxes) remoteFolderFromMailbox(b)];
      });

  @override
  Future<FolderStatus> selectFolder(String path) => _run((c) async {
        final box = await _select(c, path);
        return FolderStatus(
          uidValidity: box.uidValidity ?? 0,
          exists: box.messagesExists,
          uidNext: box.uidNext,
          highestModSeq: box.highestModSequence,
        );
      });

  @override
  Future<List<RemoteHeader>> fetchHeadersBySequence(
    String path,
    int start,
    int end,
  ) =>
      _run((c) async {
        await _ensureSelected(c, path);
        final result = await c.fetchMessages(
          em.MessageSequence.fromRange(start, end),
          _headerCriteria,
        );
        return _headers(result);
      });

  @override
  Future<List<RemoteHeader>> fetchHeadersFromUid(String path, int fromUid) =>
      _run((c) async {
        await _ensureSelected(c, path);
        final result = await c.uidFetchMessages(
          em.MessageSequence.fromRangeToLast(fromUid, isUidSequence: true),
          _headerCriteria,
        );
        return _headers(result);
      });

  @override
  Future<List<RemoteFlags>> fetchFlags(
    String path,
    int fromUid,
    int toUid, {
    int? changedSinceModSeq,
  }) =>
      _run((c) async {
        await _ensureSelected(c, path);
        final result = await c.uidFetchMessages(
          em.MessageSequence.fromRange(fromUid, toUid, isUidSequence: true),
          '(UID FLAGS)',
          changedSinceModSequence: changedSinceModSeq,
        );
        return [
          for (final m in result.messages)
            if (m.uid != null)
              RemoteFlags(uid: m.uid!, isRead: m.isSeen, isFlagged: m.isFlagged),
        ];
      });

  @override
  Future<Set<int>> existingUids(String path, int fromUid, int toUid) =>
      _run((c) async {
        await _ensureSelected(c, path);
        final result = await c.uidSearchMessages(
          searchCriteria: 'UID $fromUid:$toUid',
        );
        final seq = result.matchingSequence;
        if (seq == null) return const {};
        return seq.toList().toSet();
      });

  @override
  Future<MailBody> fetchBody(String path, int uid) => _run((c) async {
        await _ensureSelected(c, path);
        final result = await c.uidFetchMessage(uid, 'BODY.PEEK[]');
        if (result.messages.isEmpty) {
          throw StateError('Message $uid in $path no longer exists');
        }
        return bodyFromMime(result.messages.first);
      });

  @override
  Future<void> storeFlag(
    String path, {
    required List<int> uids,
    required MessageFlag flag,
    required bool set,
  }) =>
      _run((c) async {
        if (uids.isEmpty) return;
        await _ensureSelected(c, path);
        await c.uidStore(
          em.MessageSequence.fromIds(uids, isUid: true),
          [_flagName(flag)],
          action: set ? em.StoreAction.add : em.StoreAction.remove,
          silent: true,
        );
      });

  @override
  Future<void> storeFlagOnAll(
    String path, {
    required MessageFlag flag,
    required bool set,
  }) =>
      _run((c) async {
        final box = await _select(c, path);
        if (box.messagesExists == 0) return;
        await c.store(
          em.MessageSequence.fromAll(),
          [_flagName(flag)],
          action: set ? em.StoreAction.add : em.StoreAction.remove,
          silent: true,
        );
      });

  @override
  Future<void> expunge(String path) => _run((c) async {
        await _ensureSelected(c, path);
        await c.expunge();
      });

  @override
  Future<void> createFolder(String path) => _run((c) async {
        await c.createMailbox(toServerPath(path, _delimiter));
        _boxes = {};
      });

  @override
  Future<void> renameFolder(String oldPath, String newPath) => _run((c) async {
        final box = await _box(c, oldPath);
        await c.renameMailbox(box, toServerPath(newPath, _delimiter));
        _boxes = {};
        if (_selectedPath == oldPath) _selectedPath = null;
      });

  @override
  Future<void> deleteFolder(String path) => _run((c) async {
        final box = await _box(c, path);
        await c.deleteMailbox(box);
        _boxes = {};
        if (_selectedPath == path) _selectedPath = null;
      });

  @override
  Future<void> close() async {
    final c = _client;
    _client = null;
    _selectedPath = null;
    if (c == null) return;
    try {
      if (c.isLoggedIn) await c.logout();
    } catch (_) {}
    try {
      await c.disconnect();
    } catch (_) {}
  }

  // --- plumbing --------------------------------------------------------------

  /// Serialise [op] behind everything queued before it, on a live client.
  /// A dropped socket resets the connection so the next call reconnects.
  Future<T> _run<T>(Future<T> Function(em.ImapClient c) op) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await op(await _ensureClient()));
      } on SocketException catch (e, st) {
        await close();
        completer.completeError(ConnectionFailed('Connection lost: $e'), st);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<em.ImapClient> _ensureClient() async {
    final existing = _client;
    if (existing != null && existing.isConnected && existing.isLoggedIn) {
      return existing;
    }
    await close();
    final client = em.ImapClient(isLogEnabled: isLogEnabled);
    try {
      await client.connectToServer(host, port, isSecure: true);
    } on Exception catch (e) {
      throw ConnectionFailed('Could not reach $host. Check the connection. ($e)');
    }
    try {
      await client.login(user, secret);
    } on em.ImapException catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      throw AuthenticationFailed(loginFailureMessage(e.message));
    }
    _client = client;
    _selectedPath = null;
    return client;
  }

  /// Turn the server's refusal into something a person can act on.
  static String loginFailureMessage(String? raw) {
    final text = raw ?? '';
    if (text.contains('AUTHENTICATIONFAILED') ||
        text.toLowerCase().contains('invalid credentials')) {
      return 'Google refused the sign-in. Check the address, and use an app '
          'password rather than the normal account password.';
    }
    return 'Sign-in failed: ${text.isEmpty ? 'the server gave no reason' : text}';
  }

  Future<List<em.Mailbox>> _listMailboxes(em.ImapClient c) async {
    List<em.Mailbox> boxes;
    try {
      // LIST-STATUS gives counts in one round trip. Gmail supports it.
      boxes = await c.listMailboxes(
        recursive: true,
        returnOptions: [
          em.ReturnOption.status(['MESSAGES', 'UNSEEN']),
        ],
      );
    } on em.ImapException {
      boxes = await c.listMailboxes(recursive: true);
      for (final b in boxes) {
        if (!b.isNotSelectable) {
          await c.statusMailbox(b, [em.StatusFlags.messages, em.StatusFlags.unseen]);
        }
      }
    }
    final selectable = [for (final b in boxes) if (!b.isNotSelectable) b];
    _boxes = {
      for (final b in selectable) toModelPath(b.path, b.pathSeparator): b,
    };
    if (boxes.isNotEmpty) _delimiter = boxes.first.pathSeparator;
    return selectable;
  }

  Future<em.Mailbox> _box(em.ImapClient c, String path) async {
    if (!_boxes.containsKey(path)) await _listMailboxes(c);
    final box = _boxes[path];
    if (box == null) throw StateError('No such folder on the server: $path');
    return box;
  }

  Future<em.Mailbox> _select(em.ImapClient c, String path) async {
    final box = await _box(c, path);
    final selected = await c.selectMailbox(box, enableCondStore: true);
    _selectedPath = path;
    return selected;
  }

  Future<void> _ensureSelected(em.ImapClient c, String path) async {
    if (_selectedPath != path) await _select(c, path);
  }

  static List<RemoteHeader> _headers(em.FetchImapResult result) => [
        for (final m in result.messages)
          if (m.uid != null) remoteHeaderFromMime(m),
      ];

  static String _flagName(MessageFlag flag) => switch (flag) {
        MessageFlag.seen => em.MessageFlags.seen,
        MessageFlag.flagged => em.MessageFlags.flagged,
        MessageFlag.deleted => em.MessageFlags.deleted,
      };
}
