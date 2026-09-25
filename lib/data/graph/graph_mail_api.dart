import 'dart:convert';

import '../../domain/calendar_invite.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:http/http.dart' as http;

import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../compose/mime_parts.dart' show bareContentId;
import '../mail_engine.dart';

/// A thin, typed client over the Microsoft Graph mail endpoints.
///
/// Knows about HTTP, JSON and Graph's shapes, and nothing about this app's
/// domain: the mapping to folders and messages lives in GraphTransport, so
/// this can be read against Microsoft's reference page and checked line by
/// line without also holding the app's model in mind.
///
/// Every call takes its access token from [accessToken] rather than holding
/// one. Graph tokens last about an hour and a sync can outlive that.
class GraphMailApi {
  GraphMailApi({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _given = httpClient;

  final Future<String> Function({bool force}) accessToken;

  /// A client handed in, which belongs to whoever handed it in.
  final http.Client? _given;

  /// One made here, kept, and closed by [close].
  ///
  /// Held rather than made per request because every request to Graph is a
  /// fresh TLS handshake otherwise, and opening a folder on a work mailbox
  /// is a dozen requests. Reusing the connection takes the largest single
  /// constant off the time before mail appears.
  http.Client? _own;

  http.Client get _client => _given ?? (_own ??= http.Client());

  /// Overridden by tests, which must not really wait out a throttle.
  final Future<void> Function(Duration)? sleep;

  /// How many times a throttled request is tried again before giving up.
  ///
  /// Graph throttles per app and per mailbox, and it throttles bursts hardest
  /// — which is exactly what adding an account is. It says how long to wait in
  /// a Retry-After header, so the right thing is to wait and try again rather
  /// than hand somebody a message about rate limiting that they can do nothing
  /// with except tap the button again themselves.
  static const maxThrottleRetries = 3;

  /// Longer than this and waiting is worse than reporting. Graph occasionally
  /// asks for minutes, and an app that appears frozen for three of them is
  /// not obviously better than one that says what happened.
  static const maxThrottleWait = Duration(seconds: 30);

  static const base = 'https://graph.microsoft.com/v1.0';

  /// Every property of a mail folder that v1.0 actually has.
  ///
  /// Deliberately not `wellKnownName`, which exists only in the beta API.
  /// Asking for it here made Graph refuse the whole request with a bare
  /// BadRequest, so every folder listing failed and nothing loaded at all.
  /// See [wellKnownFolderIds] for how the special folders are found instead.
  static const folderFields =
      'id,displayName,parentFolderId,childFolderCount,totalItemCount,'
      'unreadItemCount';

  /// The folders Outlook makes for everyone, by the names Graph answers to.
  ///
  /// These are addressable in place of an id — `/me/mailFolders/inbox` works
  /// whatever the mailbox language — which is what makes it possible to learn
  /// which folder is which without the beta-only property.
  static const wellKnownNames = [
    'inbox',
    'drafts',
    'sentitems',
    'deleteditems',
    'junkemail',
    'archive',
  ];

  /// What a message list needs. Asking for everything would pull each body
  /// down with its list row, which is the difference between a folder opening
  /// at once and it opening after a megabyte.
  static const headerFields =
      'id,subject,from,toRecipients,ccRecipients,replyTo,receivedDateTime,'
      'isRead,flag,hasAttachments,bodyPreview,internetMessageId,'
      'conversationId';

  // --- folders ---------------------------------------------------------------

  /// Every folder, including nested ones.
  ///
  /// Graph returns only the top level from /me/mailFolders, so this walks
  /// down. [maxDepth] stops a malformed parent chain from recursing forever;
  /// real mailboxes are nowhere near it.
  Future<List<GraphFolder>> listFolders({int maxDepth = 8}) async {
    final folders = <GraphFolder>[];

    Future<void> walk(String? parentId, int depth) async {
      if (depth > maxDepth) return;
      final path = parentId == null
          ? '/me/mailFolders'
          : '/me/mailFolders/${_id(parentId)}/childFolders';
      var next = Uri.parse('$base$path').replace(queryParameters: {
        '\$top': '100',
        '\$select': folderFields,
      });

      while (true) {
        final json = await _get(next);
        final values = json['value'];
        if (values is! List) break;
        for (final entry in values) {
          if (entry is! Map) continue;
          final folder = GraphFolder.fromJson(entry.cast<String, Object?>());
          if (folder == null) continue;
          folders.add(folder);
          if (folder.childFolderCount > 0) {
            await walk(folder.id, depth + 1);
          }
        }
        // Graph pages with an opaque link rather than a skip count; following
        // it is the only supported way to get the rest.
        final link = json['@odata.nextLink'];
        if (link is! String) break;
        next = Uri.parse(link);
      }
    }

    await walk(null, 0);
    return folders;
  }

  Future<GraphFolder> folder(String folderId) async {
    final json = await _get(
      Uri.parse('$base/me/mailFolders/${_id(folderId)}').replace(
        queryParameters: {r'$select': folderFields},
      ),
    );
    final folder = GraphFolder.fromJson(json);
    if (folder == null) {
      throw const ConnectionFailed('Microsoft sent back an unreadable folder.');
    }
    return folder;
  }

  /// Which folder id is the Inbox, the Sent folder, and so on.
  ///
  /// One request per name, run together. That is a handful of extra round
  /// trips per folder listing, and it is the supported way: v1.0 has no
  /// property saying what a folder is for, but it will resolve these names to
  /// the right folder in any mailbox, in any language.
  ///
  /// A name the mailbox does not have simply does not appear. Archive is the
  /// common case — plenty of mailboxes have never had one.
  Future<Map<String, String>> wellKnownFolderIds() async {
    final found = <String, String>{};
    var asking = wellKnownNames;
    for (var attempt = 0;; attempt++) {
      // One request, not one per name. Six at once was a burst, and a burst
      // is what Graph throttles hardest — adding an account could fail
      // outright with a 429 before anything had loaded.
      final json = await _post(Uri.parse('$base/\$batch'), {
        'requests': [
          for (final name in asking)
            {
              'id': name,
              'method': 'GET',
              'url': '/me/mailFolders/$name?\$select=id',
            },
        ],
      });

      // A batch answers 200 even when the requests inside it did not, so
      // each one carries its own status. A 404 is a mailbox with no Archive,
      // which is ordinary. A 429 or a 5xx is no answer at all: Graph
      // throttles the requests inside a batch one by one. Read as "no such
      // folder", a throttled Inbox was listed as an ordinary folder, and the
      // account went without notifications, the unified Inbox and Undo
      // until a later listing happened to get through.
      final again = <String>[];
      var wait = Duration.zero;
      final responses = json['responses'];
      for (final entry in responses is List ? responses : const []) {
        if (entry is! Map) continue;
        final name = entry['id'];
        if (name is! String) continue;
        final status = entry['status'];
        if (status == 200) {
          final body = entry['body'];
          final id = body is Map ? body['id'] : null;
          if (id is String && id.isNotEmpty) found[name] = id;
        } else if (status == 429 || (status is int && status >= 500)) {
          again.add(name);
          final asked = _innerRetryAfter(entry['headers']);
          if (asked > wait) wait = asked;
        }
      }
      if (again.isEmpty) return found;
      if (attempt >= maxThrottleRetries || wait > maxThrottleWait) {
        throw const ConnectionFailed(
          'Microsoft is busy and would not say which folder is the Inbox. '
          'Try again shortly.',
        );
      }
      await (sleep ?? _realSleep)(wait);
      asking = again;
    }
  }

  /// How long one request inside a batch asked to be left, 2 s if it did
  /// not say.
  static Duration _innerRetryAfter(Object? headers) {
    if (headers is Map) {
      for (final MapEntry(:key, :value) in headers.entries) {
        if ('$key'.toLowerCase() != 'retry-after') continue;
        final seconds = int.tryParse('$value'.trim());
        if (seconds != null) return Duration(seconds: seconds);
      }
    }
    return const Duration(seconds: 2);
  }

  Future<GraphFolder> createFolder({
    required String displayName,
    String? parentId,
  }) async {
    final path = parentId == null
        ? '/me/mailFolders'
        : '/me/mailFolders/${_id(parentId)}/childFolders';
    final json = await _post(
      Uri.parse('$base$path'),
      {'displayName': displayName},
    );
    final folder = GraphFolder.fromJson(json);
    if (folder == null) {
      throw const ConnectionFailed('Microsoft created the folder but sent '
          'back something unreadable.');
    }
    return folder;
  }

  Future<void> renameFolder(String folderId, String displayName) => _patch(
        Uri.parse('$base/me/mailFolders/${_id(folderId)}'),
        {'displayName': displayName},
      );

  /// Reparent, which Graph does as a move rather than as a rename.
  Future<void> moveFolder(String folderId, String newParentId) => _post(
        Uri.parse('$base/me/mailFolders/${_id(folderId)}/move'),
        {'destinationId': newParentId},
      );

  Future<void> deleteFolder(String folderId) =>
      _delete(Uri.parse('$base/me/mailFolders/${_id(folderId)}'));

  // --- messages --------------------------------------------------------------

  /// A page of a folder's messages, newest first.
  Future<List<GraphMessage>> messages(
    String folderId, {
    int skip = 0,
    int top = 50,
    DateTime? receivedAfter,
  }) async {
    final query = {
      '\$select': headerFields,
      '\$orderby': 'receivedDateTime desc',
      '\$top': '$top',
      if (skip > 0) '\$skip': '$skip',
      if (receivedAfter != null)
        '\$filter': 'receivedDateTime ge '
            '${receivedAfter.toUtc().toIso8601String()}',
    };
    final json = await _get(
      Uri.parse('$base/me/mailFolders/${_id(folderId)}/messages')
          .replace(queryParameters: query),
    );
    return _messagesFrom(json);
  }

  /// One message's headers, or null if it is no longer there.
  ///
  /// Null rather than an error: a message deleted from another device is the
  /// ordinary case, not a failure, and the sync mirrors the deletion.
  Future<GraphMessage?> message(String messageId) async {
    try {
      final json = await _get(
        Uri.parse('$base/me/messages/${_id(messageId)}')
            .replace(queryParameters: {'\$select': headerFields}),
      );
      return GraphMessage.fromJson(json);
    } on GraphNotFound {
      return null;
    }
  }

  /// The body, in both forms the reading pane can show.
  ///
  /// Two ways of telling a meeting request from a message, because one is
  /// not enough: `@odata.type`, which Graph sends for a derived type but
  /// has been seen left out of a `$select`ed response, and
  /// `meetingMessageType`, asked for through the cast that names it. A
  /// mailbox that refuses the cast falls back to the plain question rather
  /// than failing to show the message at all.
  Future<GraphBody?> body(String messageId) async {
    final uri = Uri.parse('$base/me/messages/${_id(messageId)}');
    try {
      Map<String, Object?> json;
      try {
        json = await _get(uri.replace(queryParameters: {
          '\$select': 'body,uniqueBody,hasAttachments,'
              'microsoft.graph.eventMessage/meetingMessageType',
        }));
      } on GraphNotFound {
        rethrow;
      } catch (_) {
        json = await _get(uri.replace(
          queryParameters: {'\$select': 'body,uniqueBody,hasAttachments'},
        ));
      }
      final body = json['body'];
      if (body is! Map) return null;
      final contentType = '${body['contentType']}'.toLowerCase();
      final content = '${body['content']}';
      return GraphBody(
        html: contentType == 'html' ? content : null,
        text: contentType == 'html' ? null : content,
        hasAttachments: json['hasAttachments'] == true,
        isEventMessage: '${json['@odata.type']}'.endsWith('.eventMessage') ||
            json['meetingMessageType'] != null,
      );
    } on GraphNotFound {
      return null;
    }
  }

  /// What is attached to a message, without the bytes.
  ///
  /// `$select` matters here: without it Graph returns `contentBytes` for
  /// every attachment, so listing what is on a message downloads all of it.
  Future<List<GraphAttachment>> attachments(String messageId) async {
    final json = await _get(
      Uri.parse('$base/me/messages/${_id(messageId)}/attachments').replace(
        queryParameters: {
          '\$select': 'id,name,contentType,size,isInline',
        },
      ),
    );
    final value = json['value'];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map<String, Object?>)
          GraphAttachment(
            id: '${item['id']}',
            name: '${item['name'] ?? ''}',
            mimeType: '${item['contentType'] ?? 'application/octet-stream'}',
            sizeBytes: item['size'] is int ? item['size'] as int : 0,
            isInline: item['isInline'] == true,
          ),
    ];
  }

  /// The name the message's HTML gives one attachment in a `cid:` link, or
  /// null if it has none or will not say.
  ///
  /// One at a time, and cast to a file in the path: `contentId` is not on
  /// the base attachment type, so the listing cannot select it, and listing
  /// without a selection downloads every file on the message.
  ///
  /// Where the cast is refused, the attachment is asked for whole, which
  /// says the same, bytes and all. For the small pictures a body names that
  /// costs little, and it is not done past [wholeAttachmentLimit]: a
  /// photograph is not worth its own weight again to learn its name. A cast
  /// that answers without a name is believed, and nothing more is asked.
  Future<String?> contentIdOf(
    String messageId,
    String attachmentId, {
    int sizeBytes = 0,
  }) async {
    final at = '$base/me/messages/${_id(messageId)}'
        '/attachments/${Uri.encodeComponent(attachmentId)}';
    try {
      final json = await _get(
        Uri.parse('$at/microsoft.graph.fileAttachment')
            .replace(queryParameters: {'\$select': 'id,contentId'}),
      );
      final id = json['contentId'];
      return id is String && id.trim().isNotEmpty ? bareContentId(id) : null;
    } catch (e) {
      // Said, because a picture that never showed failed silently here for
      // as long as it did.
      debugPrint('[myemail] content id: the cast was refused: $e');
    }
    if (sizeBytes > wholeAttachmentLimit) return null;
    try {
      final json = await _get(Uri.parse(at));
      final id = json['contentId'];
      return id is String && id.trim().isNotEmpty ? bareContentId(id) : null;
    } catch (e) {
      // A picture shown as a chip rather than in the body; nothing worse.
      debugPrint('[myemail] content id not had: $e');
      return null;
    }
  }

  /// The largest attachment asked for whole just to learn its Content-ID.
  static const wholeAttachmentLimit = 1024 * 1024;

  /// The bytes of one attachment.
  ///
  /// `/$value` rather than the JSON with contentBytes in it: the same data
  /// without a base64 round trip through a string, which for a 20MB file is
  /// the difference between a download and an out-of-memory.
  /// The event a meeting request is about, or null if this mailbox will
  /// not say which one it is.
  ///
  /// `event` is a link on `eventMessage`, not on `message`. A mailbox that
  /// does not hand the message over as its derived type answers the plain
  /// path with "Resource not found for the segment 'event'", so the cast
  /// is asked first: it names the type in the path and always parses. The
  /// plain path stays for mailboxes that refuse a cast, and the
  /// invitation's own UID finds the event on the calendar when neither
  /// works — automatic processing may have put it there without ever
  /// linking it back to the message.
  Future<String?> eventIdFor(String messageId, {String? iCalUid}) async {
    final id = _id(messageId);
    for (final path in [
      '$base/me/messages/$id/microsoft.graph.eventMessage/event',
      '$base/me/messages/$id/event',
    ]) {
      try {
        final json = await _get(
          Uri.parse(path).replace(queryParameters: {'\$select': 'id'}),
        );
        final eventId = json['id'];
        if (eventId is String && eventId.isNotEmpty) return eventId;
      } catch (_) {
        // Ask the next way.
      }
    }
    if (iCalUid == null || iCalUid.isEmpty) return null;
    try {
      final json = await _get(Uri.parse('$base/me/events').replace(
        queryParameters: {
          '\$filter': "iCalUId eq '${iCalUid.replaceAll("'", "''")}'",
          '\$select': 'id',
          '\$top': '1',
        },
      ));
      final value = json['value'];
      if (value is List && value.isNotEmpty) {
        final first = value.first;
        if (first is Map) {
          final eventId = first['id'];
          if (eventId is String && eventId.isNotEmpty) return eventId;
        }
      }
    } catch (_) {
      // The calendar cannot be searched either.
    }
    return null;
  }

  /// Answer the invitation an event message carries: accept, tentatively
  /// accept or decline the event on the calendar, telling the organiser.
  /// Two calls, because the message knows its event and the event takes
  /// the answer.
  ///
  /// False when no event could be found to answer on, which is the
  /// caller's cue to send the reply as mail instead. A refused answer on
  /// an event that was found is an error and says so.
  Future<bool> respondToInvite(
    String messageId,
    InviteResponse response, {
    String? iCalUid,
  }) async {
    final eventId = await eventIdFor(messageId, iCalUid: iCalUid);
    if (eventId == null) return false;
    final action = switch (response) {
      InviteResponse.accepted => 'accept',
      InviteResponse.tentative => 'tentativelyAccept',
      InviteResponse.declined => 'decline',
    };
    await _postNoContent(
      Uri.parse('$base/me/events/${_id(eventId)}/$action'),
      {'sendResponse': true},
    );
    return true;
  }

  /// A POST whose success is a 202 with nothing in it.
  Future<void> _postNoContent(Uri uri, Map<String, Object?> body) async {
    final response = await _exchange(http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body));
    if (response.statusCode == 404) throw const GraphNotFound();
    if (response.statusCode >= 400) {
      throw _failureFor(response.statusCode, _errorOf(response));
    }
  }

  /// The message as MIME, which is what Graph's `$value` on a message is:
  /// the RFC 822 form, for an `.eml`. One character per byte, as
  /// [MailEngine.rawMessage] has it; decoding it as UTF-8 put a U+FFFD in
  /// place of every 8-bit byte that was not.
  Future<String> mime(String messageId) async =>
      latin1.decode(await mimeBytes(messageId));

  /// The same, as the bytes themselves.
  Future<Uint8List> mimeBytes(String messageId) =>
      _bytes(Uri.parse('$base/me/messages/${_id(messageId)}/\$value'));

  Future<Uint8List> attachmentBytes(String messageId, String attachmentId) =>
      _bytes(
        Uri.parse(
          '$base/me/messages/${_id(messageId)}'
          '/attachments/${Uri.encodeComponent(attachmentId)}/\$value',
        ),
      );

  /// Full text search across the mailbox, scoped to one folder.
  Future<List<GraphMessage>> search(
    String folderId,
    String query, {
    int top = 100,
  }) async {
    // $search takes a quoted string and cannot be combined with $orderby;
    // Graph returns its own relevance order, which is what a search wants.
    final escaped = query.replaceAll('"', r'\"');
    final json = await _get(
      Uri.parse('$base/me/mailFolders/${_id(folderId)}/messages').replace(
        queryParameters: {
          '\$search': '"$escaped"',
          '\$select': headerFields,
          '\$top': '$top',
        },
      ),
    );
    return _messagesFrom(json);
  }

  Future<void> setRead(String messageId, bool isRead) => _patch(
        Uri.parse('$base/me/messages/${_id(messageId)}'),
        {'isRead': isRead},
      );

  Future<void> setFlagged(String messageId, bool isFlagged) => _patch(
        Uri.parse('$base/me/messages/${_id(messageId)}'),
        {
          'flag': {'flagStatus': isFlagged ? 'flagged' : 'notFlagged'},
        },
      );

  /// Move a message, returning its new id.
  ///
  /// Graph reissues the id on a move, so the caller has to take the new one:
  /// the old id stops resolving the moment this returns.
  Future<String?> move(String messageId, String destinationFolderId) async {
    final json = await _post(
      Uri.parse('$base/me/messages/${_id(messageId)}/move'),
      {'destinationId': destinationFolderId},
    );
    final id = json['id'];
    return id is String ? id : null;
  }

  Future<void> delete(String messageId) =>
      _delete(Uri.parse('$base/me/messages/${_id(messageId)}'));

  /// Put a MIME message into a folder, for drafts and for filing a copy.
  Future<String?> createMessage(String folderId, String mimeText) async {
    final json = await _send(
      http.Request(
        'POST',
        Uri.parse('$base/me/mailFolders/${_id(folderId)}/messages'),
      )
        ..headers['Content-Type'] = 'text/plain'
        ..body = base64Encode(utf8.encode(mimeText)),
    );
    final id = json['id'];
    return id is String ? id : null;
  }

  // --- plumbing --------------------------------------------------------------

  /// Graph ids are long, opaque and contain characters that mean something in
  /// a URL. They go through here every time.
  static String _id(String id) => Uri.encodeComponent(id);

  static List<GraphMessage> _messagesFrom(Map<String, Object?> json) {
    final values = json['value'];
    if (values is! List) return const [];
    return [
      for (final entry in values)
        if (entry is Map)
          ?GraphMessage.fromJson(entry.cast<String, Object?>()),
    ];
  }

  Future<Map<String, Object?>> _get(Uri uri) =>
      _send(http.Request('GET', uri));

  /// A response that is a file rather than JSON.
  ///
  /// Its own path because [_send] decodes what comes back, and an attachment
  /// is bytes: decoding a PDF as UTF-8 and re-encoding it produces something
  /// that is the right length and opens in nothing.
  Future<Uint8List> _bytes(Uri uri) async {
    final response = await _exchange(http.Request('GET', uri));
    if (response.statusCode == 404) throw const GraphNotFound();
    if (response.statusCode >= 400) {
      throw _failureFor(response.statusCode, _errorOf(response));
    }
    return response.bodyBytes;
  }

  /// Let go of the connection. Only one made here: a client handed in is
  /// closed by its owner.
  void close() {
    _own?.close();
    _own = null;
  }

  Future<Map<String, Object?>> _post(Uri uri, Map<String, Object?> body) =>
      _send(http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body));

  Future<Map<String, Object?>> _patch(Uri uri, Map<String, Object?> body) =>
      _send(http.Request('PATCH', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body));

  Future<Map<String, Object?>> _delete(Uri uri) =>
      _send(http.Request('DELETE', uri));

  /// The account's token, with a refresh that could not reach Microsoft
  /// read as what it is: no connection. See [SignInUnreachable].
  Future<String> _token({bool force = false}) async {
    try {
      return await accessToken(force: force);
    } on SignInUnreachable catch (e) {
      throw ConnectionFailed(e.message);
    }
  }

  /// Send what [build] makes with the account's token, and once more with a
  /// freshly refreshed one if Microsoft turns the first away.
  ///
  /// A token can look good here and not be: a clock running a few minutes
  /// slow, or Microsoft withdrawing it early. A 401 went straight to "sign
  /// in again", for up to an hour, when one refresh would have done. A
  /// second 401 is the real thing. [build] is called for each try because
  /// a request cannot be sent twice.
  Future<http.Response> _authorised(http.Request Function() build) async {
    for (var forced = false;; forced = true) {
      final request = build()
        ..headers['Authorization'] = 'Bearer ${await _token(force: forced)}';
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request));
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach Microsoft. ($e)');
      }
      if (response.statusCode != 401 || forced) return response;
    }
  }

  /// Send [request], waiting out any throttling Graph asks for.
  ///
  /// Every request goes through here, whatever it answers with: JSON for
  /// most, a file for an attachment or an `.eml`, nothing at all for an
  /// invitation answer. The last two used to go round it, so a throttled
  /// download or answer failed at once where everything else waited.
  Future<http.Response> _exchange(http.Request request) async {
    for (var attempt = 0;; attempt++) {
      // Copies, so the one given is never sent and can be copied again.
      final response = await _authorised(() => _copyOf(request));

      // Throttled, and Graph has said how long to wait. Waiting it out is the
      // whole remedy, and doing it here means nothing above this ever has to
      // know it happened.
      final wait = _retryAfter(response);
      if (wait == null || attempt >= maxThrottleRetries) return response;
      await (sleep ?? _realSleep)(wait);
    }
  }

  Future<Map<String, Object?>> _send(http.Request request) async {
    final response = await _exchange(request);

    if (response.statusCode == 404) throw const GraphNotFound();
    if (response.statusCode == 204 || response.body.isEmpty) {
      return const {};
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw ConnectionFailed(
        'Microsoft answered with something that was not JSON '
        '(HTTP ${response.statusCode}).',
      );
    }
    final json =
        decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{};

    if (response.statusCode >= 400) {
      throw _failureFor(response.statusCode, json);
    }
    return json;
  }

  /// Graph's error envelope from a response that is not otherwise JSON, or
  /// nothing if it has none.
  static Map<String, Object?> _errorOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON. The status is all there is.
    }
    return const {};
  }

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// How long to wait before trying again, or null if trying again is not the
  /// answer.
  ///
  /// Graph sends Retry-After in seconds on a 429 and often on a 503. Without
  /// the header a short pause is still better than failing, because both of
  /// those are conditions that pass.
  static Duration? _retryAfter(http.Response response) {
    if (response.statusCode != 429 && response.statusCode != 503) return null;
    final header = response.headers['retry-after'];
    final seconds = header == null ? null : int.tryParse(header.trim());
    final wait = Duration(seconds: seconds ?? 2);
    // Graph occasionally asks for minutes. Sitting there is worse than saying
    // what happened, so past the cap it is reported instead.
    return wait > maxThrottleWait ? null : wait;
  }

  /// An http.Request cannot be sent twice, so a retry needs its own.
  static http.Request _copyOf(http.Request original) {
    final copy = http.Request(original.method, original.url)
      ..bodyBytes = original.bodyBytes;
    copy.headers.addAll(original.headers);
    return copy;
  }

  static Exception _failureFor(int status, Map<String, Object?> json) {
    String? code;
    String? detail;
    final error = json['error'];
    if (error is Map) {
      code = error['code'] as String?;
      detail = error['message'] as String?;
    }

    if (status == 401 || code == 'InvalidAuthenticationToken') {
      return const AuthenticationFailed(
        'The sign-in for this account is no longer accepted. Open Settings, '
        'Accounts and sign in again.',
      );
    }
    if (status == 403) {
      return const AuthenticationFailed(
        'Microsoft would not let the app do that with this account. If it is '
        'a work or school account, an administrator may need to approve the '
        'app for your organisation.',
      );
    }
    if (status == 429 || status >= 500) {
      // Worth retrying, so it reads as a connection problem rather than as
      // something the person did.
      return ConnectionFailed(
        status == 429
            ? 'Microsoft is rate limiting this account. Try again shortly.'
            : 'Microsoft is having trouble (HTTP $status). Try again shortly.',
      );
    }
    // Graph's own sentence, kept. Without it a refusal reads as
    // "Microsoft refused the request (BadRequest)", which says only that
    // something was wrong with a request the person never made, and leaves
    // whoever has to fix it nothing to go on.
    return ConnectionFailed(
      'Microsoft refused the request (${code ?? 'HTTP $status'})'
      '${detail == null || detail.isEmpty ? '' : ': $detail'}',
    );
  }
}

/// One file on a message, as Graph describes it.
class GraphAttachment {
  const GraphAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.isInline,
  });

  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final bool isInline;
}

/// The message or folder is not there. Usually means deleted elsewhere.
class GraphNotFound implements Exception {
  const GraphNotFound();
  @override
  String toString() => 'Not found';
}

class GraphFolder {
  const GraphFolder({
    required this.id,
    required this.displayName,
    required this.parentId,
    required this.childFolderCount,
    required this.total,
    required this.unread,
  });

  final String id;
  final String displayName;
  final String? parentId;
  final int childFolderCount;
  final int total;
  final int unread;

  static GraphFolder? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return GraphFolder(
      id: id,
      displayName: json['displayName'] is String
          ? json['displayName'] as String
          : '(unnamed)',
      parentId:
          json['parentFolderId'] is String ? json['parentFolderId'] as String : null,
      childFolderCount: _int(json['childFolderCount']),
      total: _int(json['totalItemCount']),
      unread: _int(json['unreadItemCount']),
    );
  }
}

class GraphMessage {
  const GraphMessage({
    required this.id,
    required this.subject,
    required this.fromEmail,
    required this.fromName,
    required this.to,
    required this.received,
    this.cc = const [],
    this.replyTo = const [],
    this.isMeeting = false,
    required this.isRead,
    required this.isFlagged,
    required this.hasAttachments,
    required this.preview,
    this.internetMessageId,
  });

  final String id;
  final String subject;
  final String fromEmail;
  final String? fromName;
  final List<({String email, String? name})> to;

  /// Everyone copied openly. Comes with the list row, so it costs nothing.
  final List<({String email, String? name})> cc;

  /// Where replies are asked to go. Empty when the message did not say.
  final List<({String email, String? name})> replyTo;

  /// A meeting request, change or cancellation. Graph types these as a
  /// derived kind of message and says so in the list row itself.
  final bool isMeeting;
  final DateTime received;
  final bool isRead;
  final bool isFlagged;
  final bool hasAttachments;
  final String preview;
  final String? internetMessageId;

  static GraphMessage? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;

    final from = _address(json['from']);
    return GraphMessage(
      id: id,
      subject: json['subject'] is String && (json['subject'] as String).isNotEmpty
          ? json['subject'] as String
          : '(No subject)',
      fromEmail: from?.email ?? '',
      fromName: from?.name,
      to: [
        if (json['toRecipients'] is List)
          for (final r in json['toRecipients'] as List) ?_address(r),
      ],
      cc: [
        if (json['ccRecipients'] is List)
          for (final r in json['ccRecipients'] as List) ?_address(r),
      ],
      replyTo: [
        if (json['replyTo'] is List)
          for (final r in json['replyTo'] as List) ?_address(r),
      ],
      isMeeting: '${json['@odata.type']}'.endsWith('.eventMessage') ||
          json['meetingMessageType'] != null,
      received: DateTime.tryParse('${json['receivedDateTime']}')?.toUtc() ??
          DateTime.now().toUtc(),
      isRead: json['isRead'] == true,
      // Graph models a flag as an object with a status, where "flagged" and
      // "complete" both mean the star is on in Outlook.
      isFlagged: json['flag'] is Map &&
          const ['flagged', 'complete']
              .contains('${(json['flag'] as Map)['flagStatus']}'.toLowerCase()),
      hasAttachments: json['hasAttachments'] == true,
      preview: json['bodyPreview'] is String ? json['bodyPreview'] as String : '',
      internetMessageId: json['internetMessageId'] is String
          ? json['internetMessageId'] as String
          : null,
    );
  }

  static ({String email, String? name})? _address(Object? value) {
    if (value is! Map) return null;
    final inner = value['emailAddress'];
    if (inner is! Map) return null;
    final email = inner['address'];
    if (email is! String || email.isEmpty) return null;
    final name = inner['name'];
    return (email: email, name: name is String && name.isNotEmpty ? name : null);
  }
}

class GraphBody {
  const GraphBody({
    this.html,
    this.text,
    this.hasAttachments = false,
    this.isEventMessage = false,
  });

  final String? html;
  final String? text;
  final bool hasAttachments;

  /// A meeting request, cancellation or reply: Graph types it so, and its
  /// invitation is in its MIME rather than its body.
  final bool isEventMessage;
}

int _int(Object? value) => value is int ? value : 0;
