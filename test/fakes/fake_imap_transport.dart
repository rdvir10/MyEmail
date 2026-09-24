import 'dart:typed_data';
import 'dart:async';

import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';

/// An in-memory IMAP server the tests can mutate between calls: deliver mail,
/// delete it, change flags, and rebuild a folder (new UIDVALIDITY) to prove
/// the sync notices each case.
class FakeImapTransport implements ImapTransport {
  final Map<String, FakeFolder> folders = {};

  /// Every call, for asserting what the sync chose to ask the server.
  final List<String> calls = [];

  /// Servers without CONDSTORE report no HIGHESTMODSEQ and ignore
  /// CHANGEDSINCE.
  bool supportsCondStore = true;

  /// When true every call fails as a dropped connection, so tests can prove
  /// the cache is what gets served.
  bool offline = false;

  /// Thrown by every call, for testing what a broken account does to the rest
  /// of the app. Distinct from [offline], which is specifically a connection
  /// failure; this one can be an authentication failure or anything else.
  Object? failWith;

  /// Folders the server will not move mail out of.
  final Set<String> refuseMovesFrom = {};

  void _online() {
    final failure = failWith;
    if (failure != null) throw failure;
    if (offline) throw const ConnectionFailed('fake server is offline');
  }

  FakeFolder folder(
    String path, {
    FolderRole role = FolderRole.user,
    bool serverManaged = false,
  }) =>
      folders.putIfAbsent(
        path,
        () => FakeFolder(path, role: role, serverManaged: serverManaged),
      );

  FakeFolder _require(String path) {
    final f = folders[path];
    if (f == null) throw StateError('No folder $path on the fake server');
    return f;
  }

  @override
  Future<List<RemoteFolder>> listFolders() async {
    _online();
    calls.add('LIST');
    return [
      for (final f in folders.values)
        RemoteFolder(
          path: f.path,
          role: f.role,
          isServerManaged: f.serverManaged,
          unread: f.messages.values.where((m) => !m.isRead).length,
          total: f.messages.length,
        ),
    ];
  }

  @override
  Future<FolderStatus> selectFolder(String path) async {
    _online();
    calls.add('SELECT $path');
    final f = _require(path);
    return FolderStatus(
      uidValidity: f.uidValidity,
      exists: f.messages.length,
      uidNext: f.nextUid,
      highestModSeq: supportsCondStore ? f.highestModSeq : null,
    );
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersBySequence(
    String path,
    int start,
    int end,
  ) async {
    calls.add('FETCH $path $start:$end');
    final ordered = _require(path).ordered;
    return [
      for (var seq = start; seq <= end && seq <= ordered.length; seq++)
        ordered[seq - 1].header,
    ];
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersFromUid(
    String path,
    int fromUid, {
    DateTime? windowStart,
  }) async {
    calls.add('UID FETCH $path $fromUid:*');
    final ordered = _require(path).ordered;
    if (ordered.isEmpty) return const [];
    final hits = [
      for (final m in ordered)
        if (m.uid >= fromUid) m.header,
    ];
    // IMAP quirk: n:* always includes the highest UID.
    return hits.isEmpty ? [ordered.last.header] : hits;
  }

  @override
  Future<List<RemoteFlags>> fetchFlags(
    String path,
    int fromUid,
    int toUid, {
    int? changedSinceModSeq,
    DateTime? windowStart,
  }) async {
    calls.add('UID FETCH $path $fromUid:$toUid FLAGS'
        '${changedSinceModSeq == null ? '' : ' CHANGEDSINCE $changedSinceModSeq'}');
    final since = supportsCondStore ? changedSinceModSeq : null;
    return [
      for (final m in _require(path).ordered)
        if (m.uid >= fromUid &&
            m.uid <= toUid &&
            (since == null || m.modSeq > since))
          RemoteFlags(uid: m.uid, isRead: m.isRead, isFlagged: m.isFlagged),
    ];
  }

  @override
  Future<Set<int>> existingUids(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) async {
    calls.add('UID SEARCH $path $fromUid:$toUid');
    return {
      for (final uid in _require(path).messages.keys)
        if (uid >= fromUid && uid <= toUid) uid,
    };
  }

  @override
  Future<List<int>> searchUids(
    String path,
    String query, {
    int limit = 100,
  }) async {
    _online();
    calls.add('UID SEARCH $path TEXT "$query"');
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    final hits = [
      for (final m in _require(path).ordered)
        if (words.every(
            (w) => '${m.subject} ${m.from} ${m.body}'.toLowerCase().contains(w)))
          m.uid,
    ]..sort((a, b) => b.compareTo(a));
    return hits.take(limit).toList();
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersByUids(
    String path,
    List<int> uids,
  ) async {
    _online();
    calls.add('UID FETCH $path ${uids.join(',')}');
    final folder = _require(path);
    return [
      for (final uid in uids)
        if (folder.messages[uid] case final m?) m.header,
    ];
  }

  @override
  Future<MailBody> fetchBody(String path, int uid) async {
    _online();
    calls.add('UID FETCH $path $uid BODY');
    final m = _require(path).messages[uid];
    if (m == null) throw StateError('No message $uid in $path');
    return MailBody(text: m.body, html: m.html);
  }

  @override
  Future<bool> respondToInvite(
    String path,
    int uid,
    InviteResponse response, {
    String? iCalUid,
  }) async {
    calls.add('RESPOND $path $uid ${response.partStat}'
        '${iCalUid == null ? '' : ' uid=$iCalUid'}');
    return false;
  }

  @override
  Future<String> fetchRaw(String path, int uid) async {
    _online();
    calls.add('UID FETCH $path $uid RAW');
    final m = _require(path).messages[uid];
    if (m == null) throw StateError('No message $uid in $path');
    return 'Subject: ${m.subject}\r\n\r\n${m.body}';
  }

  /// Files on a message, keyed by uid. Empty unless a test puts some there.
  final Map<int, List<MailAttachment>> attachments = {};

  @override
  Future<List<MailAttachment>> listAttachments(String path, int uid) async {
    _online();
    calls.add('UID FETCH $path $uid BODYSTRUCTURE');
    return attachments[uid] ?? const [];
  }

  @override
  Future<Uint8List> fetchAttachment(
    String path,
    int uid,
    String attachmentId,
  ) async {
    _online();
    calls.add('UID FETCH $path $uid BODY[$attachmentId]');
    final found = (attachments[uid] ?? const <MailAttachment>[])
        .where((a) => a.id == attachmentId)
        .firstOrNull;
    if (found == null) throw StateError('No attachment $attachmentId');
    return Uint8List.fromList(
      List<int>.generate(found.sizeBytes.clamp(1, 64), (i) => i % 256),
    );
  }

  @override
  Future<void> storeFlag(
    String path, {
    required List<int> uids,
    required MessageFlag flag,
    required bool set,
  }) async {
    calls.add('UID STORE $path ${uids.join(',')} ${set ? '+' : '-'}$flag');
    final f = _require(path);
    for (final uid in uids) {
      f.messages[uid]?._apply(flag, set, f.bump());
    }
  }

  @override
  Future<void> storeFlagOnAll(
    String path, {
    required MessageFlag flag,
    required bool set,
  }) async {
    calls.add('STORE $path 1:* ${set ? '+' : '-'}$flag');
    final f = _require(path);
    for (final m in f.messages.values) {
      m._apply(flag, set, f.bump());
    }
  }

  /// Set false to model a server without MOVE or UIDPLUS, which cannot say
  /// what UIDs the copies were given.
  bool reportsCopyUids = true;

  /// Whether this server hands a preview over with a list row, as Graph
  /// does and IMAP does not.
  bool suppliesPreviews = false;

  @override
  bool get canRefreshHeaders => suppliesPreviews;

  @override
  Future<List<RemoteHeader>> refreshHeaders(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) async {
    _online();
    calls.add('REFRESH $path $fromUid:$toUid');
    if (!suppliesPreviews) return const [];
    return [
      for (final m in _require(path).ordered)
        if (m.uid >= fromUid && m.uid <= toUid) m.header,
    ];
  }

  @override
  Future<List<int>?> moveMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  ) async {
    _online();
    if (refuseMovesFrom.contains(fromPath)) {
      throw StateError('the server would not move mail out of $fromPath');
    }
    calls.add('UID MOVE $fromPath ${uids.join(',')} $toPath');
    final from = _require(fromPath);
    final to = _require(toPath);
    final newUids = <int>[];
    for (final uid in uids) {
      final m = from.messages.remove(uid);
      if (m == null) continue;
      final moved = to.deliver(
        subject: m.subject,
        from: m.from,
        date: m.date,
        isRead: m.isRead,
        body: m.body,
        messageId: m.messageId,
      );
      newUids.add(moved.uid);
    }
    from.bump();
    return reportsCopyUids ? newUids : null;
  }

  /// Messages appended by a send, so tests can assert a Sent copy was filed.
  final List<String> appended = [];

  @override
  Future<void> appendMessage(
    String path,
    String mimeText, {
    bool seen = true,
    bool draft = false,
  }) async {
    _online();
    calls.add('APPEND $path${draft ? r' \Draft' : ''}');
    appended.add(mimeText);
    folder(path).deliver(subject: 'appended', isRead: seen);
  }

  @override
  Future<void> expunge(String path) async {
    _online();
    calls.add('EXPUNGE $path');
    _require(path).messages.removeWhere((_, m) => m.isDeleted);
  }

  @override
  Future<void> createFolder(String path) async {
    calls.add('CREATE $path');
    folder(path);
  }

  @override
  Future<void> renameFolder(String oldPath, String newPath) async {
    calls.add('RENAME $oldPath $newPath');
    // Its subfolders go with it, as RFC 3501 has a server do.
    for (final path in [...folders.keys]) {
      if (path != oldPath && !path.startsWith('$oldPath/')) continue;
      final moved = newPath + path.substring(oldPath.length);
      folders[moved] = folders.remove(path)!..path = moved;
    }
  }

  @override
  bool get deleteTakesSubfolders => false;

  @override
  Future<void> deleteFolder(String path) async {
    calls.add('DELETE $path');
    folders.remove(path);
  }

  /// Completed by [deliverWhileIdle] to wake a waiter, as a real server would
  /// when mail lands. Left alone, [awaitChanges] times out instead.
  Completer<bool>? _idle;

  /// Whether anything is currently waiting in IDLE.
  bool get isIdling => _idle != null;

  /// Deliver to [path] and wake whatever is in IDLE, the way a server does.
  FakeMessage deliverWhileIdle(String path, {String? subject, DateTime? date}) {
    final m = folder(path).deliver(subject: subject, date: date);
    final waiter = _idle;
    _idle = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(true);
    return m;
  }

  /// How many waits ended because they were called off.
  int idleCancelled = 0;

  @override
  Future<bool> awaitChanges(
    String path, {
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    _online();
    calls.add('IDLE $path');
    final waiter = Completer<bool>();
    _idle = waiter;
    cancel?.then((_) {
      if (waiter.isCompleted) return;
      idleCancelled++;
      waiter.complete(false);
    });
    final woken = await waiter.future.timeout(
      timeout,
      onTimeout: () => false,
    );
    if (identical(_idle, waiter)) _idle = null;
    return woken;
  }

  @override
  Future<void> close() async {
    calls.add('LOGOUT');
  }
}

class FakeFolder {
  FakeFolder(this.path, {this.role = FolderRole.user, this.serverManaged = false});

  String path;
  final FolderRole role;

  /// Gmail's Starred and Important. See [RemoteFolder.isServerManaged].
  final bool serverManaged;
  int uidValidity = 1000;
  int nextUid = 1;
  int highestModSeq = 1;
  final Map<int, FakeMessage> messages = {};

  List<FakeMessage> get ordered =>
      messages.values.toList()..sort((a, b) => a.uid.compareTo(b.uid));

  int bump() => ++highestModSeq;

  /// Deliver a message with the next UID.
  FakeMessage deliver({
    String? subject,
    String from = 'someone@example.com',
    DateTime? date,
    bool isRead = false,
    String body = 'Hello.',
    String? messageId,
  }) {
    final uid = nextUid++;
    final m = FakeMessage(
      uid: uid,
      subject: subject ?? 'Message $uid',
      from: from,
      date: date ?? DateTime(2026, 9, 1).add(Duration(hours: uid)),
      isRead: isRead,
      body: body,
      modSeq: bump(),
      messageId: messageId ?? '<m${FakeMessage.seq++}@example.com>',
    );
    messages[uid] = m;
    return m;
  }

  void delete(int uid) => messages.remove(uid);

  /// Simulate the server rebuilding the mailbox: new UIDVALIDITY and every
  /// message renumbered from 1.
  void rebuild() {
    uidValidity += 1;
    final old = ordered;
    messages.clear();
    nextUid = 1;
    highestModSeq = 1;
    for (final m in old) {
      deliver(
        subject: m.subject,
        from: m.from,
        date: m.date,
        isRead: m.isRead,
        body: m.body,
      );
    }
  }
}

class FakeMessage {
  FakeMessage({
    required this.uid,
    required this.subject,
    required this.from,
    required this.date,
    required this.isRead,
    required this.body,
    required this.modSeq,
    required this.messageId,
    this.isFlagged = false,
    this.html,
  });

  /// Made when the message is first delivered and kept through every move.
  /// A real Message-ID follows a message between folders and servers, which
  /// is what lets one be found again after a move that did not say where.
  final String messageId;

  /// What a server that sends previews would send. Empty for one that does
  /// not, which is every IMAP server.
  String preview = '';

  static int seq = 0;

  final int uid;
  final String subject;
  final String from;
  final DateTime date;
  bool isRead;
  bool isFlagged;
  bool isDeleted = false;
  bool isAnswered = false;
  final String body;
  final String? html;
  int modSeq;

  void _apply(MessageFlag flag, bool set, int newModSeq) {
    switch (flag) {
      case MessageFlag.seen:
        isRead = set;
      case MessageFlag.flagged:
        isFlagged = set;
      case MessageFlag.deleted:
        isDeleted = set;
      case MessageFlag.answered:
        isAnswered = set;
    }
    modSeq = newModSeq;
  }

  RemoteHeader get header => RemoteHeader(
        uid: uid,
        subject: subject,
        from: MailAddress(email: from),
        to: const [MailAddress(email: 'me@example.com')],
        date: date,
        isRead: isRead,
        isFlagged: isFlagged,
        hasAttachments: false,
        preview: preview,
        messageId: messageId,
      );
}
