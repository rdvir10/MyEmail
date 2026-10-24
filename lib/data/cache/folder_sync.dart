import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/mail_message.dart';
import '../imap/imap_mapping.dart';
import '../imap/imap_transport.dart';
import 'cache_store.dart';

/// Brings the cached copy of one folder up to date with the server.
///
/// The rules, in the order they run:
///
///  1. SELECT and compare UIDVALIDITY with what we stored. A change means
///     every cached UID is meaningless: wipe the folder and start over.
///     Skipping this is how clients end up showing the wrong message for a
///     click after a server-side rebuild.
///  2. First fill (nothing cached): the newest [windowSize] messages by
///     sequence number, so a 9,000-message folder is not downloaded whole.
///  3. Otherwise, new mail: `UID FETCH <max+1>:*`, filtered to what is not
///     cached, because IMAP returns the highest existing UID even when
///     nothing is newer.
///  4. Flags for the cached window: with CONDSTORE only those changed since
///     our HIGHESTMODSEQ; without it, all of them.
///  5. Deletions: `UID SEARCH` the cached range and drop what is gone; on
///     Graph, from the newest rows only, the ones a list is showing.
///  6. The names of the files on rows that have some and do not know them
///     yet: new Microsoft mail, and rows cached before names were kept.
///  7. Record the new state.
///
/// [ensureCached] extends the window downward on demand as the user pages.
class FolderSync {
  FolderSync({
    required this.transport,
    required this.store,
    required this.accountId,
    this.windowSize = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ImapTransport transport;
  final CacheStore store;
  final String accountId;

  /// How many of the newest messages the first sync of a folder fetches,
  /// and how many every sync keeps up to date at the least.
  final int windowSize;

  /// The most rows one pass asks the files' names of: see
  /// [_nameAttachments]. Rows cached before names were kept fill in over a
  /// few syncs, not all in the first, which on a Microsoft account is a
  /// request for every twenty.
  static const attachmentNamesPerPass = 60;

  /// The most rows one pass asks the importance of: one request over IMAP
  /// whatever the number, so a whole window at once.
  static const importancePerPass = 200;

  final DateTime Function() _clock;

  /// [reach] is how many of the folder's newest messages the caller is
  /// about to show. Their flags and deletions are brought up to date, or
  /// the newest [windowSize] if that is more; rows below them wait until a
  /// list reaches them, and the sync made for that list sees to them.
  Future<SyncResult> sync(String path, {int reach = 0}) async {
    final status = await transport.selectFolder(path);
    final previous = await store.readFolderState(accountId, path);

    if (previous == null || previous.uidValidity != status.uidValidity) {
      final wiped = previous != null;
      await store.clearFolder(accountId, path);
      final added = await _fillNewest(path, status);
      await _writeState(path, status);
      return SyncResult(
        added: added,
        cacheReset: wiped,
        serverExists: status.exists,
      );
    }

    final range = await store.uidRange(accountId, path);
    if (range == null) {
      // State existed but nothing cached (e.g. folder was empty last time).
      final added = await _fillNewest(path, status);
      await _writeState(path, status);
      return SyncResult(added: added, serverExists: status.exists);
    }

    // What is cached now, before anything is added, newest first, and how
    // far back it reaches, which a transport whose numbers do not follow
    // dates needs to know. See ImapTransport.fetchHeadersFromUid.
    final cached = await store.readSyncRows(accountId, path);
    final windowStart = _oldest(cached);

    // The rows kept up to date: as many as the caller is showing, and at
    // least the newest [windowSize]. Not the whole cache, which nothing
    // ever trims. On Graph each scan below pages back a hundred messages a
    // request to the oldest row it is asked about, so a folder scrolled
    // back two months cost some fifty requests a sync, every minute in
    // push mode, against nine for the newest two hundred.
    final recent = cached.take(max(windowSize, reach)).toList();
    final recentStart = _oldest(recent);

    // New mail. It is the newest there is, so on Graph a scan back as far
    // as the rows kept up to date finds it: all but mail moved in, which
    // keeps its old date. Moved in from elsewhere, it waits for a list to
    // reach its date and is numbered then. But a move made here, an undo
    // or a search numbers what it finds at once, and a number left without
    // a row was never picked up: newer mail is numbered above it, and only
    // numbers above the highest cached were asked for. So while a number
    // handed out since the last sync has no row, the scan goes back across
    // the whole cache, from the lowest such number. IMAP numbers by arrival
    // in the folder and pays nothing for any of this.
    final cachedUids = {for (final m in cached) m.uid};
    final since = previous.uidNext;
    final upTo = status.uidNext;
    var unclaimed = since ?? range.max + 1;
    while (upTo != null && unclaimed < upTo && cachedUids.contains(unclaimed)) {
      unclaimed++;
    }
    final lookBack = since == null || upTo == null || unclaimed < upTo;
    final fresh = await transport.fetchHeadersFromUid(
      path,
      min(range.max + 1, unclaimed),
      windowStart: lookBack ? windowStart : recentStart,
    );
    final newHeaders = [
      for (final h in fresh)
        if (!cachedUids.contains(h.uid)) h,
    ];
    await store.upsertMessages(accountId, path, newHeaders.map(_cached).toList());

    // Flag changes: read, flagged, and a reply or forward sent from
    // somewhere else. Across the cached range, which over IMAP is one
    // request whatever its size; Graph pages back by date, and only as far
    // as the rows kept up to date.
    // Changes only, where the server can say what changed, unless a row
    // has no size yet: cached before sizes were fetched, it needs the whole
    // window read once, and the size comes with the flags.
    final useCondStore = previous.highestModSeq != null &&
        status.highestModSeq != null &&
        cached.every((m) => m.hasSize);
    final flags = await transport.fetchFlags(
      path,
      range.min,
      range.max,
      changedSinceModSeq: useCondStore ? previous.highestModSeq : null,
      windowStart: recentStart,
    );
    await store.updateFlags(accountId, path, {
      for (final f in flags)
        f.uid: (
          isRead: f.isRead,
          isFlagged: f.isFlagged,
          isAnswered: f.isAnswered,
          isForwarded: f.isForwarded,
        ),
    });
    await store.updateSizes(accountId, path, {
      for (final f in flags)
        if (f.sizeBytes case final size? when size > 0) f.uid: size,
    });
    // The importance, where it comes with the flags (Graph).
    final rated = {
      for (final f in flags)
        f.uid: ?f.importance,
    };
    await store.updateImportance(accountId, path, rated);

    // Deletions. On Graph, among the rows kept up to date only: the scan
    // went no further than a page past the oldest of them, and an older row
    // it did not happen to see is not gone for that. IMAP's one search
    // covers the whole cache, and leaving its older rows out kept mail
    // deleted elsewhere in the cache until a list scrolled down to it.
    final existing = await transport.existingUids(
      path,
      range.min,
      range.max,
      windowStart: recentStart,
    );
    // Only rows inside the range the server was asked about. A page of older
    // mail loaded while this ran lands below it (IMAP numbers them lower),
    // and counting those as gone deleted what had just been scrolled in.
    // And none when the server could not say: see existingUids.
    final gone = {
      if (existing != null)
        for (final m in transport.readsBackByDate ? recent : cached)
          if (m.uid >= range.min &&
              m.uid <= range.max &&
              !existing.contains(m.uid))
            m.uid,
    };
    await store.deleteUids(accountId, path, gone);

    // File names: the new mail's that came without them, then the rows kept
    // up to date that have never had theirs.
    await _nameAttachments(path, [
      ...unnamed(newHeaders),
      for (final m in recent)
        if (m.needsAttachmentNames && !gone.contains(m.uid)) m.uid,
    ]);
    // The importance, the same way, less what the flags just brought.
    await _rateImportance(path, [
      ...unrated(newHeaders),
      for (final m in recent)
        if (m.needsImportance &&
            !gone.contains(m.uid) &&
            !rated.containsKey(m.uid))
          m.uid,
    ]);

    // Rows that have no preview line.
    //
    // Three reasons a row has none. It was cached by a version that dropped
    // the server's preview on the floor, which is most of a work mailbox
    // and is what this is for. Or the server has no preview to give, which
    // is every IMAP server, and there [canRefreshHeaders] is false so this
    // never runs and never costs a round trip that could not help. Or the
    // message has no text at all, a meeting reply say, and asking again
    // would get nothing again: once a folder's rows have all been asked
    // about, they are not asked about again. A pass over the whole folder
    // every sync, forever, for one empty message.
    //
    // A row without the server's conversation is read again the same way:
    // it was cached before that was kept (schema 10 cleared every folder's
    // mark so this runs once more), and the same read brings it.
    if (transport.canRefreshHeaders &&
        !previous.previewsChecked &&
        cached.any((m) =>
            (!m.hasPreview || !m.hasConversation) && !gone.contains(m.uid))) {
      final refreshed = await transport.refreshHeaders(
        path,
        range.min,
        range.max,
        windowStart: windowStart,
      );
      await store.upsertMessages(
        accountId,
        path,
        [
          for (final h in refreshed)
            if (h.preview.isNotEmpty) _cached(h),
        ],
      );
    }

    await _writeState(path, status);
    // What the sync was asked about and what it found, for the log: a
    // folder that stops showing new mail is either not looking far enough
    // or not hearing back, and this tells the two apart.
    debugPrint('[myemail] sync $path: ${cached.length} cached, newest '
        '${cached.isEmpty ? '-' : cached.first.date.toIso8601String()}, '
        'kept ${recent.length} back to ${recentStart?.toIso8601String()}, '
        'new from ${min(range.max + 1, unclaimed)} of ${status.uidNext}'
        '${lookBack ? ' looking back' : ''}, server ${status.exists}: '
        '+${newHeaders.length} ~${flags.length} -${gone.length}'
        '${existing == null ? ' (deletions unknown)' : ''}');
    return SyncResult(
      added: newHeaders.length,
      updated: flags.length,
      removed: gone.length,
      serverExists: status.exists,
      arrived: [for (final h in newHeaders) h.uid],
    );
  }

  /// Make sure at least [count] messages are cached, fetching older ones by
  /// sequence number if the server has more. Returns how many are cached.
  ///
  /// Leaves the folder's state alone: a page read now brings the server's
  /// previews with it, so it changes nothing [FolderSyncState] records.
  Future<int> ensureCached(String path, int count) async {
    var have = await store.countMessages(accountId, path);
    if (have >= count) return have;

    final status = await transport.selectFolder(path);
    if (status.exists <= have) return have;

    // Older messages sit below the cached window. Sequence numbers count
    // from the oldest, so the window's bottom is at exists - have.
    final end = status.exists - have;
    final start = max(1, end - (count - have) + 1);
    if (end < 1) return have;
    final headers = await transport.fetchHeadersBySequence(path, start, end);
    // Everything not already cached. This used to keep only numbers below
    // the window, which is how IMAP UIDs run and not how Graph's do: Graph
    // numbers a message the first time it is seen, so older mail paged in
    // after the newest is numbered above it, every header was dropped, and
    // a Microsoft folder never showed more than its first two hundred.
    final cachedUids = {
      for (final m in await store.readSyncRows(accountId, path)) m.uid,
    };
    final added = [
      for (final h in headers)
        if (!cachedUids.contains(h.uid)) h,
    ];
    await store.upsertMessages(accountId, path, added.map(_cached).toList());
    await _nameAttachments(path, unnamed(added.reversed));
    await _rateImportance(path, unrated(added.reversed));
    have = await store.countMessages(accountId, path);
    return have;
  }

  /// The body, from the cache if we have it, else fetched and cached along
  /// with a preview for the list.
  ///
  /// Not cached when its invitation is still to come: kept, it would be
  /// the message without its card for good.
  Future<MailBody> body(String path, int uid) async {
    final cached = await cachedBody(store, accountId, path, uid);
    if (cached != null) return cached;
    final fetched = await transport.fetchBody(path, uid);
    if (fetched.calendarPending) return fetched;
    await store.writeBody(
      accountId,
      path,
      uid,
      text: fetched.text,
      html: fetched.html,
      calendar: fetched.calendar,
      preview: previewFromText(fetched.text),
    );
    return fetched;
  }

  Future<int> _fillNewest(String path, FolderStatus status) async {
    if (status.exists == 0) return 0;
    final start = max(1, status.exists - windowSize + 1);
    final headers =
        await transport.fetchHeadersBySequence(path, start, status.exists);
    await store.upsertMessages(accountId, path, headers.map(_cached).toList());
    // Newest first, as the list shows them, for the pass's limit to fall
    // on the oldest.
    await _nameAttachments(path, unnamed(headers.reversed));
    await _rateImportance(path, unrated(headers.reversed));
    return headers.length;
  }

  /// The headers among [headers] that did not say how important they are.
  static List<int> unrated(Iterable<RemoteHeader> headers) => [
        for (final h in headers)
          if (h.importance == null) h.uid,
      ];

  /// Ask the server how important the first [importancePerPass] of [uids]
  /// are, and keep it. Never fails the sync, as [_nameAttachments] does not.
  Future<void> _rateImportance(String path, List<int> uids) async {
    final wanted = uids.toSet().take(importancePerPass).toList();
    if (wanted.isEmpty) return;
    try {
      final rated = await transport.importanceOf(path, wanted);
      await store.updateImportance(accountId, path, rated);
    } catch (e) {
      debugPrint('[myemail] importance for $path not read: $e');
    }
  }

  /// The headers among [headers] that have files and did not name them.
  static List<int> unnamed(Iterable<RemoteHeader> headers) => [
        for (final h in headers)
          if (h.hasAttachments && h.attachmentNames == null) h.uid,
      ];

  /// Ask the server for the files' names on the first
  /// [attachmentNamesPerPass] of [uids], in the order given, and keep them.
  ///
  /// Never fails the sync. The names are for the row, which shows the
  /// paperclip without them, and a row that did not get them is asked
  /// about again by the next pass that keeps it up to date.
  Future<void> _nameAttachments(String path, List<int> uids) async {
    final wanted = uids.toSet().take(attachmentNamesPerPass).toList();
    if (wanted.isEmpty) return;
    try {
      final names = await transport.attachmentNames(path, wanted);
      await store.updateAttachmentNames(accountId, path, names);
    } catch (e) {
      debugPrint('[myemail] file names for $path not read: $e');
    }
  }

  /// Every sync that gets this far has seen to the previews, where the
  /// server has them to give: rows it fetched came with the server's, and
  /// rows that lacked one were asked.
  Future<void> _writeState(String path, FolderStatus status) =>
      store.writeFolderState(
        accountId,
        path,
        FolderSyncState(
          uidValidity: status.uidValidity,
          uidNext: status.uidNext,
          highestModSeq: status.highestModSeq,
          lastSync: _clock(),
          previewsChecked: transport.canRefreshHeaders,
        ),
      );

  static DateTime? _oldest(List<SyncRow> rows) => rows.isEmpty
      ? null
      : rows.map((m) => m.date).reduce((a, b) => a.isBefore(b) ? a : b);

  static CachedMessage _cached(RemoteHeader h) => CachedMessage(
        uid: h.uid,
        subject: h.subject,
        from: h.from,
        to: h.to,
        date: h.date,
        arrived: h.arrived,
        isRead: h.isRead,
        isFlagged: h.isFlagged,
        isAnswered: h.isAnswered,
        isForwarded: h.isForwarded,
        hasAttachments: h.hasAttachments,
        attachmentNames: h.attachmentNames,
        importance: h.importance,
        cc: h.cc,
        replyTo: h.replyTo,
        sizeBytes: h.sizeBytes,
        isMeeting: h.isMeeting,
        preview: h.preview,
        messageId: h.messageId,
        inReplyTo: h.inReplyTo,
        conversationId: h.conversationId,
      );
}

/// The body cached for a message, or null where none is.
///
/// A Microsoft HTML message opened before the text was made from its HTML
/// (see `GraphTransport.fetchBody`) was cached with no text at all: its row
/// lost the second line Graph had sent with it, and a meeting made from it
/// had nothing for notes. A cached body is never fetched again, so the
/// text is made from the HTML here, the first time the message is opened
/// since, and kept, with the list's preview made from it.
Future<MailBody?> cachedBody(
  CacheStore store,
  String accountId,
  String path,
  int uid,
) async {
  final cached = await store.readBody(accountId, path, uid);
  if (cached == null) return null;
  final html = cached.html;
  if (cached.text.isEmpty && html != null && html.isNotEmpty) {
    final remade = htmlToText(html);
    if (remade.isNotEmpty) {
      try {
        await store.writeBody(
          accountId,
          path,
          uid,
          text: remade,
          html: html,
          calendar: cached.calendar,
          preview: previewFromText(remade),
        );
      } catch (_) {
        // Kept or not, the message reads the same; the next open tries
        // again.
      }
      return MailBody(text: remade, html: html, calendar: cached.calendar);
    }
  }
  return cached;
}

class SyncResult {
  const SyncResult({
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.cacheReset = false,
    required this.serverExists,
    this.arrived = const [],
  });

  final int added;

  /// The UIDs of mail new since the last sync, as it arrived: not a first
  /// fill or a refill, which is the folder as it already was.
  final List<int> arrived;
  final int updated;
  final int removed;

  /// UIDVALIDITY changed and the folder was refilled from scratch.
  final bool cacheReset;
  final int serverExists;

  @override
  String toString() =>
      'SyncResult(+$added ~$updated -$removed reset=$cacheReset exists=$serverExists)';
}
