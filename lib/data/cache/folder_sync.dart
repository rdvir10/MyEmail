import 'dart:math';

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
///  3. Otherwise, new mail: `UID FETCH <max+1>:*`, filtered because IMAP
///     returns the highest existing UID even when nothing is newer.
///  4. Flags for the cached window: with CONDSTORE only those changed since
///     our HIGHESTMODSEQ; without it, all of them.
///  5. Deletions: `UID SEARCH` the cached range and drop what is gone.
///  6. Record the new state.
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

  /// How many of the newest messages the first sync of a folder fetches.
  final int windowSize;

  final DateTime Function() _clock;

  Future<SyncResult> sync(String path) async {
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

    // What is cached now, before anything is added: the rows the deletion
    // check runs over, and how far back the window reaches, which a
    // transport whose numbers do not follow dates needs to know. See
    // ImapTransport.fetchHeadersFromUid.
    final cached = await store.readSyncRows(accountId, path);
    final windowStart = cached.isEmpty
        ? null
        : cached
            .map((m) => m.date)
            .reduce((a, b) => a.isBefore(b) ? a : b);

    // New mail.
    final fresh = await transport.fetchHeadersFromUid(
      path,
      range.max + 1,
      windowStart: windowStart,
    );
    final newHeaders = [
      for (final h in fresh)
        if (h.uid > range.max) h,
    ];
    await store.upsertMessages(accountId, path, newHeaders.map(_cached).toList());

    // Flag changes across the cached window: read, flagged, and a reply or
    // forward sent from somewhere else.
    final useCondStore =
        previous.highestModSeq != null && status.highestModSeq != null;
    final flags = await transport.fetchFlags(
      path,
      range.min,
      range.max,
      changedSinceModSeq: useCondStore ? previous.highestModSeq : null,
      windowStart: windowStart,
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

    // Deletions.
    final existing = await transport.existingUids(
      path,
      range.min,
      range.max,
      windowStart: windowStart,
    );
    // Only rows inside the range the server was asked about. A page of older
    // mail loaded while this ran lands below it (IMAP numbers them lower),
    // and counting those as gone deleted what had just been scrolled in.
    final gone = {
      for (final m in cached)
        if (m.uid >= range.min &&
            m.uid <= range.max &&
            !existing.contains(m.uid))
          m.uid,
    };
    await store.deleteUids(accountId, path, gone);

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
    if (transport.canRefreshHeaders &&
        !previous.previewsChecked &&
        cached.any((m) => !m.hasPreview && !gone.contains(m.uid))) {
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
    return SyncResult(
      added: newHeaders.length,
      updated: flags.length,
      removed: gone.length,
      serverExists: status.exists,
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
    await store.upsertMessages(accountId, path, [
      for (final h in headers)
        if (!cachedUids.contains(h.uid)) _cached(h),
    ]);
    have = await store.countMessages(accountId, path);
    return have;
  }

  /// The body, from the cache if we have it, else fetched and cached along
  /// with a preview for the list.
  Future<MailBody> body(String path, int uid) async {
    final cached = await store.readMessage(accountId, path, uid);
    if (cached != null && cached.bodyText != null) {
      return MailBody(
        text: cached.bodyText!,
        html: cached.bodyHtml,
        calendar: cached.calendar,
      );
    }
    final fetched = await transport.fetchBody(path, uid);
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
    return headers.length;
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
        cc: h.cc,
        replyTo: h.replyTo,
        attachmentBytes: h.attachmentBytes,
        isMeeting: h.isMeeting,
        preview: h.preview,
        messageId: h.messageId,
        inReplyTo: h.inReplyTo,
      );
}

class SyncResult {
  const SyncResult({
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.cacheReset = false,
    required this.serverExists,
  });

  final int added;
  final int updated;
  final int removed;

  /// UIDVALIDITY changed and the folder was refilled from scratch.
  final bool cacheReset;
  final int serverExists;

  @override
  String toString() =>
      'SyncResult(+$added ~$updated -$removed reset=$cacheReset exists=$serverExists)';
}
