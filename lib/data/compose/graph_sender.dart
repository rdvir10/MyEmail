import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:http/http.dart' as http;

import '../../domain/draft.dart';
import '../mail_engine.dart';

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

  static final sendMailUri =
      Uri.parse('https://graph.microsoft.com/v1.0/me/sendMail');

  /// Graph accepts a request body up to 4 MB, and base64 adds about a third,
  /// so the MIME itself has to stay under roughly 3 MB. Past that the API
  /// wants an upload session, which is a different and much longer path.
  /// Checked here so an oversized attachment fails with something that names
  /// the problem rather than with a bare 413.
  static const defaultMaxMimeBytes = 3 * 1024 * 1024;

  /// Lowered by tests. Building a genuinely oversized MIME message costs
  /// minutes of encoding, which is time spent proving that enough_mail can
  /// encode three megabytes rather than that this check works.
  final int maxMimeBytes;

  Future<void> send(em.MimeMessage message) async {
    final mime = utf8.encode(message.renderMessage());
    if (mime.length > maxMimeBytes) {
      throw SendFailed(
        'This message is too large to send: ${_mb(mime.length)} against a '
        'limit of ${_mb(maxMimeBytes)}. Microsoft needs a different upload '
        'route above that, which this app does not do yet. Try again with '
        'smaller attachments.',
      );
    }

    final client = _http ?? http.Client();
    try {
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

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AuthenticationFailed(_refusalMessage(response));
      }
      throw SendFailed(_refusalMessage(response));
    } finally {
      if (_http == null) client.close();
    }
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
