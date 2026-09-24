import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/mail_attachment.dart';
import '../../domain/mail_credentials.dart';
import '../../domain/mail_message.dart';
import '../../domain/calendar_invite.dart';
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
    required this.credentials,
    this.port = 993,
    this.isLogEnabled = false,
    this.useTls = true,
    this.commandLimit = defaultCommandLimit,
    this.transferLimit = defaultTransferLimit,
  });

  /// Always true in the app. Off only for a test talking to a local fake
  /// server, which has no certificate to offer.
  final bool useTls;

  /// See [defaultCommandLimit] and [defaultTransferLimit]; settable so a test
  /// does not have to wait minutes to see one run out.
  final Duration commandLimit;
  final Duration transferLimit;

  final String host;
  final String user;

  /// An app password, or the means of getting a current OAuth access token.
  /// See [MailCredentials] for why these cannot be the same type.
  final MailCredentials credentials;
  final int port;

  /// enough_mail's protocol log. It scrambles passwords itself.
  final bool isLogEnabled;

  em.ImapClient? _client;

  /// Completes when [_client]'s connection is lost. See [_run].
  Future<void>? _clientLost;
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
  Future<List<RemoteHeader>> fetchHeadersFromUid(
    String path,
    int fromUid, {
    DateTime? windowStart,
  }) =>
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
    DateTime? windowStart,
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
  Future<Set<int>> existingUids(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) =>
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
  Future<List<int>> searchUids(String path, String query, {int limit = 100}) =>
      _run((c) async {
        await _ensureSelected(c, path);
        final result = await c.uidSearchMessages(
          searchCriteria: buildSearchCriteria(query),
        );
        final seq = result.matchingSequence;
        if (seq == null) return const [];
        // Highest UID is newest, and that is the end the user wants.
        final uids = seq.toList()..sort((a, b) => b.compareTo(a));
        return uids.take(limit).toList();
      });

  @override
  Future<List<RemoteHeader>> fetchHeadersByUids(
    String path,
    List<int> uids,
  ) =>
      _run((c) async {
        if (uids.isEmpty) return const [];
        await _ensureSelected(c, path);
        final result = await c.uidFetchMessages(
          em.MessageSequence.fromIds(uids, isUid: true),
          _headerCriteria,
        );
        return _headers(result);
      });

  @override
  Future<MailBody> fetchBody(String path, int uid) => _run(limit: transferLimit, (c) async {
        await _ensureSelected(c, path);
        final result = await c.uidFetchMessage(uid, 'BODY.PEEK[]');
        if (result.messages.isEmpty) {
          throw StateError('Message $uid in $path no longer exists');
        }
        return bodyFromMime(result.messages.first);
      });

  /// IMAP has no preview to give: it would mean fetching a body part for
  /// every row. Previews here are written when a message is opened.
  @override
  bool get canRefreshHeaders => false;

  @override
  Future<List<RemoteHeader>> refreshHeaders(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) async =>
      const [];

  @override
  Future<bool> respondToInvite(
    String path,
    int uid,
    InviteResponse response, {
    String? iCalUid,
  }) async =>
      false; // IMAP has no calendar; the reply goes as mail.

  @override
  Future<String> fetchRaw(String path, int uid) => _run(limit: transferLimit, (c) async {
        await _ensureSelected(c, path);
        final result = await c.uidFetchMessage(uid, 'BODY.PEEK[]');
        if (result.messages.isEmpty) {
          throw StateError('Message $uid in $path no longer exists');
        }
        // Rendered from the parsed message rather than read off the wire:
        // the same headers and parts, in the form every client reads.
        return result.messages.first.renderMessage();
      });

  @override
  Future<List<MailAttachment>> listAttachments(String path, int uid) =>
      _run((c) async {
        await _ensureSelected(c, path);
        // BODYSTRUCTURE, not the message: the server describes the parts and
        // sends none of them, which is the whole point of listing separately
        // from fetching.
        final result = await c.uidFetchMessage(uid, 'BODYSTRUCTURE');
        if (result.messages.isEmpty) return const [];
        return attachmentsOf(result.messages.first);
      });

  @override
  Future<Uint8List> fetchAttachment(String path, int uid, String attachmentId) =>
      _run(limit: transferLimit, (c) async {
        await _ensureSelected(c, path);
        // PEEK, so downloading a file does not mark the message read.
        final result =
            await c.uidFetchMessage(uid, 'BODY.PEEK[$attachmentId]');
        if (result.messages.isEmpty) {
          throw StateError('Attachment $attachmentId is no longer there');
        }
        final part = result.messages.first.getPart(attachmentId) ??
            result.messages.first;
        final bytes = part.decodeContentBinary();
        if (bytes == null) {
          throw StateError('Attachment $attachmentId could not be decoded');
        }
        return bytes;
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
  Future<List<int>?> moveMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  ) =>
      _run((c) async {
        if (uids.isEmpty) return null;
        await _ensureSelected(c, fromPath);
        final target = imapCommandPath(toPath, _delimiter,
            serverTakesUtf8: c.serverInfo.supportsUtf8);
        final sequence = em.MessageSequence.fromIds(uids, isUid: true);

        if (c.serverInfo.supportsMove) {
          final result =
              await c.uidMove(sequence, targetMailboxPath: target);
          return _copiedUids(result);
        }

        // No MOVE: copy, mark the originals deleted, expunge. Not atomic, so
        // a failure between steps leaves a copy in both places rather than
        // losing the message, which is the right way round.
        final result = await c.uidCopy(sequence, targetMailboxPath: target);
        await c.uidStore(
          sequence,
          [em.MessageFlags.deleted],
          action: em.StoreAction.add,
          silent: true,
        );
        await c.expunge();
        return _copiedUids(result);
      });

  static List<int>? _copiedUids(em.GenericImapResult result) {
    // UIDPLUS servers report the new UIDs; others say nothing.
    final code = result.responseCodeCopyUid;
    if (code == null) return null;
    final list = code.targetSequence.toList();
    return list.isEmpty ? null : list;
  }

  @override
  Future<void> appendMessage(
    String path,
    String mimeText, {
    bool seen = true,
    bool draft = false,
  }) =>
      _run(limit: transferLimit, (c) async {
        final box = await _box(c, path);
        await c.appendMessageText(
          mimeText,
          targetMailbox: box,
          flags: [
            if (seen) em.MessageFlags.seen,
            if (draft) em.MessageFlags.draft,
          ],
        );
      });

  @override
  Future<void> expunge(String path) => _run((c) async {
        await _ensureSelected(c, path);
        await c.expunge();
      });

  @override
  Future<void> createFolder(String path) => _run((c) async {
        await c.createMailbox(imapCommandPath(path, _delimiter,
            serverTakesUtf8: c.serverInfo.supportsUtf8));
        _boxes = {};
      });

  @override
  Future<void> renameFolder(String oldPath, String newPath) => _run((c) async {
        final box = await _box(c, oldPath);
        await c.renameMailbox(
          box,
          imapCommandPath(newPath, _delimiter,
              serverTakesUtf8: c.serverInfo.supportsUtf8),
        );
        _boxes = {};
        if (_selectedPath == oldPath) _selectedPath = null;
      });

  @override
  bool get deleteTakesSubfolders => false;

  @override
  Future<void> deleteFolder(String path) => _run((c) async {
        final box = await _box(c, path);
        await c.deleteMailbox(box);
        _boxes = {};
        if (_selectedPath == path) _selectedPath = null;
      });

  /// IMAP IDLE: ask the server to speak up, and wait.
  ///
  /// Goes through the same serialising queue as everything else, which is the
  /// point: while this is waiting, nothing else can use the connection. That
  /// is correct — a client in IDLE may not send other commands — and it is
  /// why the caller gives it a timeout rather than waiting forever.
  ///
  /// Only events that can mean new mail wake it. An expunge is somebody
  /// deleting something, which the next ordinary sync will notice; waking the
  /// whole pass for it would turn housekeeping elsewhere into battery here.
  @override
  Future<bool> awaitChanges(
    String path, {
    required Duration timeout,
    Future<void>? cancel,
  }) =>
      // Its own handling of a lost connection (it wakes, below), and a limit
      // just past its own timeout for a socket that dies without saying so.
      _run(limit: timeout + commandLimit, watchLoss: false, (c) async {
        await _ensureSelected(c, path);
        final woken = Completer<bool>();
        void wake(em.ImapEvent event) {
          debugPrint('[myemail] idle on $path woke: ${event.runtimeType}');
          if (!woken.isCompleted) woken.complete(true);
        }

        // Called off: end with nothing to report, and let the finally below
        // send DONE so the connection is free for the pass that follows.
        cancel?.then((_) {
          if (!woken.isCompleted) woken.complete(false);
        });

        final subscriptions = [
          c.eventBus.on<em.ImapMessagesExistEvent>().listen(wake),
          c.eventBus.on<em.ImapMessagesRecentEvent>().listen(wake),
          c.eventBus.on<em.ImapFetchEvent>().listen(wake),
          // A dropped connection has to end the wait, or the loop sits on a
          // dead socket until the timeout and reports silence that never was.
          c.eventBus.on<em.ImapConnectionLostEvent>().listen(wake),
        ];

        try {
          debugPrint('[myemail] idle starting on $path');
          await c.idleStart();
          debugPrint('[myemail] idle running on $path');
        } catch (e) {
          // No IDLE on this server, or it refused. Degrade to a slow poll
          // rather than failing: the caller's timeout becomes the interval.
          for (final s in subscriptions) {
            await s.cancel();
          }
          debugPrint('[myemail] idle unavailable on $path: $e');
          await Future.any([
            Future<void>.delayed(timeout),
            ?cancel,
          ]);
          return false;
        }

        try {
          return await woken.future.timeout(timeout, onTimeout: () {
            debugPrint('[myemail] idle on $path timed out');
            return false;
          });
        } finally {
          for (final s in subscriptions) {
            await s.cancel();
          }
          try {
            await c.idleDone();
          } catch (_) {
            // Connection already gone. The next command reconnects.
          }
        }
      });

  @override
  Future<void> close() async {
    final c = _client;
    _client = null;
    _clientLost = null;
    _selectedPath = null;
    if (c == null) return;
    // Bounded: on a connection that has died without saying so, LOGOUT is
    // never answered, and a close that waits for it holds the queue as
    // surely as the command that found the connection dead.
    try {
      if (c.isLoggedIn) await c.logout().timeout(_goodbyeLimit);
    } catch (_) {}
    try {
      await c.disconnect().timeout(_goodbyeLimit);
    } catch (_) {}
  }

  // --- plumbing --------------------------------------------------------------

  /// How long one ordinary command may take, connecting included, before the
  /// connection is taken to be dead.
  ///
  /// enough_mail puts no limit on anything, and never fails a command whose
  /// connection drops: it announces the loss and leaves the command waiting.
  /// Every command for the account queues behind that one, so a network
  /// switch in the middle of a fetch used to stop that account's sync, and
  /// its notifications, until the app was killed.
  static const defaultCommandLimit = Duration(minutes: 2);

  /// For commands that carry a whole message or file, which on a slow
  /// connection can take minutes and still be healthy.
  static const defaultTransferLimit = Duration(minutes: 10);

  static const _goodbyeLimit = Duration(seconds: 5);

  /// Serialise [op] behind everything queued before it, on a live client.
  ///
  /// A dropped socket, a lost connection or a command over [limit] (the
  /// [commandLimit] when not given) ends the op with [ConnectionFailed] and
  /// lets go of the client, so the next call reconnects rather than waiting
  /// behind a command that will never finish. [watchLoss] is off only for
  /// IDLE, which wakes on a lost connection itself.
  Future<T> _run<T>(
    Future<T> Function(em.ImapClient c) op, {
    Duration? limit,
    bool watchLoss = true,
  }) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(
          await _attempt(op, watchLoss).timeout(limit ?? commandLimit),
        );
      } on SocketException catch (e, st) {
        await close();
        completer.completeError(ConnectionFailed('Connection lost: $e'), st);
      } on TimeoutException catch (_, st) {
        await close();
        completer.completeError(
          ConnectionFailed(
            'The mail server stopped answering, so the connection was '
            'dropped. It is tried again on the next sync.',
          ),
          st,
        );
      } on _ConnectionLost catch (_, st) {
        await close();
        completer.completeError(
          const ConnectionFailed('Connection lost. It is tried again on the '
              'next sync.'),
          st,
        );
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<T> _attempt<T>(
    Future<T> Function(em.ImapClient c) op,
    bool watchLoss,
  ) async {
    final client = await _ensureClient();
    final lost = _clientLost;
    if (!watchLoss || lost == null) return op(client);
    return Future.any([
      op(client),
      lost.then<T>((_) => throw const _ConnectionLost()),
    ]);
  }

  Future<em.ImapClient> _ensureClient() async {
    final existing = _client;
    if (existing != null && existing.isConnected && existing.isLoggedIn) {
      return existing;
    }
    await close();
    em.ImapClient client;
    try {
      client = await _connect(forceTokenRefresh: false);
    } on AuthenticationFailed {
      // One retry, and only for OAuth. isUsableAt decides a token is still
      // good by reading the device clock, so a tablet whose clock has drifted
      // will hand over a token the server has already retired and see a
      // refusal that looks exactly like a wrong password. Asking for a
      // definitely-new token costs one round trip on a path that has already
      // failed. A wrong app password, by contrast, is still wrong the second
      // time.
      if (credentials is! OAuthCredentials) rethrow;
      client = await _connect(forceTokenRefresh: true);
    }
    _clientLost = _lossOf(client);
    return _client = client;
  }

  /// A future that completes when [client] announces its connection is gone,
  /// which is all enough_mail does about it.
  static Future<void> _lossOf(em.ImapClient client) {
    final lost = Completer<void>();
    client.eventBus.on<em.ImapConnectionLostEvent>().listen((_) {
      if (!lost.isCompleted) lost.complete();
    });
    return lost.future;
  }

  Future<em.ImapClient> _connect({required bool forceTokenRefresh}) async {
    final client = em.ImapClient(isLogEnabled: isLogEnabled);
    try {
      await client.connectToServer(host, port, isSecure: useTls);
    } on Exception catch (e) {
      throw ConnectionFailed('Could not reach $host. Check the connection. ($e)');
    }
    try {
      switch (credentials) {
        case PasswordCredentials(:final password):
          await client.login(user, password);
        case OAuthCredentials(:final accessToken):
          await client.authenticateWithOAuth2(
            user,
            await accessToken(force: forceTokenRefresh),
          );
      }
    } on em.ImapException catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      throw AuthenticationFailed(loginFailureMessage(e.message));
    } catch (_) {
      // A token refresh can fail for its own reasons (no network, a revoked
      // sign-in). Those exceptions are already the right shape for the UI, so
      // they travel up as they are; the socket still has to be let go.
      try {
        await client.disconnect();
      } catch (_) {}
      rethrow;
    }
    _selectedPath = null;
    return client;
  }

  /// Turn the server's refusal into something a person can act on.
  static String loginFailureMessage(String? raw) {
    final text = raw ?? '';
    if (text.contains('AUTHENTICATIONFAILED') ||
        text.toLowerCase().contains('invalid credentials')) {
      return 'The mail server refused the sign-in. For Gmail, check the '
          'address and use an app password rather than the normal account '
          'password. For Outlook.com, sign in to the account again.';
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
    final selectable = selectableMailboxes(boxes);
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
    // Forgotten before asking rather than after: a SELECT the server refuses
    // (a Gmail label deleted on the web) leaves no folder selected there,
    // and a path still remembered here sent the next read to nothing, which
    // the server answers with BAD.
    _selectedPath = null;
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
        MessageFlag.answered => em.MessageFlags.answered,
      };
}

/// The client announced its connection was lost while a command waited.
class _ConnectionLost implements Exception {
  const _ConnectionLost();
}
