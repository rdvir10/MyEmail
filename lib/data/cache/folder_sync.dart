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

    // New mail.
    final fresh = await transport.fetchHeadersFromUid(path, range.max + 1);
    final newHeaders = [
      for (final h in fresh)
        if (h.uid > range.max) h,
    ];
    await store.upsertMessages(accountId, path, newHeaders.map(_cached).toList());

    // Flag changes across the cached window.
    final useCondStore =
        previous.highestModSeq != null && status.highestModSeq != null;
    final flags = await transport.fetchFlags(
      path,
      range.min,
      range.max,
      changedSinceModSeq: useCondStore ? previous.highestModSeq : null,
    );
    await store.updateFlags(accountId, path, {
      for (final f in flags) f.uid: (isRead: f.isRead, isFlagged: f.isFlagged),
    });

    // Deletions.
    final existing = await transport.existingUids(path, range.min, range.max);
    final cached = await store.readMessages(
      accountId,
      path,
      offset: 0,
      limit: 1 << 30,
    );
    final gone = {
      for (final m in cached)
        if (m.uid <= range.max && !existing.contains(m.uid)) m.uid,
    };
    await store.deleteUids(accountId, path, gone);

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
    final range = await store.uidRange(accountId, path);
    await store.upsertMessages(accountId, path, [
      for (final h in headers)
        if (range == null || h.uid < range.min) _cached(h),
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

  Future<void> _writeState(String path, FolderStatus status) =>
      store.writeFolderState(
        accountId,
        path,
        FolderSyncState(
          uidValidity: status.uidValidity,
          uidNext: status.uidNext,
          highestModSeq: status.highestModSeq,
          lastSync: _clock(),
        ),
      );

  static CachedMessage _cached(RemoteHeader h) => CachedMessage(
        uid: h.uid,
        subject: h.subject,
        from: h.from,
        to: h.to,
        date: h.date,
        isRead: h.isRead,
        isFlagged: h.isFlagged,
        hasAttachments: h.hasAttachments,
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
