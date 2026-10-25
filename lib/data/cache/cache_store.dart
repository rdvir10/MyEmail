import 'package:flutter/foundation.dart';

import '../../domain/address_suggestions.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_reads.dart';
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

  /// The next number the folder would hand out when the last sync began:
  /// everything numbered since is at or above it, which is how the sync
  /// knows to look back for mail numbered without being cached.
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
/// What the sync needs of a cached row: its number and date, and whether
/// the row has what a header read again would bring, a preview and the
/// server's conversation.
///
/// [needsAttachmentNames]: it has files and their names are not known yet.
/// [needsImportance]: its importance is not known yet.
typedef SyncRow = ({
  int uid,
  DateTime date,
  bool hasPreview,
  bool hasConversation,
  bool hasSize,
  bool needsAttachmentNames,
  bool needsImportance,
});

/// A cached row's flags, all of them, as [CacheStore.updateFlags] writes
/// them.
typedef CachedFlags = ({
  bool isRead,
  bool isFlagged,
  bool isAnswered,
  bool isForwarded,
});

/// A message as cached: the list row plus, once fetched, the body.
///
/// The body is written with a row, but a row read back comes without it:
/// only [CacheStore.readBody] reads one.
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
    this.attachmentNames,
    this.importance,
    this.isAnswered = false,
    this.isForwarded = false,
    this.arrived,
    this.cc = const [],
    this.replyTo = const [],
    this.sizeBytes = 0,
    this.isMeeting = false,
    this.preview = '',
    this.bodyText,
    this.bodyHtml,
    this.calendar,
    this.messageId,
    this.inReplyTo,
    this.conversationId,
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

  /// See [MailMessage.attachmentNames]. Null where they are not known yet:
  /// a Microsoft row with files, until they are asked for, and every row
  /// cached before schema 13.
  final List<String>? attachmentNames;

  /// See [MailMessage.importance]. Null where it is not known yet: an IMAP
  /// row until it is asked for, and every row cached before schema 14.
  final Importance? importance;

  /// See [MailMessage.sizeBytes].
  final int sizeBytes;

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

  /// See [MailMessage.conversationId]. Null on rows cached before schema
  /// 10, until the folder's next sync reads their headers again.
  final String? conversationId;

  /// The row as a read gives it back: everything but the body.
  CachedMessage withoutBody() => CachedMessage(
        uid: uid,
        subject: subject,
        from: from,
        to: to,
        cc: cc,
        replyTo: replyTo,
        date: date,
        arrived: arrived,
        isRead: isRead,
        isFlagged: isFlagged,
        isAnswered: isAnswered,
        isForwarded: isForwarded,
        hasAttachments: hasAttachments,
        attachmentNames: attachmentNames,
        importance: importance,
        sizeBytes: sizeBytes,
        isMeeting: isMeeting,
        preview: preview,
        messageId: messageId,
        inReplyTo: inReplyTo,
        conversationId: conversationId,
      );

  CachedMessage copyWith({
    bool? isRead,
    bool? isFlagged,
    bool? isAnswered,
    bool? isForwarded,
    int? sizeBytes,
    List<String>? attachmentNames,
    Importance? importance,
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
      attachmentNames: attachmentNames ?? this.attachmentNames,
      importance: importance ?? this.importance,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      isMeeting: isMeeting,
      preview: preview ?? this.preview,
      bodyText: bodyText ?? this.bodyText,
      bodyHtml: bodyHtml ?? this.bodyHtml,
      calendar: calendar ?? this.calendar,
      messageId: messageId,
      inReplyTo: inReplyTo,
      conversationId: conversationId,
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
      attachmentNames: attachmentNames ?? const [],
      importance: importance ?? Importance.normal,
      sizeBytes: sizeBytes,
      isMeeting: isMeeting,
      messageId: messageId,
      inReplyTo: inReplyTo,
      conversationId: conversationId,
    );
  }
}

/// Where cached messages and sync state live. Keyed by account and folder
/// path; the Drift implementation is the real one, the memory one is for
/// tests and the browser preview.
/// A message snoozed: by its own Message-ID, which finds it again in
/// [snoozedPath], where it waits until [until], to go back to [fromPath].
typedef SnoozedEntry = ({
  String accountId,
  String messageId,
  String fromPath,
  String snoozedPath,
  DateTime until,
});

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

  /// Newest first by when the server took each message in
  /// ([CachedMessage.arrived] where it is known, else its date), and by
  /// UID among those that arrived together. Not by UID alone: numbers do
  /// not follow dates for older mail paged in on Graph, or for mail moved
  /// into an IMAP folder.
  ///
  /// The rows come without their bodies, which a list has no use for and
  /// which are most of what is stored: see [readBody].
  Future<List<CachedMessage>> readMessages(
    String accountId,
    String path, {
    int offset = 0,
    int limit = 50,
  });

  /// Every snoozed message, as [addSnoozed] wrote it.
  Future<List<SnoozedEntry>> readSnoozed();

  /// Snoozed, or snoozed again to a new time.
  Future<void> addSnoozed(List<SnoozedEntry> entries);

  /// Back, or gone: no longer waited for.
  Future<void> removeSnoozed(String accountId, String messageId);

  /// What [accountId]'s calendar [calendarId] held from [start] to [end]
  /// when it was read at [readAt]: every event kept before for that
  /// stretch goes, and [events] are kept in its place. Not kept where a
  /// read of the same stretch kept since is newer, an answer that came
  /// back after one asked for later. Events and reads that ended longer
  /// ago than [keptCalendarBack] are let go at the same time.
  Future<void> keepCalendar(
    String accountId,
    DateTime start,
    DateTime end,
    List<CalendarEvent> events, {
    required DateTime readAt,
    String calendarId = CalendarEvent.mainCalendar,
  });

  /// The events kept for [accountId] that fall between [start] and [end],
  /// earliest first, on [calendarIds], and when that stretch of all of them
  /// was read (see [readAtOver]). Nothing kept is no events and no time.
  Future<KeptCalendar> keptCalendar(
    String accountId,
    DateTime start,
    DateTime end, {
    Set<String> calendarIds = const {CalendarEvent.mainCalendar},
  });

  /// The newest [limit] flagged messages in all of [accountId]'s folders,
  /// each with the folder it is in, as [readMessages] reads them.
  Future<List<({String path, CachedMessage message})>> readFlagged(
    String accountId, {
    int limit = 100,
  });

  /// Every cached row of the folder, as little of each as the sync needs,
  /// in the order [readMessages] reads them: the sync keeps the newest up
  /// to date, and they have to be the ones a list shows first.
  Future<List<SyncRow>> readSyncRows(String accountId, String path);

  Future<int> countMessages(String accountId, String path);

  /// Everyone on any cached message, as sender, recipient or copied, each
  /// address once: see [historyFrom], which says what is counted and how.
  ///
  /// [mine] is the accounts' own addresses, lower-cased: a message from one
  /// of them is one written from here, and its recipients are people
  /// written to. [now] is what each message's age is reckoned from.
  ///
  /// The whole cache, not its newest messages: someone last written to in
  /// the spring is still someone to suggest. The drift store counts in SQL,
  /// so what crosses to Dart is one row per person, not one per message.
  Future<List<AddressSuggestion>> addressHistory({
    required Set<String> mine,
    required DateTime now,
  });
  Future<({int min, int max})?> uidRange(String accountId, String path);

  /// One row, without its body, as [readMessages] gives them: for its flags
  /// and headers.
  Future<CachedMessage?> readMessage(String accountId, String path, int uid);

  /// Those of [uids] that are cached, in one read: what a list row is made
  /// of, for turning search hits into rows. Each hit read on its own was a
  /// round trip per hit. The database leaves the body out, since a whole
  /// row is mostly its body, so these are not for writing back.
  Future<List<CachedMessage>> readHeaders(
    String accountId,
    String path,
    List<int> uids,
  );

  /// The body cached for one message, or null where none has been fetched:
  /// the one read that takes it.
  Future<MailBody?> readBody(String accountId, String path, int uid);

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

  /// Each row's whole-message size, as the server now gives it with the
  /// flags: see [MailMessage.sizeBytes]. Callers pass only known, positive
  /// sizes.
  Future<void> updateSizes(
    String accountId,
    String path,
    Map<int, int> bytesByUid,
  );

  /// Each row's importance, as the server gave it: see
  /// [CachedMessage.importance].
  Future<void> updateImportance(
    String accountId,
    String path,
    Map<int, Importance> importanceByUid,
  );

  /// Each row's file names, as [ImapTransport.attachmentNames] found them:
  /// see [CachedMessage.attachmentNames].
  Future<void> updateAttachmentNames(
    String accountId,
    String path,
    Map<int, List<String>> namesByUid,
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

  /// The order the database reads a folder in: see [CacheStore.readMessages].
  static int _newestArrivalFirst(CachedMessage a, CachedMessage b) {
    final byArrival = (b.arrived ?? b.date).compareTo(a.arrived ?? a.date);
    if (byArrival != 0) return byArrival;
    return b.uid.compareTo(a.uid);
  }

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
      ..sort(_newestArrivalFirst);
    if (offset >= all.length) return const [];
    // Without their bodies, as the database reads them, so that nothing
    // tested against this store can come to rely on a body being there.
    return [
      for (final m in all.sublist(offset, (offset + limit).clamp(0, all.length)))
        m.withoutBody(),
    ];
  }

  final Map<String, SnoozedEntry> _snoozed = {};

  @override
  Future<List<SnoozedEntry>> readSnoozed() async => [..._snoozed.values];

  @override
  Future<void> addSnoozed(List<SnoozedEntry> entries) async {
    for (final e in entries) {
      _snoozed[_k(e.accountId, e.messageId)] = e;
    }
  }

  @override
  Future<void> removeSnoozed(String accountId, String messageId) async =>
      _snoozed.remove(_k(accountId, messageId));

  final MemoryCalendarKeep _calendars = MemoryCalendarKeep();

  @override
  Future<void> keepCalendar(
    String accountId,
    DateTime start,
    DateTime end,
    List<CalendarEvent> events, {
    required DateTime readAt,
    String calendarId = CalendarEvent.mainCalendar,
  }) async =>
      _calendars.keep(accountId, start, end, events,
          readAt: readAt, calendarId: calendarId);

  @override
  Future<KeptCalendar> keptCalendar(
    String accountId,
    DateTime start,
    DateTime end, {
    Set<String> calendarIds = const {CalendarEvent.mainCalendar},
  }) async =>
      _calendars.kept(accountId, start, end, calendarIds: calendarIds);

  @override
  Future<List<({String path, CachedMessage message})>> readFlagged(
    String accountId, {
    int limit = 100,
  }) async {
    final own = '$accountId$_separator';
    final found = [
      for (final MapEntry(:key, :value) in _messages.entries)
        if (key.startsWith(own))
          for (final m in value.values)
            if (m.isFlagged)
              (path: key.substring(own.length), message: m.withoutBody()),
    ]..sort((a, b) => _newestArrivalFirst(a.message, b.message));
    return found.take(limit).toList();
  }

  @override
  Future<List<SyncRow>> readSyncRows(String accountId, String path) async => [
        for (final m in _folder(accountId, path).values.toList()
          ..sort(_newestArrivalFirst))
          (
            uid: m.uid,
            date: m.date,
            hasPreview: m.preview.isNotEmpty,
            hasConversation: m.conversationId != null,
            hasSize: m.sizeBytes > 0,
            needsAttachmentNames:
                m.hasAttachments && m.attachmentNames == null,
            needsImportance: m.importance == null,
          ),
      ];

  @override
  Future<List<AddressSuggestion>> addressHistory({
    required Set<String> mine,
    required DateTime now,
  }) async {
    // Each message once, as the database has it: by Message-ID where there
    // is one, the newest copy.
    final messages = <String, CachedMessage>{};
    for (final folder in _messages.entries) {
      for (final m in folder.value.values) {
        final key = m.messageId ?? '${folder.key}#${m.uid}';
        final kept = messages[key];
        if (kept == null || m.date.isAfter(kept.date)) messages[key] = m;
      }
    }
    return historyFrom(
      [
        for (final m in messages.values)
          for (final (i, a) in [m.from, ...m.to, ...m.cc].indexed)
            (
              address: a,
              date: m.date,
              // The sender is not someone written to, even by themselves.
              sent: i > 0 && mine.contains(m.from.email.trim().toLowerCase()),
            ),
      ],
      now: now,
    );
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
      _folder(accountId, path)[uid]?.withoutBody();

  @override
  Future<MailBody?> readBody(String accountId, String path, int uid) async {
    final m = _folder(accountId, path)[uid];
    final text = m?.bodyText;
    if (m == null || text == null) return null;
    return MailBody(text: text, html: m.bodyHtml, calendar: m.calendar);
  }

  /// Without their bodies, as the database reads them, so that nothing
  /// tested against this store can come to rely on a body being there.
  @override
  Future<List<CachedMessage>> readHeaders(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    final folder = _folder(accountId, path);
    return [for (final uid in uids) ?folder[uid]?.withoutBody()];
  }

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
              // And a size the new row does not know leaves the old one.
              sizeBytes: m.sizeBytes > 0 ? m.sizeBytes : existing.sizeBytes,
              // So do file names: a Microsoft header read again has none.
              attachmentNames: m.attachmentNames ?? existing.attachmentNames,
              // And the importance, which an IMAP header never has.
              importance: m.importance ?? existing.importance,
              bodyText: existing.bodyText,
              bodyHtml: existing.bodyHtml,
              calendar: existing.calendar,
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
  Future<void> updateSizes(
    String accountId,
    String path,
    Map<int, int> bytesByUid,
  ) async {
    final folder = _folder(accountId, path);
    for (final e in bytesByUid.entries) {
      final m = folder[e.key];
      if (m != null) folder[e.key] = m.copyWith(sizeBytes: e.value);
    }
  }

  @override
  Future<void> updateImportance(
    String accountId,
    String path,
    Map<int, Importance> importanceByUid,
  ) async {
    final folder = _folder(accountId, path);
    for (final e in importanceByUid.entries) {
      final m = folder[e.key];
      if (m != null) folder[e.key] = m.copyWith(importance: e.value);
    }
  }

  @override
  Future<void> updateAttachmentNames(
    String accountId,
    String path,
    Map<int, List<String>> namesByUid,
  ) async {
    final folder = _folder(accountId, path);
    for (final e in namesByUid.entries) {
      final m = folder[e.key];
      if (m != null) folder[e.key] = m.copyWith(attachmentNames: e.value);
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
    _calendars.forget(accountId);
  }
}

/// [CacheStore.keepCalendar] and [CacheStore.keptCalendar] in memory, for
/// [MemoryCacheStore] and the sample engine.
class MemoryCalendarKeep {
  final Map<String, List<CalendarRead>> _reads = {};
  final Map<String, Map<(String, String), CalendarEvent>> _events = {};

  void keep(
    String accountId,
    DateTime start,
    DateTime end,
    List<CalendarEvent> events, {
    required DateTime readAt,
    String calendarId = CalendarEvent.mainCalendar,
  }) {
    final read = CalendarRead(
      calendarId: calendarId,
      start: start,
      end: end,
      readAt: readAt,
    );
    final reads = _reads[accountId] ?? const [];
    if (readIsStale(reads, read)) return;
    final kept = _events.putIfAbsent(accountId, () => {});
    kept.removeWhere(
        (k, e) => e.calendarId == calendarId && eventIsIn(e, start, end));
    for (final e in events) {
      kept[(e.calendarId, e.id)] = e;
    }
    final before = readAt.subtract(keptCalendarBack);
    kept.removeWhere((_, e) => e.end.isBefore(before));
    _reads[accountId] = [
      for (final r in withRead(reads, read))
        if (!r.end.isBefore(before)) r,
    ];
  }

  KeptCalendar kept(
    String accountId,
    DateTime start,
    DateTime end, {
    Set<String> calendarIds = const {CalendarEvent.mainCalendar},
  }) {
    final events = [
      for (final e in (_events[accountId] ?? const {}).values)
        if (calendarIds.contains(e.calendarId) && eventIsIn(e, start, end)) e,
    ]..sort(byStart);
    final reads = _reads[accountId] ?? const [];
    return (events: events, readAt: readAtOverAll(reads, start, end, calendarIds));
  }

  void forget(String accountId) {
    _reads.remove(accountId);
    _events.remove(accountId);
  }
}

/// Earliest first, and the shorter first of two that start together.
int byStart(CalendarEvent a, CalendarEvent b) {
  final byStart = a.start.compareTo(b.start);
  return byStart != 0 ? byStart : a.end.compareTo(b.end);
}

/// [readAtOver] for several calendars at once: the oldest of their times,
/// or null where any of them has a part never read.
DateTime? readAtOverAll(
  List<CalendarRead> reads,
  DateTime start,
  DateTime end,
  Set<String> calendarIds,
) {
  DateTime? oldest;
  for (final id in calendarIds) {
    final at = readAtOver(reads, start, end, calendarId: id);
    if (at == null) return null;
    if (oldest == null || at.isBefore(oldest)) oldest = at;
  }
  return oldest;
}
