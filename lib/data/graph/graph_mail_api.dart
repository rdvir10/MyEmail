import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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
  const GraphMailApi({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _http = httpClient;

  final Future<String> Function({bool force}) accessToken;
  final http.Client? _http;
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
      'id,subject,from,toRecipients,receivedDateTime,isRead,flag,'
      'hasAttachments,bodyPreview,internetMessageId,conversationId';

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
    // One request, not one per name. Six at once was a burst, and a burst is
    // what Graph throttles hardest — adding an account could fail outright
    // with a 429 before anything had loaded.
    final json = await _post(Uri.parse('$base/\$batch'), {
      'requests': [
        for (final name in wellKnownNames)
          {
            'id': name,
            'method': 'GET',
            'url': '/me/mailFolders/$name?\$select=id',
          },
      ],
    });

    final found = <String, String>{};
    final responses = json['responses'];
    if (responses is! List) return found;
    for (final entry in responses) {
      if (entry is! Map) continue;
      // A batch answers 200 even when the requests inside it did not, so each
      // one carries its own status. A 404 here is a mailbox with no Archive,
      // which is ordinary.
      if (entry['status'] != 200) continue;
      final name = entry['id'];
      final body = entry['body'];
      if (name is! String || body is! Map) continue;
      final id = body['id'];
      if (id is String && id.isNotEmpty) found[name] = id;
    }
    return found;
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
  Future<GraphBody?> body(String messageId) async {
    try {
      final json = await _get(
        Uri.parse('$base/me/messages/${_id(messageId)}').replace(
          queryParameters: {'\$select': 'body,uniqueBody,hasAttachments'},
        ),
      );
      final body = json['body'];
      if (body is! Map) return null;
      final contentType = '${body['contentType']}'.toLowerCase();
      final content = '${body['content']}';
      return GraphBody(
        html: contentType == 'html' ? content : null,
        text: contentType == 'html' ? null : content,
        hasAttachments: json['hasAttachments'] == true,
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

  /// The bytes of one attachment.
  ///
  /// `/$value` rather than the JSON with contentBytes in it: the same data
  /// without a base64 round trip through a string, which for a 20MB file is
  /// the difference between a download and an out-of-memory.
  /// The message as MIME text, which is what Graph's `$value` on a
  /// message is: the RFC 822 form, for an `.eml`.
  Future<String> mime(String messageId) async => utf8.decode(
        await _bytes(Uri.parse('$base/me/messages/${_id(messageId)}/\$value')),
        allowMalformed: true,
      );

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
    final client = _http ?? http.Client();
    try {
      final request = http.Request('GET', uri)
        ..headers['Authorization'] = 'Bearer ${await accessToken()}'
        ..followRedirects = true;
      final response =
          await http.Response.fromStream(await client.send(request));
      if (response.statusCode == 404) throw const GraphNotFound();
      if (response.statusCode >= 400) {
        throw _failureFor(response.statusCode, const {});
      }
      return response.bodyBytes;
    } finally {
      if (_http == null) client.close();
    }
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

  Future<Map<String, Object?>> _send(
    http.Request request, {
    int attempt = 0,
  }) async {
    final client = _http ?? http.Client();
    try {
      request.headers['Authorization'] = 'Bearer ${await accessToken()}';

      final http.Response response;
      try {
        response = await http.Response.fromStream(await client.send(request));
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach Microsoft. ($e)');
      }

      // Throttled, and Graph has said how long to wait. Waiting it out is the
      // whole remedy, and doing it here means nothing above this ever has to
      // know it happened.
      final wait = _retryAfter(response);
      if (wait != null && attempt < maxThrottleRetries) {
        await (sleep ?? _realSleep)(wait);
        // Awaited inside the try on purpose: returning the future would let
        // the finally below close the client out from under the retry.
        // A fresh request object too — an http.Request cannot be sent twice.
        return await _send(_copyOf(request), attempt: attempt + 1);
      }

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
    } finally {
      if (_http == null) client.close();
    }
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
  const GraphBody({this.html, this.text, this.hasAttachments = false});

  final String? html;
  final String? text;
  final bool hasAttachments;
}

int _int(Object? value) => value is int ? value : 0;
