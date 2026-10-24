import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import '../../domain/folder_role.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../imap/imap_mapping.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/draft.dart' show SendFailed;
import 'package:enough_mail/enough_mail.dart' as em;
import '../compose/mime_parts.dart' show attachmentsInMime, mimeWithoutFiles;
import '../imap/imap_transport.dart';
import '../mail_engine.dart';
import 'filed_message.dart';
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
    this.maxMimeBytes = GraphMailApi.maxPostedMimeBytes,
  });

  final String accountId;
  final GraphMailApi api;
  final GraphIdMap idMap;

  /// The largest message put in a folder in one request; see
  /// [appendMessage]. Lowered by tests, for the reason GraphSender gives
  /// for its own.
  final int maxMimeBytes;

  /// Folder path to Graph id, filled by [listFolders] and needed by every call
  /// that takes a path.
  Map<String, String> _folderIds = {};

  /// How many messages to pull per page. Graph's own maximum is 1000; 100
  /// keeps each response small enough that a slow connection makes progress
  /// rather than timing out on one enormous request.
  static const _pageSize = 100;

  /// How far back a range scan will page before giving up. A folder with
  /// 50,000 messages must not turn one sync into a walk of the entire
  /// mailbox. A cached window can still reach further back than this, and a
  /// scan that stops here says so: see [existingUids].
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
    // number. The scan reaches back to windowStart to find the second kind,
    // which can sit anywhere in date order.
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
    // The rows with a last verb or an icon, as Graph sent them, for the
    // log: an arrow that fails to appear is either not on the server or not
    // read, and this tells the two apart.
    final marked = [
      for (final m in scan.messages)
        if (m.lastVerb != null || m.iconIndex != null) m,
    ];
    debugPrint('[myemail] verbs $path: ${scan.messages.length} rows, marked '
        '${[for (final m in marked.take(24)) '${scan.uids[m.id]}=${m.lastVerb}/${m.iconIndex}'].join(' ')}');
    return [
      for (final m in scan.messages)
        if (_inRange(scan.uids[m.id], fromUid, toUid))
          RemoteFlags(
            uid: scan.uids[m.id]!,
            isRead: m.isRead,
            isFlagged: m.isFlagged,
            isAnswered: _answered(m),
            isForwarded: _forwarded(m),
            // So mail already on the phone gets its size at the next sync,
            // not only mail that arrives from now on. Unknown stays unknown
            // rather than wiping a size already had.
            sizeBytes: m.sizeBytes,
            importance: m.importance,
          ),
    ];
  }

  /// Exchange's last verb as the two marks, and where it has none, the
  /// icon: Outlook on a desktop draws its own arrow from the icon and, for a
  /// forward made there, set the icon and not the verb on the server. A
  /// reply to all is a reply.
  static bool _answered(GraphMessage m) => switch (m.lastVerb) {
        GraphMailApi.verbReply || GraphMailApi.verbReplyAll => true,
        GraphMailApi.verbForward => false,
        _ => m.iconIndex == GraphMailApi.iconReplied,
      };

  static bool _forwarded(GraphMessage m) => switch (m.lastVerb) {
        GraphMailApi.verbForward => true,
        GraphMailApi.verbReply || GraphMailApi.verbReplyAll => false,
        _ => m.iconIndex == GraphMailApi.iconForwarded,
      };

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
  Future<Set<int>?> existingUids(
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
    // Out of pages before the bottom of the window: the messages below the
    // last page were never seen, and nothing here tells them apart from
    // mail that has gone. Listing only what was seen had the sync drop
    // every cached row down there, and paging fetch them all again for
    // the next sync to drop.
    if (!scan.complete) return null;
    return {
      for (final m in scan.messages)
        if (_inRange(scan.uids[m.id], fromUid, toUid)) scan.uids[m.id]!,
    };
  }

  @override
  bool get readsBackByDate => true;

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
    //
    // A download that could not be had for the moment leaves the words to
    // read and says the invitation is still to come, so the body is not
    // cached and the next open asks again (see [MailBody.calendarPending]).
    // Swallowed, the message was cached as one with no invitation, and its
    // card never came back; thrown, a meeting request with a large deck
    // attached could not be read at all on a weak signal. MIME Microsoft
    // refuses, or that will not parse, leaves the message to read without
    // one.
    String? calendar;
    var pending = false;
    if (body.isEventMessage) {
      try {
        calendar = calendarPartOf(
          em.MimeMessage.parseFromData(await api.mimeBytes(remoteId)),
        );
      } on GraphUnavailable {
        pending = true;
      } catch (_) {
        calendar = null;
      }
    }
    // A meeting the mail system never typed as one: an invitation attached
    // to an ordinary message, which is how a booking made outside Exchange
    // arrives. The list of what is attached is one small request and the
    // reading pane asks for it anyway; only the invitation itself is
    // downloaded, and only when there is one.
    if (calendar == null && !pending && body.hasAttachments) {
      try {
        calendar = await _calendarFileOn(remoteId);
      } on GraphUnavailable {
        pending = true;
      }
    }
    // Graph sends one form of the body, and for work mail it is HTML. The
    // text is what the cache makes the list's second line from and what a
    // meeting made from the message takes for notes, so it is the HTML read
    // as text, as it is for a Gmail message with no text part. Left empty,
    // it wiped the preview Graph had sent with the row.
    final html = body.html;
    return MailBody(
      text: body.text ?? (html != null ? htmlToText(html) : ''),
      html: html,
      calendar: calendar,
      calendarPending: pending,
    );
  }

  /// The invitation attached to a message, if one of its files is an
  /// `.ics`. Silent about a refusal: a message that will not give up its
  /// attachments still has a body worth showing. Not about Microsoft being
  /// out of reach for the moment, which would otherwise be cached as a
  /// message with no invitation; see [fetchBody].
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
    } on GraphUnavailable {
      rethrow;
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
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) async =>
      api.respondToInvite(
        await _remoteId(path, uid),
        response,
        iCalUid: iCalUid,
        note: note,
        send: send,
        proposal: proposal,
      );

  /// See [GraphMailApi.mailTips].
  Future<List<MailTip>> mailTips(List<String> emails) => api.mailTips(emails);

  @override
  Future<String?> linkedEventId(String path, int uid) async {
    try {
      return await api.linkedEventId(await _remoteId(path, uid));
    } catch (e) {
      // A message no longer here, or no connection: the calendar is still
      // asked by the invitation's UID.
      debugPrint('[myemail] could not follow a meeting message to its event: '
          '$e');
      return null;
    }
  }

  /// The conversation index of a message in [path], for a reply to it to
  /// carry on its thread (see `replyThreadIndex`). Null where it has none.
  Future<String?> conversationIndexOf(String path, int uid) async =>
      api.conversationIndex(await _remoteId(path, uid));

  @override
  Future<List<MailAttachment>> listAttachments(String path, int uid) async {
    final remoteId = await _remoteId(path, uid);
    final listed = await api.attachments(remoteId);
    final items = listed.where((a) => a.isItem).length;
    if (items > 0) {
      debugPrint('[myemail] attachments: $items of ${listed.length} are '
          'Outlook items, shown as attached emails');
    }
    // Asked only of what the body could show: a part marked inline, or a
    // picture. A file nobody draws needs no second request.
    final contentIds = await Future.wait([
      for (final a in listed)
        a.isInline || a.mimeType.toLowerCase().startsWith('image/')
            ? api.contentIdOf(remoteId, a.id, sizeBytes: a.sizeBytes)
            : Future<String?>.value(),
    ]);
    return [
      for (final (i, a) in listed.indexed)
        if (a.isItem)
          attachedItem(a)
        else
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
  Future<Map<String, String>> headerValues(
    String path,
    int uid,
    List<String> names,
  ) async {
    if (names.isEmpty) return const {};
    final wanted = {for (final n in names) n.toLowerCase()};
    final found = <String, String>{};
    for (final h in await api.internetHeaders(await _remoteId(path, uid))) {
      final name = h.name.toLowerCase();
      if (wanted.contains(name) && h.value.trim().isNotEmpty) {
        found.putIfAbsent(name, () => h.value.trim());
      }
    }
    return found;
  }

  /// Exchange keeps no such mark where Graph can set it.
  @override
  Future<void> markReceiptAnswered(String path, int uid) async {}

  /// Graph sends the importance with every row and with the flags, so this
  /// is asked only of rows the scans have not reached.
  @override
  Future<Map<int, Importance>> importanceOf(String path, List<int> uids) async {
    if (uids.isEmpty) return const {};
    final remoteIds = await idMap.remoteIdsFor(accountId, path, uids);
    final byRemote = {
      for (final uid in uids)
        if (remoteIds[uid] case final id? when id.isNotEmpty) id: uid,
    };
    final rated = await api.importanceOf(byRemote.keys.toList());
    return {
      for (final MapEntry(key: id, value: importance) in rated.entries)
        byRemote[id]!: importance,
    };
  }

  /// Twenty messages to a request; see [GraphMailApi.attachmentsOf].
  /// Named as [listAttachments] names them, so a name tapped on a row is
  /// the file of that name on the message.
  @override
  Future<Map<int, List<String>>> attachmentNames(
    String path,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return const {};
    final remoteIds = await idMap.remoteIdsFor(accountId, path, uids);
    final byRemote = {
      for (final uid in uids)
        if (remoteIds[uid] case final id? when id.isNotEmpty) id: uid,
    };
    final listed = await api.attachmentsOf(byRemote.keys.toList());
    return {
      for (final MapEntry(key: id, value: files) in listed.entries)
        byRemote[id]!: [
          for (final a in files)
            if (!a.isInline) a.isItem ? attachedItem(a).name : safeFileName(a.name),
        ],
    };
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
    SearchField field = SearchField.all,
    bool unlabelledOnly = false,
  }) async {
    final found = await api.search(
      await _folderId(path),
      query,
      top: limit,
      field: field,
    );
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

  /// The search's answer carries every field of a header already. Kept to
  /// the numbers, each hit nobody had cached was asked for again, one GET
  /// after another: a folder of a hundred old hits took a hundred round
  /// trips, and the whole search waited for it.
  @override
  Future<List<SearchHit>> searchHits(
    String path,
    String query, {
    int limit = 100,
    SearchField field = SearchField.all,
    bool unlabelledOnly = false,
  }) async {
    final found = await api.search(
      await _folderId(path),
      query,
      top: limit,
      field: field,
    );
    // Numbered oldest first, as searchUids numbers them, and handed back
    // newest first.
    final headers = await _headers(path, found.reversed.toList());
    return [for (final h in headers.reversed) (uid: h.uid, header: h)];
  }

  /// With each hit's header, as [searchHits] has them: Graph answers with
  /// the messages themselves.
  @override
  Future<List<SearchHit>> filterHits(
    String path,
    MessageFilter filter, {
    required String ownAddress,
    int limit = 100,
  }) async {
    final found = await api.filtered(
      await _folderId(path),
      filter,
      ownAddress: ownAddress,
      top: limit,
    );
    // Numbered oldest first, as a search numbers them, and handed back
    // newest first.
    final headers = await _headers(path, found.reversed.toList());
    return [for (final h in headers.reversed) (uid: h.uid, header: h)];
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

  /// Every flagged message in the mailbox as search hits, by the folder
  /// each is in, with the day its flag is due: see
  /// [GraphMailApi.flaggedEverywhere]. Not part of [ImapTransport]: over
  /// IMAP each folder is asked on its own.
  Future<List<({String path, SearchHit hit, DateTime? due})>> flaggedHits({
    int limit = 100,
  }) async {
    final found = await api.flaggedEverywhere(top: limit);
    if (found.isEmpty) return const [];
    if (_folderIds.isEmpty) await listFolders();
    final paths = {
      for (final MapEntry(:key, :value) in _folderIds.entries) value: key,
    };
    final byPath = <String, List<GraphMessage>>{};
    for (final m in found) {
      final path = paths[m.parentFolderId];
      if (path != null) (byPath[path] ??= []).add(m);
    }
    final hits = <({String path, SearchHit hit, DateTime? due})>[];
    for (final MapEntry(key: path, value: messages) in byPath.entries) {
      // Numbered oldest first, as a search numbers them.
      final oldestFirst = messages.reversed.toList();
      final headers = await _headers(path, oldestFirst);
      final due = {for (final m in oldestFirst) m.id: m.flagDue};
      final ids = await idMap.remoteIdsFor(
          accountId, path, [for (final h in headers) h.uid]);
      for (final h in headers.reversed) {
        hits.add((
          path: path,
          hit: (uid: h.uid, header: h),
          due: due[ids[h.uid]],
        ));
      }
    }
    return hits;
  }

  // --- recover deleted items -------------------------------------------------

  /// Mail emptied out of Deleted Items: see [GraphMailApi.recoverable].
  /// Not part of [ImapTransport]: only Exchange keeps it.
  Future<List<RecoverableMessage>> recoverable({
    int skip = 0,
    int top = 50,
    String query = '',
  }) async {
    final found = await api.recoverable(skip: skip, top: top, query: query);
    return [
      for (final (:message, :deletedOn) in found)
        RecoverableMessage(
          id: message.id,
          subject: message.subject,
          from: MailAddress(email: message.fromEmail, name: message.fromName),
          received: message.received.toLocal(),
          deletedOn: deletedOn,
          preview: message.preview,
          hasAttachments: message.hasAttachments,
        ),
    ];
  }

  /// Back into the Inbox; answers how many went.
  Future<int> recover(List<String> ids) async =>
      (await api.recover(ids)).length;

  // --- writing ---------------------------------------------------------------

  @override
  Future<void> storeFlag(
    String path, {
    required List<int> uids,
    required MessageFlag flag,
    required bool set,
  }) async {
    final remoteIds = await idMap.remoteIdsFor(accountId, path, uids);
    final failures = await _applyFlag(
      [for (final uid in uids) ?remoteIds[uid]],
      flag,
      set,
    );
    if (failures.isEmpty) return;
    // Which went is said, so a selection marked part way keeps on screen
    // the part that was.
    final stored = [
      for (final uid in uids)
        if (!failures.containsKey(remoteIds[uid])) uid,
    ];
    if (stored.isEmpty) throw failures.values.first;
    throw FlaggedInPart(stored: stored, cause: failures.values.first);
  }

  /// Outlook's Follow Up on [uids]: see [MailEngine.setFollowUp]. A flag
  /// with no date is taken off and put back, which is what clears a day set
  /// before: Graph is not known to take a null in its place. Fails as
  /// [storeFlag] does.
  Future<void> storeFollowUp(
    String path, {
    required List<int> uids,
    DateTime? due,
    bool complete = false,
  }) async {
    final remoteIds = await idMap.remoteIdsFor(accountId, path, uids);
    final ids = [for (final uid in uids) ?remoteIds[uid]];
    final noDate = due == null && !complete;
    final failures = noDate
        ? await _applyFlag(ids, MessageFlag.flagged, false)
        : <String, Exception>{};
    final answers = await api.batch([
      for (final id in ids)
        if (!failures.containsKey(id))
          noDate
              ? GraphRequest.flagged(id, true)
              : GraphRequest.followUp(id, due: due, complete: complete),
    ]);
    final asked = [
      for (final id in ids)
        if (!failures.containsKey(id)) id,
    ];
    for (final (i, id) in asked.indexed) {
      final failure = answers[i].failure;
      if (failure != null) failures[id] = failure;
    }
    if (failures.isEmpty) return;
    final stored = [
      for (final uid in uids)
        if (!failures.containsKey(remoteIds[uid])) uid,
    ];
    if (stored.isEmpty) throw failures.values.first;
    throw FlaggedInPart(stored: stored, cause: failures.values.first);
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
    if (flag == MessageFlag.seen && set) {
      return _markAllRead(folderId);
    }
    // Any other mark on a whole folder, which the app does not ask for, is
    // paged through. Holding the folder in memory first buys nothing.
    for (var page = 0; page < _maxPages; page++) {
      final messages = await api.messages(
        folderId,
        skip: page * _pageSize,
        top: _pageSize,
      );
      if (messages.isEmpty) return;
      final failures = await _applyFlag(
        [
          for (final m in messages)
            // Already in the wanted state, and left alone.
            if (!(flag == MessageFlag.seen && m.isRead == set) &&
                !(flag == MessageFlag.flagged && m.isFlagged == set))
              m.id,
        ],
        flag,
        set,
      );
      if (failures.isNotEmpty) throw failures.values.first;
      if (messages.length < _pageSize) return;
    }
  }

  /// Mark a folder read: what is unread, from the top, until nothing is.
  ///
  /// Asked for by what is unread, not paged through by offset. That looked
  /// at the newest 4,000 and stopped without a word, so older unread mail
  /// in a folder a rule fills stayed unread and its badge stayed up; and
  /// it listed every message to find the few unread. What is read already
  /// is not listed, so a second Mark all read writes nothing. Each page
  /// marked drops out of the next listing, as an emptied one does in
  /// [_deleteAll], and the marks go twenty to a request.
  Future<void> _markAllRead(String folderId) async {
    final tried = <String>{};
    while (true) {
      final unread = await api.unreadMessages(folderId, top: _pageSize);
      if (unread.isEmpty) return;
      final fresh = [
        for (final m in unread)
          if (tried.add(m.id)) m.id,
      ];
      if (fresh.isEmpty) {
        // Marked, and still unread. Going round again would never end.
        throw const ConnectionFailed(
          'Microsoft would not mark some of the messages in that folder read.',
        );
      }
      final answers = await api.batch([
        for (final id in fresh) GraphRequest.read(id, true),
      ]);
      for (final (json: _, :failure) in answers) {
        // Gone since the page was listed: nothing left to mark.
        if (failure == null || failure is GraphNotFound) continue;
        throw failure;
      }
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
      final answers = await api.batch([
        for (final m in fresh) GraphRequest.delete(m.id),
      ]);
      for (final (json: _, :failure) in answers) {
        // Gone since the page was listed (Outlook, a rule, another
        // device): the delete asked for has already happened.
        if (failure == null || failure is GraphNotFound) continue;
        throw failure;
      }
    }
  }

  /// Set or clear [flag] on each of [remoteIds], twenty to a request (see
  /// [GraphMailApi.batch]), and answer with the ones that failed and why,
  /// in the order asked, once every one has been tried.
  Future<Map<String, Exception>> _applyFlag(
    List<String> remoteIds,
    MessageFlag flag,
    bool set,
  ) async {
    final asked = [
      for (final id in remoteIds)
        if (_flagRequest(id, flag, set) case final request?) (id, request),
    ];
    final answers = await api.batch([for (final (_, r) in asked) r]);
    final failures = <String, Exception>{};
    for (final (i, (id, _)) in asked.indexed) {
      final failure = answers[i].failure;
      if (failure == null) continue;
      // A delete of mail already gone has nothing left to do. Anything
      // else on a message that is not there is still a failure.
      if (failure is GraphNotFound &&
          flag == MessageFlag.deleted &&
          set &&
          await api.message(id) == null) {
        continue;
      }
      failures[id] = failure;
    }
    return failures;
  }

  /// What sets or clears [flag] on one message, or null where there is
  /// nothing to do.
  static GraphRequest? _flagRequest(
    String remoteId,
    MessageFlag flag,
    bool set,
  ) =>
      switch (flag) {
        MessageFlag.seen => GraphRequest.read(remoteId, set),
        MessageFlag.flagged => GraphRequest.flagged(remoteId, set),
        // Graph has no \Deleted to set and later expunge: deleting is a
        // single call, and it moves the message to Deleted Items exactly as
        // Outlook does. Unsetting is meaningless, so it does nothing rather
        // than pretending to undelete.
        MessageFlag.deleted => set ? GraphRequest.delete(remoteId) : null,
        // Exchange has no flag for either. It keeps what was last done to a
        // message, so setting one writes that, and there is nothing to
        // clear.
        MessageFlag.answered || MessageFlag.forwarded => set
            ? GraphRequest.lastVerb(
                remoteId,
                flag == MessageFlag.forwarded
                    ? GraphMailApi.verbForward
                    : GraphMailApi.verbReply,
                at: DateTime.now(),
              )
            : null,
      };

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

  /// Not asked of Microsoft: only Gmail's All Mail needs a copy in place of
  /// a move, and Exchange has no folder like it.
  @override
  Future<List<int>?> copyMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  ) =>
      throw UnsupportedError('Copying is only needed for Gmail.');

  @override
  Future<List<int>?> moveMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  ) async {
    final destination = await _folderId(toPath);
    final remoteIds = await idMap.remoteIdsFor(accountId, fromPath, uids);
    final asked = [
      for (final uid in uids)
        if (remoteIds[uid] != null) uid,
    ];

    // Twenty to a request; see GraphMailApi.batch.
    final answers = await api.batch([
      for (final uid in asked) GraphRequest.move(remoteIds[uid]!, destination),
    ]);

    final movedIds = <String>[];
    final moved = <int>[];
    Object? failure;
    for (final (i, uid) in asked.indexed) {
      final (:json, failure: refused) = answers[i];
      if (refused == null) {
        moved.add(uid);
        // Graph reissues the id on a move, and the old one stops resolving
        // at once. Taking the new one is what lets the destination folder
        // be numbered without a resync.
        final newId = json['id'];
        if (newId is String && newId.isNotEmpty) movedIds.add(newId);
        continue;
      }
      if (refused is GraphNotFound && failure == null) {
        // Deleted or moved already, from Outlook, a rule, another device.
        // Where it was asked to leave, it has left: counted as moved, so
        // its number is spent and its row goes. A Delete from the shade
        // otherwise failed five times over and then said the message was
        // where it was. Unless the message is still there, in which case
        // what was not found is the destination, and so it is for the rest.
        try {
          if (await api.message(remoteIds[uid]!) == null) {
            moved.add(uid);
            continue;
          }
        } catch (e) {
          failure = e;
          continue;
        }
      }
      failure ??= refused;
    }

    if (failure != null) {
      // Some may have gone and others not. Their old numbers point at
      // nothing now, and saying which went is what lets them stay gone from
      // the list and be put back.
      if (moved.isEmpty) throw failure;
      await idMap.forgetMoved(accountId, fromPath, moved);
      throw MovedInPart(
        moved: moved,
        landed: await _numbered(toPath, movedIds),
        cause: failure,
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
    final folderId = await _folderId(path);
    final id = utf8.encode(mimeText).length <= maxMimeBytes
        ? await api.createMessage(folderId, mimeText)
        : await _createInPieces(folderId, mimeText);
    // A message created from MIME arrives unread. Everything the app appends
    // is something the person wrote, so leaving it bold in Drafts would be
    // wrong. But it exists by now: failing to mark it must not read as not
    // saved, or the caller saves another copy.
    if (seen) {
      try {
        await api.setRead(id, true);
      } catch (e) {
        debugPrint('[myemail] appended, but not marked read: $e');
      }
    }
  }

  /// A message too large to post whole, made the way GraphSender sends
  /// one: the message without its files first, then each file put on it,
  /// through an upload session where the file is itself too large. Posted
  /// whole, a draft with a 4 MB file on it was refused every time.
  ///
  /// If a file will not go, the message is taken back out and the failure
  /// thrown: a draft without its files is not the draft, and the copy it
  /// was to replace is still there.
  Future<String> _createInPieces(String folderId, String mimeText) async {
    final words = mimeWithoutFiles(mimeText);
    final size = utf8.encode(words).length;
    if (size > maxMimeBytes) {
      // The message itself, not its files: a picture pasted into the text
      // is the usual cause, and it cannot be split off the way a file can.
      throw SendFailed(
        'The message itself is ${(size / (1024 * 1024)).toStringAsFixed(1)} '
        'MB before any attachments, which is more than Microsoft accepts in '
        'one piece, so it was not saved. Pictures pasted into the message '
        'are the usual cause; attaching them instead works.',
      );
    }
    final id = await api.createMessage(folderId, words);
    try {
      for (final a in attachmentsInMime(mimeText)) {
        await api.attach(
          id,
          name: a.fileName,
          contentType: a.mimeType,
          bytes: a.bytes,
          contentId: a.contentId,
        );
      }
    } catch (_) {
      try {
        await api.delete(id);
      } catch (e) {
        debugPrint('[myemail] a half-saved draft was left: $e');
      }
      rethrow;
    }
    return id;
  }

  /// As received mail, in Graph's JSON: see [filedMessageFromMime].
  ///
  /// The files go up one by one after the message. If one will not, the
  /// message is taken back out and the failure thrown, so the move fails
  /// whole and the original stays where it was: a copy without its files
  /// is not the message.
  @override
  Future<int?> fileMessage(
    String path,
    String mimeText, {
    required bool seen,
    bool flagged = false,
    DateTime? arrived,
  }) async {
    final filed =
        filedMessageFromMime(mimeText, flagged: flagged, arrived: arrived);
    final id = await api.fileMessage(await _folderId(path), filed.message);
    try {
      for (final a in filed.attachments) {
        await api.attach(
          id,
          name: a.fileName,
          contentType: a.mimeType,
          bytes: a.bytes,
          contentId: a.contentId,
        );
      }
    } catch (_) {
      try {
        await api.delete(id);
      } catch (e) {
        debugPrint('[myemail] a half-filed message was left: $e');
      }
      rethrow;
    }
    if (!seen) {
      // Filed read, as it has to be to be filed at all. Unread is a mark,
      // and failing to set it must not undo a move that has happened.
      try {
        await api.setRead(id, false);
      } catch (e) {
        debugPrint('[myemail] filed, but not marked unread: $e');
      }
    }
    return (await _numbered(path, [id]))?.firstOrNull;
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
  /// Where it stops. With [downToDate] — the oldest date the sync is asking
  /// about — once a page reaches back past it: every message since then has
  /// been seen, whatever its number. Without it, at the first page holding
  /// a number at or below [downToUid]. That was the only rule once, and it
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

    for (var page = 0;; page++) {
      if (page == _maxPages) {
        return _Scan(
          messages: messages.values.toList(),
          uids: uids,
          complete: false,
        );
      }
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

    return _Scan(
      messages: messages.values.toList(),
      uids: uids,
      complete: true,
    );
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
            isAnswered: _answered(m),
            isForwarded: _forwarded(m),
            hasAttachments: m.hasAttachments,
            // Graph says only that there are files, not what they are
            // called: asked for after, for the rows that need them.
            attachmentNames: m.hasAttachments ? null : const [],
            sizeBytes: m.sizeBytes ?? 0,
            preview: m.preview,
            messageId: m.internetMessageId,
            // Graph does not return In-Reply-To with a list row, and asking
            // for it costs a second request per message. Threading falls back
            // to the normalised subject for these accounts, which is what it
            // already does for any mail without the header.
            inReplyTo: null,
            // What Exchange groups by, and Outlook shows: the one thing that
            // tells two unrelated messages with one subject apart.
            conversationId: m.conversationId,
            importance: m.importance,
          ),
    ];
  }
}

class _Scan {
  const _Scan({
    required this.messages,
    required this.uids,
    required this.complete,
  });

  /// Newest first, as Graph returns them.
  final List<GraphMessage> messages;
  final Map<String, int> uids;

  /// Whether the scan got as far back as it was asked to, or to the end of
  /// the folder. False when it ran out of pages first.
  final bool complete;

  Iterable<GraphMessage> get reversed => messages.reversed;
}

/// An Outlook item attached to a message, as the file it downloads as.
///
/// Graph names it after the item's subject and gives it no media type, and
/// what it downloads as is the item in MIME. Almost always it is an email
/// dragged into the message, so it is called one (`.eml`): it shows as one,
/// opens in the app as one, and goes to other apps as one. Offered as an
/// unnamed file, Android's choices for it were Google Pay and the launcher.
/// A calendar item or a contact is called that where Graph says so.
MailAttachment attachedItem(GraphAttachment a) {
  final type = a.mimeType.toLowerCase();
  final (mime, extension) = type.startsWith('text/calendar')
      ? ('text/calendar', 'ics')
      : type.contains('vcard')
          ? ('text/vcard', 'vcf')
          : ('message/rfc822', 'eml');
  final name = a.name.trim().isEmpty ? 'Attached item' : a.name.trim();
  return MailAttachment(
    id: a.id,
    name: safeFileName(
      name.toLowerCase().endsWith('.$extension') ? name : '$name.$extension',
    ),
    mimeType: mime,
    sizeBytes: a.sizeBytes,
  );
}
