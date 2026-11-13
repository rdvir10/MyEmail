import 'package:flutter/foundation.dart';

/// What a change made on this device does to a message on its server.
enum PendingKind {
  /// Into Trash, or for good where it is in Trash already: see
  /// `MailEngine.deleteMessages`.
  delete,

  /// Into another folder of the same account.
  move,

  /// Read, or unread.
  read,

  /// Flagged, or not.
  flag,

  /// Outlook's Follow Up: flagged for a day, or marked complete.
  followUp;

  /// Whether it takes the message out of the folder it is in.
  bool get removes => this == delete || this == move;
}

/// A change made on this device that its server has not had yet: the
/// server could not be reached when it was made (no network, or one that
/// was not answering, as an aeroplane's often is).
///
/// Kept in the database beside the cache, so that the background sync can
/// send it as well as the app, and shown meanwhile as if made: see
/// [WaitingOverlay]. One row per message, so that a batch that half went
/// is half sent.
@immutable
class PendingChange {
  const PendingChange({
    this.id = 0,
    required this.accountId,
    required this.path,
    required this.uid,
    this.uidValidity,
    this.messageId,
    required this.kind,
    this.toPath,
    this.wanted,
    this.due,
    required this.action,
    required this.madeAt,
    this.tries = 0,
    this.error,
  });

  /// The database's number for it, 0 before it is kept. Changes are sent
  /// in the order of these, which is the order they were made in.
  final int id;

  final String accountId;

  /// The folder the message is in on its server, and its number there.
  final String path;
  final int uid;

  /// What the folder's numbers meant when this was made: its UIDVALIDITY.
  /// A folder whose numbers have been dealt out afresh since no longer has
  /// the message under [uid], and it is found again by its [messageId].
  final int? uidValidity;

  /// The message's own Message-ID, where it has one.
  final String? messageId;

  final PendingKind kind;

  /// Where a move goes. Where a delete goes: Trash, or the message's own
  /// folder for one deleted for good.
  final String? toPath;

  /// Read for [PendingKind.read]; flagged for [PendingKind.flag]; and for
  /// [PendingKind.followUp], flagged rather than marked complete.
  final bool? wanted;

  /// A follow up's day, where it has one.
  final DateTime? due;

  /// The action the change was part of: the messages of one delete or one
  /// move share it, and Undo takes them back together.
  final String action;

  final DateTime madeAt;

  /// How many times sending it has failed, and the last reason.
  final int tries;
  final String? error;

  PendingChange copyWith({
    int? id,
    String? path,
    int? uid,
    int? uidValidity,
    String? toPath,
    int? tries,
    String? error,
  }) =>
      PendingChange(
        id: id ?? this.id,
        accountId: accountId,
        path: path ?? this.path,
        uid: uid ?? this.uid,
        uidValidity: uidValidity ?? this.uidValidity,
        messageId: messageId,
        kind: kind,
        toPath: toPath ?? this.toPath,
        wanted: wanted,
        due: due,
        action: action,
        madeAt: madeAt,
        tries: tries ?? this.tries,
        error: error ?? this.error,
      );

  /// What has to be the same for two changes to be sent together: one
  /// request to the server carries them all.
  Object get sentWith => (accountId, path, kind, toPath, wanted, due);

  @override
  String toString() =>
      'PendingChange(#$id ${kind.name} $accountId:$path#$uid'
      '${toPath == null ? '' : ' to $toPath'}'
      '${wanted == null ? '' : ' $wanted'})';
}

/// What the changes still waiting for a server make of the messages they
/// are about: a list shows them as they will be, not as the server last
/// said they were.
///
/// The cache itself keeps what the server said, and the sync goes on
/// writing that. Laid over it where it is read, a change waiting cannot be
/// undone by a sync that finds the server as it was, and nothing has to be
/// put right in the cache when the change goes, or when it is taken back.
class WaitingOverlay {
  WaitingOverlay(Iterable<PendingChange> changes) {
    // In the order made: a later change to a message says what it ends up as.
    for (final c in [...changes]..sort((a, b) => a.id.compareTo(b.id))) {
      final key = (c.path, c.uid);
      final id = c.messageId;
      switch (c.kind) {
        case PendingKind.delete:
          _gone[key] = id;
          if (id != null) _deleted.add(id);
        case PendingKind.move:
          _gone[key] = id;
        case PendingKind.read:
          if (c.wanted case final read?) {
            _read[key] = (read, id);
            if (id != null) _readById[id] = read;
          }
        case PendingKind.flag:
        case PendingKind.followUp:
          if (c.wanted case final flagged?) {
            _flagged[key] = (flagged, id);
            if (id != null) _flaggedById[id] = flagged;
          }
      }
      _touched.putIfAbsent(c.path, () => {}).add(c.uid);
    }
  }

  static final none = WaitingOverlay(const []);

  /// By folder and number, with the Message-ID of the message the change
  /// was made to. A folder whose numbers are dealt out afresh before the
  /// change goes gives its number to another message, which is not to be
  /// hidden or marked for it.
  final Map<(String, int), String?> _gone = {};
  final Map<(String, int), (bool, String?)> _read = {};
  final Map<(String, int), (bool, String?)> _flagged = {};

  /// The Message-IDs of the messages on their way to Trash.
  final Set<String> _deleted = {};

  /// The same marks by Message-ID, for the message seen from another
  /// folder: a Gmail message is in its label's folder and in All Mail, and
  /// is read or starred in both at once.
  final Map<String, bool> _readById = {};
  final Map<String, bool> _flaggedById = {};
  final Map<String, Set<int>> _touched = {};

  bool get isEmpty => _touched.isEmpty;

  /// Whether a change made to [theirs] is about the message [messageId]:
  /// yes where either is not known.
  static bool _same(String? theirs, String? messageId) =>
      theirs == null || messageId == null || theirs == messageId;

  /// Whether the message, [messageId] where known, is on its way out of
  /// [path]: deleted, or moved.
  bool hides(String path, int uid, [String? messageId]) =>
      _gone.containsKey((path, uid)) && _same(_gone[(path, uid)], messageId);

  /// How many of [path]'s numbers are on their way out of it, at most.
  int hiddenIn(String path) => _gone.keys.where((g) => g.$1 == path).length;

  /// Whether the message [messageId] is on its way to Trash from wherever
  /// it is: from Gmail's Inbox, it goes from All Mail with it.
  bool deletes(String? messageId) =>
      messageId != null && _deleted.contains(messageId);

  /// Read or unread as asked here, where a change says; null where none.
  /// [messageId] finds a change made to the message from another folder.
  bool? readOf(String path, int uid, [String? messageId]) =>
      _markOf(_read, _readById, path, uid, messageId);

  /// Flagged or not as asked here, where a change says; null where none.
  bool? flaggedOf(String path, int uid, [String? messageId]) =>
      _markOf(_flagged, _flaggedById, path, uid, messageId);

  static bool? _markOf(
    Map<(String, int), (bool, String?)> byNumber,
    Map<String, bool> byId,
    String path,
    int uid,
    String? messageId,
  ) {
    if (byNumber[(path, uid)] case (final on, final theirs)
        when _same(theirs, messageId)) {
      return on;
    }
    return messageId == null ? null : byId[messageId];
  }

  /// The messages of [path] flagged here while their server was out of
  /// reach, and not on their way out.
  Iterable<int> flaggedIn(String path) => [
        for (final MapEntry(key: (p, uid), value: (on, _)) in _flagged.entries)
          if (p == path && on && !_gone.containsKey((p, uid))) uid,
      ];

  /// Every folder a change waits in, and the messages of it each is about.
  Map<String, Set<int>> get touched => _touched;

  /// What one message's changes do to its folder's counts, from [isRead]
  /// as the server last said: one fewer in it where it is on its way out,
  /// and one more or fewer unread where it was marked.
  ({int unread, int total}) countChange(
    String path,
    int uid,
    bool isRead, [
    String? messageId,
  ]) {
    if (hides(path, uid, messageId)) {
      return (unread: isRead ? 0 : -1, total: -1);
    }
    final read = readOf(path, uid, messageId);
    if (read == null || read == isRead) return (unread: 0, total: 0);
    return (unread: read ? -1 : 1, total: 0);
  }
}
