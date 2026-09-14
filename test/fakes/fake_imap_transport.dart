import 'package:mailtree/data/imap/imap_transport.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/domain/folder_role.dart';
import 'package:mailtree/domain/mail_message.dart';

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

  void _online() {
    if (offline) throw const ConnectionFailed('fake server is offline');
  }

  FakeFolder folder(String path, {FolderRole role = FolderRole.user}) =>
      folders.putIfAbsent(path, () => FakeFolder(path, role: role));

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
  Future<List<RemoteHeader>> fetchHeadersFromUid(String path, int fromUid) async {
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
  Future<Set<int>> existingUids(String path, int fromUid, int toUid) async {
    calls.add('UID SEARCH $path $fromUid:$toUid');
    return {
      for (final uid in _require(path).messages.keys)
        if (uid >= fromUid && uid <= toUid) uid,
    };
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

  @override
  Future<void> expunge(String path) async {
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
    final f = folders.remove(oldPath)!;
    folders[newPath] = f..path = newPath;
  }

  @override
  Future<void> deleteFolder(String path) async {
    calls.add('DELETE $path');
    folders.remove(path);
  }

  @override
  Future<void> close() async {
    calls.add('LOGOUT');
  }
}

class FakeFolder {
  FakeFolder(this.path, {this.role = FolderRole.user});

  String path;
  final FolderRole role;
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
    this.isFlagged = false,
    this.html,
  });

  final int uid;
  final String subject;
  final String from;
  final DateTime date;
  bool isRead;
  bool isFlagged;
  bool isDeleted = false;
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
      );
}
