import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/folder_role.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../imap/imap_mapping.dart';
import '../../domain/calendar_invite.dart';
import 'package:enough_mail/enough_mail.dart' as em;
import '../imap/imap_transport.dart';
import '../mail_engine.dart';
import 'graph_id_map.dart';
import 'graph_mail_api.dart';

/// The app's mail transport, over Microsoft Graph.
///
/// Implements the same port the IMAP transport does, so everything above it —
/// the folder sync, the cache, the offline reads, the notification
/// watermarks, search, the whole UI — works against a Microsoft account with
/// no changes at all. That was the point of choosing this shape over a second
/// engine: the sync is the part with the subtle bugs already beaten out of it.
///
/// Why Graph rather than IMAP for these accounts: IMAP and SMTP are what
/// Microsoft calls legacy authentication, they are disabled by default on new
/// tenants, and an organisation with security defaults on blocks them at the
/// tenant level whatever the per-mailbox setting says. A work mailbox
/// therefore often cannot be reached over IMAP at all, and nothing the app
/// does can change that. Graph is the route Microsoft supports.
///
/// Two mismatches are worth knowing about, because they shape the code below.
///
/// Graph has no UIDs. Its message ids are opaque strings, so each message is
/// given a number the first time it is seen and [GraphIdMap] remembers which
/// is which. Numbers go up in the order messages are seen, the same rule IMAP
/// uses, which is what keeps the sync's arithmetic meaningful.
///
/// Graph has no IDLE. [awaitChanges] therefore waits out its timeout and
/// reports nothing happened, which the caller already treats as "time to sync
/// again" — so a Microsoft account polls where a Gmail one is pushed.
class GraphTransport implements ImapTransport {
  GraphTransport({
    required this.accountId,
    required this.api,
    required this.idMap,
  });

  final String accountId;
  final GraphMailApi api;
  final GraphIdMap idMap;

  /// Folder path to Graph id, filled by [listFolders] and needed by every call
  /// that takes a path.
  Map<String, String> _folderIds = {};

  /// How many messages to pull per page. Graph's own maximum is 1000; 100
  /// keeps each response small enough that a slow connection makes progress
  /// rather than timing out on one enormous request.
  static const _pageSize = 100;

  /// How far back a range scan will page before giving up. A folder with
  /// 50,000 messages must not turn one sync into a walk of the entire
  /// mailbox; the sync only ever asks about its cached window, which is far
  /// smaller than this.
  static const _maxPages = 40;

  // --- folders ---------------------------------------------------------------

  @override
  Future<List<RemoteFolder>> listFolders() async {
    // Both at once: the listing, and the answer to which of them is the Inbox.
    //
    // Started together but awaited one at a time, rather than with the record
    // form of wait. That wraps any failure in a ParallelWaitError, which would
    // replace the message this app wrote for the person — "sign in again", or
    // whatever Graph actually said — with wrapper text naming neither.
    final foldersRequest = api.listFolders();
    final wellKnownRequest = api.wellKnownFolderIds();
    // Registers a handler, so if the listing throws first and this one is
    // never awaited, its failure is not an unhandled asynchronous error.
    // Awaiting it below still surfaces the original.
    unawaited(wellKnownRequest.catchError((_) => <String, String>{}));

    final folders = await foldersRequest;
    final wellKnown = await wellKnownRequest;
    final roles = {
      for (final entry in wellKnown.entries) entry.value: entry.key,
    };

    // Build the display path of each folder by walking up its parents. Graph
    // gives a parent id and a name; the app wants "Work/Invoices".
    final byId = {for (final f in folders) f.id: f};
    String pathOf(GraphFolder folder) {
      final parts = <String>[safePathSegment(folder.displayName)];
      var cursor = folder;
      // Bounded: a cycle in the parent chain would otherwise hang the sync.
      for (var depth = 0; depth < 16; depth++) {
        final parentId = cursor.parentId;
        if (parentId == null) break;
        final parent = byId[parentId];
        // The parent is not in the list when it is the mailbox root, which
        // Graph reports as a parent but never returns as a folder.
        if (parent == null) break;
        parts.insert(0, safePathSegment(parent.displayName));
        cursor = parent;
      }
      return parts.join('/');
    }

    final result = <RemoteFolder>[];
    final ids = <String, String>{};
    for (final folder in folders) {
      final path = pathOf(folder);
      ids[path] = folder.id;
      result.add(RemoteFolder(
        path: path,
        role: _roleFor(roles[folder.id]),
        unread: folder.unread,
        total: folder.total,
      ));
    }
    _folderIds = ids;
    return result;
  }

  static FolderRole _roleFor(String? wellKnownName) => switch (wellKnownName) {
        'inbox' => FolderRole.inbox,
        'drafts' => FolderRole.drafts,
        'sentitems' => FolderRole.sent,
        'deleteditems' => FolderRole.deleted,
        'junkemail' => FolderRole.junk,
        'archive' => FolderRole.archive,
        // recoverableitemsdeletions, outbox, conversationhistory and the rest
        // have no place in this app's tree and read as ordinary folders.
        _ => FolderRole.user,
      };

  @override
  Future<FolderStatus> selectFolder(String path) async {
    final folder = await api.folder(await _folderId(path));
    return FolderStatus(
      // Graph reissues a folder id when a folder is deleted and one of the
      // same name made again, so hashing the id gives exactly what
      // UIDVALIDITY is for: the number changes, and the cache for that folder
      // is thrown away rather than being matched against a different folder's
      // messages.
      uidValidity: folder.id.hashCode & 0x7fffffff,
      exists: folder.total,
      uidNext: await idMap.highestUid(accountId, path) + 1,
      // No CONDSTORE equivalent, so callers fetch flags for the whole range
      // rather than only what changed.
      highestModSeq: null,
    );
  }

  @override
  Future<void> createFolder(String path) async {
    final cut = path.lastIndexOf('/');
    final name = cut < 0 ? path : path.substring(cut + 1);
    final parent = cut < 0 ? null : await _folderId(path.substring(0, cut));
    // The path has a stand-in for each slash in a name; Graph gets the name.
    final created = await api.createFolder(
      displayName: nameFromPathSegment(name),
      parentId: parent,
    );
    _folderIds[path] = created.id;
  }

  @override
  Future<void> renameFolder(String oldPath, String newPath) async {
    final id = await _folderId(oldPath);
    final oldCut = oldPath.lastIndexOf('/');
    final newCut = newPath.lastIndexOf('/');
    final oldParent = oldCut < 0 ? null : oldPath.substring(0, oldCut);
    final newParent = newCut < 0 ? null : newPath.substring(0, newCut);
    final newName = newCut < 0 ? newPath : newPath.substring(newCut + 1);

    // Graph splits what IMAP does with one RENAME: changing the name and
    // changing the parent are different calls, and a drag in the tree can do
    // both at once.
    if (oldParent != newParent) {
      await api.moveFolder(
        id,
        newParent == null ? 'msgfolderroot' : await _folderId(newParent),
      );
    }
    if (oldPath.substring(oldCut + 1) != newName) {
      // The name, not the path segment: sending the stand-in saved "AP/AR"
      // as a look-alike that nothing on the web matched.
      await api.renameFolder(id, nameFromPathSegment(newName));
    }
    // The folder and everything under it now live at the new path. Graph
    // keeps every id, so the ids and the numbering move with them; the
    // engine moves the cached rows the same way.
    _folderIds = {
      for (final e in _folderIds.entries)
        if (e.key == oldPath)
          newPath: e.value
        else if (e.key.startsWith('$oldPath/'))
          '$newPath${e.key.substring(oldPath.length)}': e.value
        else
          e.key: e.value,
    };
    await idMap.renameFolder(accountId, oldPath, newPath);
  }

  @override
  bool get deleteTakesSubfolders => true;

  @override
  Future<void> deleteFolder(String path) async {
    await api.deleteFolder(await _folderId(path));
    _folderIds.remove(path);
    await idMap.forgetFolder(accountId, path);
  }

  // --- reading ---------------------------------------------------------------

  @override
  Future<List<RemoteHeader>> fetchHeadersBySequence(
    String path,
    int start,
    int end,
  ) async {
    // IMAP sequence numbers run oldest first from 1. Graph pages newest
    // first, so the window has to be measured from the other end.
    final folder = await api.folder(await _folderId(path));
    final total = folder.total;
    if (total == 0 || start > end) return const [];

    final from = start.clamp(1, total);
    final to = end.clamp(1, total);
    final skip = total - to;
    final top = to - from + 1;
    if (top <= 0) return const [];

    final messages = await api.messages(
      folder.id,
      skip: skip < 0 ? 0 : skip,
      top: top,
    );
    // Back into oldest-first order, which is what the caller expects.
    return _headers(path, messages.reversed.toList());
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersFromUid(
    String path,
    int fromUid, {
    DateTime? windowStart,
  }) async {
    // Everything numbered at or above fromUid: mail that arrived since the
    // last sync, and mail moved in, which keeps its old date but gets a new
    // number. The scan reaches back across the whole cached window to find
    // the second kind, which can sit anywhere in date order.
    final fresh = await _scanBack(
      path,
      downToUid: fromUid,
      downToDate: windowStart,
    );
    return _headers(
      path,
      [
        for (final m in fresh.reversed)
          if ((fresh.uids[m.id] ?? 0) >= fromUid &&
              // The last page of the scan reaches past the window, and mail
              // down there, numbered on the way past, is older mail for
              // paging to bring in, not new mail. Returned here it would
              // stretch the window by a page on every sync.
              (windowStart == null || !m.received.isBefore(windowStart)))
            m,
      ],
    );
  }

  @override
  Future<List<RemoteFlags>> fetchFlags(
    String path,
    int fromUid,
    int toUid, {
    int? changedSinceModSeq,
    DateTime? windowStart,
  }) async {
    // changedSinceModSeq is ignored: Graph has no CONDSTORE, so this reports
    // the whole range and the caller compares.
    final scan = await _scanBack(
      path,
      downToUid: fromUid,
      downToDate: windowStart,
    );
    return [
      for (final m in scan.messages)
        if (_inRange(scan.uids[m.id], fromUid, toUid))
          RemoteFlags(
            uid: scan.uids[m.id]!,
            isRead: m.isRead,
            isFlagged: m.isFlagged,
            isAnswered: _answered(m.lastVerb),
            isForwarded: _forwarded(m.lastVerb),
          ),
    ];
  }

  /// Exchange's last verb as the two marks. A reply to all is a reply.
  static bool _answered(int? verb) =>
      verb == GraphMailApi.verbReply || verb == GraphMailApi.verbReplyAll;

  static bool _forwarded(int? verb) => verb == GraphMailApi.verbForward;

  @override
  bool get canRefreshHeaders => true;

  @override
  Future<List<RemoteHeader>> refreshHeaders(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) async {
    final scan = await _scanBack(
      path,
      downToUid: fromUid,
      downToDate: windowStart,
    );
    return _headers(path, [
      for (final m in scan.messages)
        if (_inRange(scan.uids[m.id], fromUid, toUid)) m,
    ]);
  }

  @override
  Future<Set<int>> existingUids(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) async {
    final scan = await _scanBack(
      path,
      downToUid: fromUid,
      downToDate: windowStart,
    );
    return {
      for (final m in scan.messages)
        if (_inRange(scan.uids[m.id], fromUid, toUid)) scan.uids[m.id]!,
    };
  }

  static bool _inRange(int? uid, int from, int to) =>
      uid != null && uid >= from && uid <= to;

  @override
  Future<MailBody> fetchBody(String path, int uid) async {
    final remoteId = await _remoteId(path, uid);
    final body = await api.body(remoteId);
    if (body == null) {
      throw const ConnectionFailed('That message is no longer on the server.');
    }
    // The invitation is not in the body Graph hands over; it is in the
    // message's MIME, the way it was sent. Only fetched for event messages:
    // the whole message can be tens of megabytes, and downloading it to look
    // for a part that is almost never there would make every message slow.
    String? calendar;
    if (body.isEventMessage) {
      try {
        calendar = calendarPartOf(
          em.MimeMessage.parseFromData(await api.mimeBytes(remoteId)),
        );
      } catch (_) {
        calendar = null;
      }
    }
    // A meeting the mail system never typed as one: an invitation attached
    // to an ordinary message, which is how a booking made outside Exchange
    // arrives. The list of what is attached is one small request and the
    // reading pane asks for it anyway; only the invitation itself is
    // downloaded, and only when there is one.
    calendar ??= body.hasAttachments
        ? await _calendarFileOn(remoteId)
        : null;
    return MailBody(text: body.text ?? '', html: body.html, calendar: calendar);
  }

  /// The invitation attached to a message, if one of its files is an
  /// `.ics`. Silent about failure: a message that will not give up its
  /// attachments still has a body worth showing.
  Future<String?> _calendarFileOn(String remoteId) async {
    try {
      for (final file in await api.attachments(remoteId)) {
        if (!isCalendarFile(file.mimeType, file.name)) continue;
        // An invitation is a few kilobytes of text. Something named .ics
        // and the size of a video is not one, and is not worth the wait.
        if (file.sizeBytes > 1024 * 1024) continue;
        final bytes = await api.attachmentBytes(remoteId, file.id);
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.trim().isNotEmpty) return text;
      }
    } catch (_) {
      // No invitation, then.
    }
    return null;
  }

  @override
  Future<bool> respondToInvite(
    String path,
    int uid,
    InviteResponse response, {
    String? iCalUid,
  }) async =>
      api.respondToInvite(
        await _remoteId(path, uid),
        response,
        iCalUid: iCalUid,
      );

  @override
  Future<List<MailAttachment>> listAttachments(String path, int uid) async {
    final remoteId = await _remoteId(path, uid);
    final listed = await api.attachments(remoteId);
    // Asked only of what the body could show: a part marked inline, or a
    // picture. A file nobody draws needs no second request.
    final contentIds = await Future.wait([
      for (final a in listed)
        a.isInline || a.mimeType.toLowerCase().startsWith('image/')
            ? api.contentIdOf(remoteId, a.id)
            : Future<String?>.value(),
    ]);
    return [
      for (final (i, a) in listed.indexed)
        MailAttachment(
          id: a.id,
          name: safeFileName(a.name),
          mimeType: a.mimeType,
          sizeBytes: a.sizeBytes,
          isInline: a.isInline,
          contentId: contentIds[i],
        ),
    ];
  }

  @override
  Future<Uint8List> fetchAttachment(
    String path,
    int uid,
    String attachmentId,
  ) async =>
      api.attachmentBytes(await _remoteId(path, uid), attachmentId);

  @override
  Future<String> fetchRaw(String path, int uid) async =>
      api.mime(await _remoteId(path, uid));

  @override
  Future<List<int>> searchUids(
    String path,
    String query, {
    int limit = 100,
  }) async {
    final found = await api.search(await _folderId(path), query, top: limit);
    final uids = await idMap.uidsFor(
      accountId,
      path,
      [for (final m in found.reversed) m.id],
    );
    // Newest first, which is the order a search result is read in.
    return [
      for (final m in found)
        if (uids.containsKey(m.id)) uids[m.id]!,
    ];
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersByUids(
    String path,
    List<int> uids,
  ) async {
    final remoteIds = await idMap.remoteIdsFor(accountId, path, uids);
    final messages = <GraphMessage>[];
    for (final uid in uids) {
      final id = remoteIds[uid];
      if (id == null) continue;
      final message = await api.message(id);
      // Gone since the search that found it. Skipping leaves it out of the
      // results rather than failing the whole search.
      if (message != null) messages.add(message);
    }
    return _headers(path, messages);
  }

  // --- writing ---------------------------------------------------------------

  @override
  Future<void> storeFlag(
    String path, {
    required List<int> uids,
    required MessageFlag flag,
    required bool set,
  }) async {
    final remoteIds = await idMap.remoteIdsFor(accountId, path, uids);
    for (final uid in uids) {
      final id = remoteIds[uid];
      if (id == null) continue;
      await _applyFlag(id, flag, set);
    }
  }

  @override
  Future<void> storeFlagOnAll(
    String path, {
    required MessageFlag flag,
    required bool set,
  }) async {
    final folderId = await _folderId(path);
    if (flag == MessageFlag.deleted && set) {
      return _deleteAll(folderId);
    }
    // Paged rather than one call: "mark all read" on a folder of thousands is
    // thousands of requests either way, and holding them all in memory first
    // buys nothing.
    for (var page = 0; page < _maxPages; page++) {
      final messages = await api.messages(
        folderId,
        skip: page * _pageSize,
        top: _pageSize,
      );
      if (messages.isEmpty) return;
      for (final m in messages) {
        // Already in the wanted state. Skipping keeps a second "mark all
        // read" from being thousands of pointless writes.
        if (flag == MessageFlag.seen && m.isRead == set) continue;
        if (flag == MessageFlag.flagged && m.isFlagged == set) continue;
        await _applyFlag(m.id, flag, set);
      }
      if (messages.length < _pageSize) return;
    }
  }

  /// Empty a folder: delete from the top of it until nothing is left.
  ///
  /// Not page by page with an offset. Each page deleted moves the rest up
  /// by a page, so the offset of the next one stepped over a page nobody
  /// had deleted: emptying 250 messages left 100 behind, while the app
  /// showed the folder empty until the next sync brought them back.
  Future<void> _deleteAll(String folderId) async {
    final tried = <String>{};
    while (true) {
      final messages = await api.messages(folderId, top: _pageSize);
      final fresh = [
        for (final m in messages)
          if (tried.add(m.id)) m,
      ];
      if (messages.isEmpty) return;
      if (fresh.isEmpty) {
        // Deleted, and still there. Going round again would never end.
        throw const ConnectionFailed(
          'Microsoft would not delete some of the messages in that folder.',
        );
      }
      for (final m in fresh) {
        await _applyFlag(m.id, MessageFlag.deleted, true);
      }
    }
  }

  Future<void> _applyFlag(String remoteId, MessageFlag flag, bool set) async {
    switch (flag) {
      case MessageFlag.seen:
        await api.setRead(remoteId, set);
      case MessageFlag.flagged:
        await api.setFlagged(remoteId, set);
      case MessageFlag.deleted:
        // Graph has no \Deleted to set and later expunge: deleting is a single
        // call, and it moves the message to Deleted Items exactly as Outlook
        // does. Unsetting is meaningless, so it does nothing rather than
        // pretending to undelete.
        if (set) await api.delete(remoteId);
      case MessageFlag.answered || MessageFlag.forwarded:
        // Exchange has no flag for either. It keeps what was last done to a
        // message, so setting one writes that, and there is nothing to clear.
        if (set) {
          await api.setLastVerb(
            remoteId,
            flag == MessageFlag.forwarded
                ? GraphMailApi.verbForward
                : GraphMailApi.verbReply,
            at: DateTime.now(),
          );
        }
    }
  }

  /// A reply to all is a verb of its own on Exchange.
  @override
  Future<void> markAnswered(String path, int uid, {bool toAll = false}) async =>
      api.setLastVerb(
        await _remoteId(path, uid),
        toAll ? GraphMailApi.verbReplyAll : GraphMailApi.verbReply,
        at: DateTime.now(),
      );

  @override
  Future<void> markForwarded(String path, int uid) async => api.setLastVerb(
        await _remoteId(path, uid),
        GraphMailApi.verbForward,
        at: DateTime.now(),
      );

  /// One last verb per message, so a forward replaces the reply before it.
  @override
  bool get keepsBothMarks => false;

  @override
  Future<List<int>?> moveMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  ) async {
    final destination = await _folderId(toPath);
    final remoteIds = await idMap.remoteIdsFor(accountId, fromPath, uids);

    final movedIds = <String>[];
    final moved = <int>[];
    try {
      for (final uid in uids) {
        final id = remoteIds[uid];
        if (id == null) continue;
        // Graph reissues the id on a move, and the old one stops resolving at
        // once. Taking the new one is what lets the destination folder be
        // numbered without a resync.
        final newId = await api.move(id, destination);
        moved.add(uid);
        if (newId != null) movedIds.add(newId);
      }
    } catch (e) {
      // One at a time, so a failure part way leaves some moved. Their old
      // numbers point at nothing now, and saying which went is what lets
      // them stay gone from the list and be put back.
      if (moved.isEmpty) rethrow;
      await idMap.forgetMoved(accountId, fromPath, moved);
      throw MovedInPart(
        moved: moved,
        landed: await _numbered(toPath, movedIds),
        cause: e,
      );
    }

    await idMap.forgetMoved(accountId, fromPath, uids);
    return _numbered(toPath, movedIds);
  }

  Future<List<int>?> _numbered(String path, List<String> remoteIds) async {
    if (remoteIds.isEmpty) return null;
    final assigned = await idMap.uidsFor(accountId, path, remoteIds);
    return [
      for (final id in remoteIds)
        if (assigned.containsKey(id)) assigned[id]!,
    ];
  }

  @override
  Future<void> appendMessage(
    String path,
    String mimeText, {
    bool seen = true,
    bool draft = false,
  }) async {
    final id = await api.createMessage(await _folderId(path), mimeText);
    // A message created from MIME arrives unread. Everything the app appends
    // is something the person wrote, so leaving it bold in Drafts would be
    // wrong.
    if (id != null && seen) await api.setRead(id, true);
  }

  @override
  Future<void> expunge(String path) async {
    // Nothing to do. Graph deletes when asked; there is no two-step mark and
    // sweep to finish.
  }

  @override
  Future<bool> awaitChanges(
    String path, {
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    // Graph's push is a webhook to a public HTTPS endpoint, which an app on a
    // tablet has no way to receive. Waiting out the timeout and reporting
    // nothing is what the interface documents for a server without IDLE, and
    // it degrades the caller to a poll rather than an error.
    await Future.any([
      Future<void>.delayed(timeout),
      ?cancel,
    ]);
    return false;
  }

  @override
  Future<void> close() async {
    // One connection to Graph, kept open between requests and let go here.
    api.close();
  }

  // --- plumbing --------------------------------------------------------------

  Future<String> _folderId(String path) async {
    final known = _folderIds[path];
    if (known != null) return known;
    // First call of a session, or a folder made on another device.
    await listFolders();
    final found = _folderIds[path];
    if (found == null) {
      throw StateError('No such folder on the server: $path');
    }
    return found;
  }

  Future<String> _remoteId(String path, int uid) async {
    final ids = await idMap.remoteIdsFor(accountId, path, [uid]);
    final id = ids[uid];
    if (id == null) {
      throw const ConnectionFailed(
        'That message is not on this device any more. Sync the folder and try '
        'again.',
      );
    }
    return id;
  }

  /// Page back through a folder, newest first, until the cached window has
  /// been covered.
  ///
  /// Numbering happens here, oldest of each page first, so the numbers keep
  /// rising with arrival order for mail arriving in the ordinary way.
  ///
  /// Where it stops. With [downToDate] — the oldest cached message's date —
  /// once a page reaches back past it: every cached message has then been
  /// seen, whatever its number. Without it, at the first page holding a
  /// number at or below [downToUid]. That was the only rule once, and it
  /// assumed numbers follow dates, which they do not for mail moved in (a
  /// new number, an old date) or older mail paged in (numbered when first
  /// seen, after the newer mail). A moved-in message below the first page
  /// was never found, and paged-in mail was taken for deleted on the next
  /// sync.
  ///
  /// One sync does this three or four times over — new mail, flags,
  /// deletions, previews — each a page of a hundred messages per request to
  /// Microsoft. Holding one answer and sharing it between them was tried and
  /// taken out again: a held scan cannot see mail that arrived since, and a
  /// transport that reports a folder as it was a moment ago is a bug waiting
  /// for the moment it matters. Sharing has to come from asking once and
  /// passing the answer down, not from a cache with a timer on it.
  ///
  /// Pages overlap by [_overlap], and each has to hold one of the last
  /// messages of the page before. Pages are asked for by offset, one request
  /// each, so a message leaving the folder between two of them moved every
  /// later one up a place, and the first of the next page was never seen:
  /// the sync then took it for deleted and dropped it from the cache, where
  /// nothing brought it back. When the folder moves by more than the
  /// overlap between two pages, the scan starts again.
  Future<_Scan> _scanBack(
    String path, {
    required int downToUid,
    DateTime? downToDate,
  }) async {
    final folderId = await _folderId(path);
    for (var attempt = 0;; attempt++) {
      final scan = await _scanOnce(
        folderId,
        path,
        downToUid: downToUid,
        downToDate: downToDate,
      );
      if (scan != null) return scan;
      if (attempt >= 2) {
        throw const ConnectionFailed(
          'The folder kept changing while it was being read. Try again in a '
          'moment.',
        );
      }
    }
  }

  /// How many messages each page shares with the one before it.
  static const _overlap = 10;

  /// One pass of [_scanBack], or null if the folder moved under it.
  Future<_Scan?> _scanOnce(
    String folderId,
    String path, {
    required int downToUid,
    DateTime? downToDate,
  }) async {
    // By id, so a message seen on two pages is one message.
    final messages = <String, GraphMessage>{};
    final uids = <String, int>{};
    List<GraphMessage>? previous;

    for (var page = 0; page < _maxPages; page++) {
      final batch = await api.messages(
        folderId,
        skip: page * (_pageSize - _overlap),
        top: _pageSize,
      );
      if (previous != null) {
        final tail = {
          for (final m in previous.skip(_pageSize - _overlap)) m.id,
        };
        if (!batch.any((m) => tail.contains(m.id))) return null;
      }
      if (batch.isEmpty) break;

      // Oldest first within the page, so the numbers handed out ascend.
      final assigned = await idMap.uidsFor(
        accountId,
        path,
        [for (final m in batch.reversed) m.id],
      );
      for (final m in batch) {
        messages[m.id] = m;
      }
      uids.addAll(assigned);
      previous = batch;

      if (batch.length < _pageSize) break;
      if (downToDate != null) {
        // Newest first, so the last in the page is the oldest seen so far.
        if (batch.last.received.isBefore(downToDate)) break;
        continue;
      }
      // Past the bottom of what was asked for, and no earlier page can hold
      // anything newer, as long as numbers follow dates.
      final lowest = batch
          .map((m) => assigned[m.id] ?? 0)
          .fold<int>(1 << 62, (a, b) => a < b ? a : b);
      if (lowest <= downToUid) break;
    }

    return _Scan(messages: messages.values.toList(), uids: uids);
  }

  Future<List<RemoteHeader>> _headers(
    String path,
    List<GraphMessage> messages,
  ) async {
    if (messages.isEmpty) return const [];
    final uids = await idMap.uidsFor(
      accountId,
      path,
      [for (final m in messages) m.id],
    );
    return [
      for (final m in messages)
        if (uids.containsKey(m.id))
          RemoteHeader(
            uid: uids[m.id]!,
            subject: m.subject,
            from: MailAddress(email: m.fromEmail, name: m.fromName),
            to: [
              for (final t in m.to) MailAddress(email: t.email, name: t.name),
            ],
            cc: [
              for (final t in m.cc) MailAddress(email: t.email, name: t.name),
            ],
            replyTo: replyToBesidesSender(
              [
                for (final t in m.replyTo)
                  MailAddress(email: t.email, name: t.name),
              ],
              MailAddress(email: m.fromEmail, name: m.fromName),
            ),
            isMeeting: m.isMeeting,
            date: m.received,
            isRead: m.isRead,
            isFlagged: m.isFlagged,
            isAnswered: _answered(m.lastVerb),
            isForwarded: _forwarded(m.lastVerb),
            hasAttachments: m.hasAttachments,
            preview: m.preview,
            messageId: m.internetMessageId,
            // Graph does not return In-Reply-To with a list row, and asking
            // for it costs a second request per message. Threading falls back
            // to the normalised subject for these accounts, which is what it
            // already does for any mail without the header.
            inReplyTo: null,
          ),
    ];
  }
}

class _Scan {
  const _Scan({required this.messages, required this.uids});

  /// Newest first, as Graph returns them.
  final List<GraphMessage> messages;
  final Map<String, int> uids;

  Iterable<GraphMessage> get reversed => messages.reversed;
}
