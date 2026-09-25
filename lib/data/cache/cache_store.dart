import 'package:flutter/foundation.dart';

import '../../domain/mail_message.dart';

/// Per-folder bookkeeping the sync needs between runs.
@immutable
class FolderSyncState {
  const FolderSyncState({
    required this.uidValidity,
    required this.lastSync,
    this.uidNext,
    this.highestModSeq,
    this.previewsChecked = false,
  });

  final int uidValidity;
  final DateTime lastSync;
  final int? uidNext;
  final int? highestModSeq;

  /// Whether the server has been asked for the preview of every row cached
  /// here. Once it has, a row with none really has none (a meeting reply
  /// with no text), and asking again every sync would only cost a full
  /// pass over the folder. Rows cached later come with the server's preview.
  final bool previewsChecked;

  FolderSyncState copyWith({int? uidNext, int? highestModSeq, DateTime? lastSync}) {
    return FolderSyncState(
      uidValidity: uidValidity,
      lastSync: lastSync ?? this.lastSync,
      uidNext: uidNext ?? this.uidNext,
      highestModSeq: highestModSeq ?? this.highestModSeq,
      previewsChecked: previewsChecked,
    );
  }
}

/// What the sync needs of each cached row: no more. Reading whole rows for
/// it pulled every cached body out of the database on every sync.
typedef SyncRow = ({int uid, DateTime date, bool hasPreview});

/// A cached row's flags, all of them, as [CacheStore.updateFlags] writes
/// them.
typedef CachedFlags = ({
  bool isRead,
  bool isFlagged,
  bool isAnswered,
  bool isForwarded,
});

/// A message as cached: the list row plus, once fetched, the body.
@immutable
class CachedMessage {
  const CachedMessage({
    required this.uid,
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.isRead,
    required this.isFlagged,
    required this.hasAttachments,
    this.isAnswered = false,
    this.isForwarded = false,
    this.arrived,
    this.cc = const [],
    this.replyTo = const [],
    this.attachmentBytes = 0,
    this.isMeeting = false,
    this.preview = '',
    this.bodyText,
    this.bodyHtml,
    this.calendar,
    this.messageId,
    this.inReplyTo,
  });

  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final List<MailAddress> cc;

  /// See [MailMessage.replyTo].
  final List<MailAddress> replyTo;
  final DateTime date;

  /// See [MailMessage.arrived].
  final DateTime? arrived;
  final bool isRead;
  final bool isFlagged;

  /// See [MailMessage.isAnswered] and [MailMessage.isForwarded].
  final bool isAnswered;
  final bool isForwarded;
  final bool hasAttachments;

  /// See [MailMessage.attachmentBytes].
  final int attachmentBytes;

  /// See [MailMessage.isMeeting].
  final bool isMeeting;
  final String preview;
  final String? bodyText;
  final String? bodyHtml;

  /// The invitation inside the message, cached with the body.
  final String? calendar;

  /// See [MailMessage.messageId]. Null for anything cached before threading
  /// existed, which is why grouping never assumes they are there.
  final String? messageId;
  final String? inReplyTo;

  bool get hasBody => bodyText != null;

  CachedMessage copyWith({
    bool? isRead,
    bool? isFlagged,
    bool? isAnswered,
    bool? isForwarded,
    String? preview,
    String? bodyText,
    String? bodyHtml,
    String? calendar,
  }) {
    return CachedMessage(
      uid: uid,
      subject: subject,
      from: from,
      to: to,
      cc: cc,
      replyTo: replyTo,
      date: date,
      arrived: arrived,
      isRead: isRead ?? this.isRead,
      isFlagged: isFlagged ?? this.isFlagged,
      isAnswered: isAnswered ?? this.isAnswered,
      isForwarded: isForwarded ?? this.isForwarded,
      hasAttachments: hasAttachments,
      attachmentBytes: attachmentBytes,
      isMeeting: isMeeting,
      preview: preview ?? this.preview,
      bodyText: bodyText ?? this.bodyText,
      bodyHtml: bodyHtml ?? this.bodyHtml,
      calendar: calendar ?? this.calendar,
      messageId: messageId,
      inReplyTo: inReplyTo,
    );
  }

  MailMessage toMailMessage({required String accountId, required String folderId}) {
    return MailMessage(
      id: MailMessage.idFor(folderId, uid),
      accountId: accountId,
      folderId: folderId,
      uid: uid,
      subject: subject,
      from: from,
      to: to,
      cc: cc,
      replyTo: replyTo,
      date: date,
      arrived: arrived,
      preview: preview,
      isRead: isRead,
      isFlagged: isFlagged,
      isAnswered: isAnswered,
      isForwarded: isForwarded,
      hasAttachments: hasAttachments,
      attachmentBytes: attachmentBytes,
      isMeeting: isMeeting,
      messageId: messageId,
      inReplyTo: inReplyTo,
    );
  }
}

/// Where cached messages and sync state live. Keyed by account and folder
/// path; the Drift implementation is the real one, the memory one is for
/// tests and the browser preview.
abstract class CacheStore {
  Future<FolderSyncState?> readFolderState(String accountId, String path);
  Future<void> writeFolderState(
    String accountId,
    String path,
    FolderSyncState state,
  );

  /// Drop everything cached for the folder, state included. Used when
  /// UIDVALIDITY changes and the cached UIDs no longer mean anything.
  Future<void> clearFolder(String accountId, String path);

  /// Newest first by UID.
  Future<List<CachedMessage>> readMessages(
    String accountId,
    String path, {
    int offset = 0,
    int limit = 50,
  });

  /// Every cached row of the folder, as little of each as the sync needs.
  Future<List<SyncRow>> readSyncRows(String accountId, String path);

  Future<int> countMessages(String accountId, String path);

  /// Every sender, recipient and copied address on the newest [limit]
  /// cached messages, in message order, newest first. Duplicates included:
  /// the caller counts them, which is how "the person you write to most"
  /// is known.
  Future<List<MailAddress>> recentAddresses({int limit = 2000});
  Future<({int min, int max})?> uidRange(String accountId, String path);
  Future<CachedMessage?> readMessage(String accountId, String path, int uid);

  /// The `Message-ID` header of each of [uids] that has one, in the order
  /// the uids were given.
  ///
  /// A Message-ID follows a message between folders and between servers,
  /// which is what makes it possible to find a message again after a move
  /// that did not say where it put it.
  Future<List<String>> messageIdsFor(
    String accountId,
    String path,
    List<int> uids,
  );

  /// The uids in [path] whose `Message-ID` is one of [messageIds].
  Future<List<int>> uidsForMessageIds(
    String accountId,
    String path,
    Set<String> messageIds,
  );

  Future<void> upsertMessages(
    String accountId,
    String path,
    List<CachedMessage> messages,
  );

  Future<void> updateFlags(
    String accountId,
    String path,
    Map<int, CachedFlags> flagsByUid,
  );

  Future<void> deleteUids(String accountId, String path, Set<int> uids);

  Future<void> writeBody(
    String accountId,
    String path,
    int uid, {
    required String text,
    String? html,
    String? calendar,
    required String preview,
  });

  /// A folder rename moves its cache (and its subtree's) rather than losing
  /// it; UIDs stay valid across RENAME on every server we care about.
  ///
  /// Whatever is cached at [newPath] already is thrown away first. The
  /// server has just accepted the name, so it belongs to no folder there
  /// now: one deleted or renamed away on another device.
  Future<void> renameFolder(String accountId, String oldPath, String newPath);

  Future<void> deleteFolder(String accountId, String path);

  /// Drop the cache of every folder of the account not in [paths], the
  /// server's full listing. A folder deleted or renamed on another device
  /// otherwise kept its messages and bodies here for good.
  Future<void> pruneFolders(String accountId, Set<String> paths);
  Future<void> deleteAccount(String accountId);
}

/// In-memory implementation for tests and the browser preview.
class MemoryCacheStore implements CacheStore {
  final Map<String, FolderSyncState> _states = {};
  final Map<String, Map<int, CachedMessage>> _messages = {};

  /// Separates the two halves of the composite key.
  ///
  /// NUL, because a folder path may contain very nearly anything a mail
  /// server allows and this is the one byte it cannot, so no path can forge a
  /// key boundary. Written as an escape rather than as the character itself:
  /// a literal NUL in the source made this file read as binary to grep and to
  /// editors, and left an invisible byte that any tool touching the file could
  /// have dropped, silently merging two accounts' cache entries.
  static const _separator = '\u0000';

  static String _k(String accountId, String path) =>
      '$accountId$_separator$path';

  Map<int, CachedMessage> _folder(String accountId, String path) =>
      _messages.putIfAbsent(_k(accountId, path), () => {});

  @override
  Future<FolderSyncState?> readFolderState(String accountId, String path) async =>
      _states[_k(accountId, path)];

  @override
  Future<void> writeFolderState(
    String accountId,
    String path,
    FolderSyncState state,
  ) async =>
      _states[_k(accountId, path)] = state;

  @override
  Future<void> clearFolder(String accountId, String path) async {
    _states.remove(_k(accountId, path));
    _messages.remove(_k(accountId, path));
  }

  @override
  Future<List<CachedMessage>> readMessages(
    String accountId,
    String path, {
    int offset = 0,
    int limit = 50,
  }) async {
    final all = _folder(accountId, path).values.toList()
      ..sort((a, b) => b.uid.compareTo(a.uid));
    if (offset >= all.length) return const [];
    return all.sublist(offset, (offset + limit).clamp(0, all.length));
  }

  @override
  Future<List<SyncRow>> readSyncRows(String accountId, String path) async => [
        for (final m in _folder(accountId, path).values)
          (uid: m.uid, date: m.date, hasPreview: m.preview.isNotEmpty),
      ]..sort((a, b) => b.uid.compareTo(a.uid));

  @override
  Future<List<MailAddress>> recentAddresses({int limit = 2000}) async {
    final all = <CachedMessage>[
      for (final folder in _messages.values) ...folder.values,
    ]..sort((a, b) => b.date.compareTo(a.date));
    return [
      for (final m in all.take(limit)) ...[m.from, ...m.to, ...m.cc],
    ];
  }

  @override
  Future<int> countMessages(String accountId, String path) async =>
      _folder(accountId, path).length;

  @override
  Future<({int min, int max})?> uidRange(String accountId, String path) async {
    final uids = _folder(accountId, path).keys;
    if (uids.isEmpty) return null;
    var min = uids.first;
    var max = uids.first;
    for (final u in uids) {
      if (u < min) min = u;
      if (u > max) max = u;
    }
    return (min: min, max: max);
  }

  @override
  Future<CachedMessage?> readMessage(
    String accountId,
    String path,
    int uid,
  ) async =>
      _folder(accountId, path)[uid];

  @override
  Future<List<String>> messageIdsFor(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    final folder = _folder(accountId, path);
    return [
      for (final uid in uids)
        if (folder[uid]?.messageId case final id? when id.isNotEmpty) id,
    ];
  }

  @override
  Future<List<int>> uidsForMessageIds(
    String accountId,
    String path,
    Set<String> messageIds,
  ) async =>
      [
        for (final m in _folder(accountId, path).values)
          if (m.messageId != null && messageIds.contains(m.messageId)) m.uid,
      ];

  @override
  Future<void> upsertMessages(
    String accountId,
    String path,
    List<CachedMessage> messages,
  ) async {
    final folder = _folder(accountId, path);
    for (final m in messages) {
      final existing = folder[m.uid];
      // Keep a body we already fetched; headers alone never overwrite it.
      folder[m.uid] = existing == null
          ? m
          : m.copyWith(
              // As the database does it: a new line replaces the old, and
              // only an empty one leaves it. The two used to differ, so the
              // tests on this store passed over the database's own bug.
              preview: m.preview.isEmpty ? existing.preview : m.preview,
              bodyText: existing.bodyText,
              bodyHtml: existing.bodyHtml,
            );
    }
  }

  @override
  Future<void> updateFlags(
    String accountId,
    String path,
    Map<int, CachedFlags> flagsByUid,
  ) async {
    final folder = _folder(accountId, path);
    for (final e in flagsByUid.entries) {
      final m = folder[e.key];
      if (m != null) {
        folder[e.key] = m.copyWith(
          isRead: e.value.isRead,
          isFlagged: e.value.isFlagged,
          isAnswered: e.value.isAnswered,
          isForwarded: e.value.isForwarded,
        );
      }
    }
  }

  @override
  Future<void> deleteUids(String accountId, String path, Set<int> uids) async {
    _folder(accountId, path).removeWhere((uid, _) => uids.contains(uid));
  }

  @override
  Future<void> writeBody(
    String accountId,
    String path,
    int uid, {
    required String text,
    String? html,
    String? calendar,
    required String preview,
  }) async {
    final folder = _folder(accountId, path);
    final m = folder[uid];
    if (m != null) {
      folder[uid] = m.copyWith(
        bodyText: text,
        bodyHtml: html,
        calendar: calendar,
        preview: preview,
      );
    }
  }

  @override
  Future<void> renameFolder(
    String accountId,
    String oldPath,
    String newPath,
  ) async {
    if (oldPath == newPath) return;
    final prefix = _k(accountId, '$oldPath/');
    final exact = _k(accountId, oldPath);
    final target = _k(accountId, newPath);
    bool stale(String k) =>
        (k == target || k.startsWith('$target/')) &&
        !(k == exact || k.startsWith(prefix));
    _messages.removeWhere((k, _) => stale(k));
    _states.removeWhere((k, _) => stale(k));
    final moves = <String, String>{};
    for (final key in [..._messages.keys, ..._states.keys]) {
      if (key == exact) {
        moves[key] = _k(accountId, newPath);
      } else if (key.startsWith(prefix)) {
        moves[key] = _k(accountId, newPath) + key.substring(exact.length);
      }
    }
    for (final e in moves.entries) {
      final msgs = _messages.remove(e.key);
      if (msgs != null) _messages[e.value] = msgs;
      final st = _states.remove(e.key);
      if (st != null) _states[e.value] = st;
    }
  }

  @override
  Future<void> deleteFolder(String accountId, String path) async {
    final prefix = _k(accountId, '$path/');
    final exact = _k(accountId, path);
    _messages.removeWhere((k, _) => k == exact || k.startsWith(prefix));
    _states.removeWhere((k, _) => k == exact || k.startsWith(prefix));
  }

  @override
  Future<void> pruneFolders(String accountId, Set<String> paths) async {
    final prefix = '$accountId$_separator';
    bool gone(String k) =>
        k.startsWith(prefix) && !paths.contains(k.substring(prefix.length));
    _messages.removeWhere((k, _) => gone(k));
    _states.removeWhere((k, _) => gone(k));
  }

  @override
  Future<void> deleteAccount(String accountId) async {
    final prefix = '$accountId$_separator';
    _messages.removeWhere((k, _) => k.startsWith(prefix));
    _states.removeWhere((k, _) => k.startsWith(prefix));
  }
}
