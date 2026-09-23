import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:http/http.dart' as http;

import '../../domain/account.dart';
import '../../domain/draft.dart';
import '../mail_engine.dart';
import 'smtp_sender.dart' show buildMimeMessage;

/// Sending through Microsoft Graph instead of SMTP.
///
/// SMTP submission cannot be relied on for a Microsoft account. Microsoft
/// disables it for every tenant by default and tells administrators to use
/// Graph; a tenant with security defaults switched on blocks it at the tenant
/// level whatever the per-mailbox setting says, and a personal Outlook.com
/// mailbox can refuse it with no setting to change at all. None of that
/// applies to Graph, which is the route Microsoft supports and is not going to
/// withdraw.
///
/// The message goes up as MIME rather than as Graph's own JSON shape. That is
/// deliberate: the app already builds a MIME message for Gmail, complete with
/// the multipart body, the attachments and the In-Reply-To and References
/// headers that keep a reply in its thread. Rebuilding all of that as Graph
/// JSON would be a second implementation of the same thing, differing from
/// the first in ways nobody would notice until a threaded reply broke.
///
/// Graph files the message in Sent Items itself, so nothing appends a copy.
class GraphSender {
  const GraphSender({
    required this.accessToken,
    http.Client? httpClient,
    this.maxMimeBytes = defaultMaxMimeBytes,
  }) : _http = httpClient;

  /// Fetched per send, and for the Graph resource specifically: an access
  /// token is issued for one resource, and an IMAP one is refused here.
  final Future<String> Function({bool force}) accessToken;

  final http.Client? _http;

  static const base = 'https://graph.microsoft.com/v1.0';

  static final sendMailUri = Uri.parse('$base/me/sendMail');
  static final messagesUri = Uri.parse('$base/me/messages');

  /// Graph accepts a request body up to 4 MB, and base64 adds about a third,
  /// so anything posted whole has to stay under roughly 3 MB. Past that the
  /// message goes up in pieces instead; see [_sendInPieces].
  static const defaultMaxMimeBytes = 3 * 1024 * 1024;

  /// What one PUT of an upload session carries.
  ///
  /// Microsoft requires every chunk but the last to be a multiple of 320 KiB.
  /// Ten of them is a little over 3 MB, which leaves room under the 4 MB
  /// request ceiling without making the round trips any smaller than they
  /// need to be.
  static const uploadChunkBytes = 327680 * 10;

  /// Beyond this nothing is attempted. Exchange Online refuses a message of
  /// about 35 MB by default and 150 MB at the very most, and spending ten
  /// minutes uploading something that will be refused at the end is worse
  /// than saying so at the start.
  static const maxTotalBytes = 140 * 1024 * 1024;

  /// Lowered by tests. Building a genuinely oversized MIME message costs
  /// minutes of encoding, which is time spent proving that enough_mail can
  /// encode three megabytes rather than that this check works.
  final int maxMimeBytes;

  /// Send a message that is already built.
  ///
  /// Only for a message small enough to post whole. Everything the app sends
  /// goes through [sendDraft], which knows what to do when it is not.
  Future<void> send(em.MimeMessage message) async {
    final mime = utf8.encode(message.renderMessage());
    if (mime.length > maxMimeBytes) {
      throw SendFailed(
        'This message is too large to post in one request: '
        '${_mb(mime.length)} against ${_mb(maxMimeBytes)}.',
      );
    }
    final client = _http ?? http.Client();
    try {
      await _postWholeMessage(client, mime);
    } finally {
      if (_http == null) client.close();
    }
  }

  /// Send a draft, whatever it weighs.
  ///
  /// Small messages go up whole, in one request, exactly as they always
  /// have: that is one round trip and it is what almost every message is.
  ///
  /// A large one cannot. Graph takes a request body of 4 MB and base64 adds
  /// a third, so a message with a 24 MB attachment on it has to be assembled
  /// on the server instead: the words go up as a draft, each file is added
  /// to that draft — in chunks, through an upload session, where the file is
  /// itself too big to post — and then the draft is sent. It is the route
  /// Microsoft documents for exactly this, and until now the app simply said
  /// it could not do it.
  Future<void> sendDraft({
    required Draft draft,
    required Account account,
  }) async {
    final whole = utf8.encode(
      buildMimeMessage(draft: draft, account: account).renderMessage(),
    );
    final client = _http ?? http.Client();
    try {
      if (whole.length <= maxMimeBytes) {
        return await _postWholeMessage(client, whole);
      }
      await _sendInPieces(client, draft: draft, account: account);
    } finally {
      if (_http == null) client.close();
    }
  }

  Future<void> _postWholeMessage(http.Client client, List<int> mime) async {
    final http.Response response;
    try {
      response = await client.post(
        sendMailUri,
        headers: {
          'Authorization': 'Bearer ${await accessToken()}',
          // text/plain is what tells Graph the body is base64 MIME rather
          // than its own JSON. application/json here is rejected as
          // malformed JSON, which reads as a bug in the message.
          'Content-Type': 'text/plain',
        },
        body: base64Encode(mime),
      );
    } on Exception catch (e) {
      throw ConnectionFailed('Could not reach Microsoft to send. ($e)');
    }

    // 202 means accepted for delivery, not delivered. Graph returns no body.
    if (response.statusCode == 202) return;
    throw _failureFor(response);
  }

  /// The words first, then the files, then send it.
  ///
  /// A failure part way through leaves the draft on the server, in Drafts,
  /// with whatever went up before it stopped. That is deliberate: it is the
  /// person's message, and deleting it to keep the mailbox tidy would throw
  /// away what they wrote. The error says where it is.
  Future<void> _sendInPieces(
    http.Client client, {
    required Draft draft,
    required Account account,
  }) async {
    final total = draft.attachments.fold<int>(0, (n, a) => n + a.size);
    if (total > maxTotalBytes) {
      throw SendFailed(
        'That is ${_mb(total)} of attachments. Microsoft will not accept a '
        'message anywhere near that size, so nothing was sent. Send the '
        'files a few at a time, or share them from cloud storage instead.',
      );
    }

    final words = utf8.encode(
      buildMimeMessage(
        draft: draft.copyWith(attachments: const []),
        account: account,
      ).renderMessage(),
    );
    if (words.length > maxMimeBytes) {
      // Not the attachments: the message itself. A pasted screenshot inside
      // the body is the usual cause, and it cannot be split off the way a
      // file can.
      throw SendFailed(
        'The message itself is ${_mb(words.length)} before any attachments, '
        'which is more than Microsoft accepts in one piece. Pictures pasted '
        'into the message are the usual cause; attaching them instead works.',
      );
    }

    final messageId = await _createDraft(client, words);
    for (final attachment in draft.attachments) {
      if (attachment.size <= maxMimeBytes) {
        await _attachSmall(client, messageId, attachment);
      } else {
        await _attachLarge(client, messageId, attachment);
      }
    }
    await _sendDraftOnServer(client, messageId);
  }

  Future<String> _createDraft(http.Client client, List<int> mime) async {
    final response = await _guarded(() async => client.post(
          messagesUri,
          headers: {
            'Authorization': 'Bearer ${await accessToken()}',
            'Content-Type': 'text/plain',
          },
          body: base64Encode(mime),
        ));
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw _failureFor(response);
    }
    final body = jsonDecode(response.body);
    final id = body is Map ? body['id'] : null;
    if (id is! String || id.isEmpty) {
      throw const SendFailed(
        'Microsoft accepted the message but did not say where it put it, so '
        'it was not sent. Nothing has gone out.',
      );
    }
    return id;
  }

  Future<void> _attachSmall(
    http.Client client,
    String messageId,
    DraftAttachment attachment,
  ) async {
    final response = await _guarded(() async => client.post(
          Uri.parse('$base/me/messages/${Uri.encodeComponent(messageId)}'
              '/attachments'),
          headers: {
            'Authorization': 'Bearer ${await accessToken()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            '@odata.type': '#microsoft.graph.fileAttachment',
            'name': attachment.fileName,
            'contentType': attachment.mimeType,
            'contentBytes': base64Encode(attachment.bytes),
            if (attachment.contentId != null) ...{
              'isInline': true,
              'contentId': attachment.contentId,
            },
          }),
        ));
    if (response.statusCode == 201 || response.statusCode == 200) return;
    throw _failureFor(response, attachment: attachment.fileName);
  }

  /// A file too big to post: ask for a session and put it up in chunks.
  ///
  /// The upload URL carries its own authorisation, and Microsoft's own
  /// guidance is not to send a bearer token with the chunks. Doing so is
  /// rejected, which is a confusing way to fail on the last leg.
  Future<void> _attachLarge(
    http.Client client,
    String messageId,
    DraftAttachment attachment,
  ) async {
    final opened = await _guarded(() async => client.post(
          Uri.parse('$base/me/messages/${Uri.encodeComponent(messageId)}'
              '/attachments/createUploadSession'),
          headers: {
            'Authorization': 'Bearer ${await accessToken()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'AttachmentItem': {
              'attachmentType': 'file',
              'name': attachment.fileName,
              'size': attachment.size,
              'contentType': attachment.mimeType,
              if (attachment.contentId != null) ...{
                'isInline': true,
                'contentId': attachment.contentId,
              },
            },
          }),
        ));
    if (opened.statusCode != 200 && opened.statusCode != 201) {
      throw _failureFor(opened, attachment: attachment.fileName);
    }
    final body = jsonDecode(opened.body);
    final url = body is Map ? body['uploadUrl'] : null;
    if (url is! String || url.isEmpty) {
      throw SendFailed(
        'Microsoft would not open an upload for ${attachment.fileName}. '
        'The message is in Drafts; nothing has gone out.',
      );
    }

    final target = Uri.parse(url);
    final bytes = attachment.bytes;
    for (var start = 0; start < bytes.length; start += uploadChunkBytes) {
      final end = (start + uploadChunkBytes < bytes.length)
          ? start + uploadChunkBytes
          : bytes.length;
      final response = await _guarded(() async {
        final request = http.Request('PUT', target)
          ..headers['Content-Length'] = '${end - start}'
          ..headers['Content-Range'] =
              'bytes $start-${end - 1}/${bytes.length}'
          ..bodyBytes = bytes.sublist(start, end);
        return http.Response.fromStream(await client.send(request));
      });
      // 200 and 202 accept a chunk and ask for the next; 201 is the last one
      // landing, and Graph sometimes answers the final chunk with 200.
      if (response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 202) {
        continue;
      }
      throw _failureFor(response, attachment: attachment.fileName);
    }
  }

  Future<void> _sendDraftOnServer(
    http.Client client,
    String messageId,
  ) async {
    final response = await _guarded(() async => client.post(
          Uri.parse(
            '$base/me/messages/${Uri.encodeComponent(messageId)}/send',
          ),
          headers: {'Authorization': 'Bearer ${await accessToken()}'},
        ));
    if (response.statusCode == 202 || response.statusCode == 200) return;
    throw _failureFor(response);
  }

  /// A network failure reads as a network failure rather than as a refusal.
  Future<http.Response> _guarded(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request();
    } on Exception catch (e) {
      throw ConnectionFailed('Could not reach Microsoft to send. ($e)');
    }
  }

  static Object _failureFor(http.Response response, {String? attachment}) {
    final because = _refusalMessage(response);
    if (response.statusCode == 401 || response.statusCode == 403) {
      return AuthenticationFailed(because);
    }
    return SendFailed(
      attachment == null ? because : 'Sending $attachment failed. $because',
    );
  }

  /// Graph puts a code and a message in a JSON envelope. The code is the part
  /// worth showing; the message is often a sentence of internals.
  static String _refusalMessage(http.Response response) {
    String? code;
    String? message;
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is Map) {
        final error = body['error'] as Map;
        code = error['code'] as String?;
        message = error['message'] as String?;
      }
    } on FormatException {
      // Not JSON. The status code is all there is.
    }

    if (code == 'ErrorAccessDenied' || response.statusCode == 403) {
      return 'Microsoft would not let the app send as this account. If it is '
          'a work or school account, an administrator may need to approve the '
          'app for your organisation.';
    }
    if (code == 'InvalidAuthenticationToken' || response.statusCode == 401) {
      return 'The sign-in for this account is no longer accepted for sending. '
          'Open Settings, Accounts and sign in again.';
    }
    if (code == 'ErrorMimeContentInvalidBase64String') {
      // Ours to fix, not the user's, so it says so rather than implying they
      // typed something wrong.
      return 'The app built a message Microsoft could not read. Nothing was '
          'sent.';
    }
    if (response.statusCode == 429) {
      return 'Microsoft is rate limiting this account. Wait a minute and try '
          'again.';
    }
    return 'Microsoft would not accept the message '
        '(${code ?? 'HTTP ${response.statusCode}'})'
        '${message == null ? '' : ': $message'}';
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
