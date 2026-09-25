import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/microsoft_oauth.dart'
    show SignInNeedsConsent, SignInUnreachable;
import '../mail_engine.dart';

/// A thin client over the Google Meet REST API: one call, to make a meeting
/// space with a link to join it, and nothing else.
///
/// For a meeting that is held on Google Meet but lives on some other
/// calendar: a Microsoft account's, whose Outlook invitation carries the
/// link. A Meet link made through Google Calendar comes with an event on
/// the Google calendar, which such a meeting must not have twice; a space
/// made here comes with nothing but the link. Its host is the Google
/// account whose token this is handed, which is who admits the others.
class GoogleMeetApi {
  GoogleMeetApi({required this.accessToken, http.Client? httpClient})
      : _given = httpClient;

  /// The Google account's token for Meet. Asked for per request, because a
  /// refused one is asked for again with `force`.
  final Future<String> Function({bool force}) accessToken;

  /// A client handed in, which belongs to whoever handed it in.
  final http.Client? _given;

  /// One made here, and closed by [close].
  http.Client? _own;

  http.Client get _client => _given ?? (_own ??= http.Client());

  /// Meeting spaces. Creating one needs no body: Google chooses the code,
  /// and the space takes the account's own settings for who may join.
  static final spacesUri = Uri.parse('https://meet.googleapis.com/v2/spaces');

  /// Make a space and answer with the link to join it.
  Future<String> createSpace() async {
    final response = await _authorised(
      () => http.Request('POST', spacesUri)
        ..headers['Content-Type'] = 'application/json'
        ..body = '{}',
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    final uri = _jsonOf(response)['meetingUri'];
    if (uri is! String || uri.isEmpty) {
      throw const ConnectionFailed(
        'Google made the Meet meeting but sent no link to it.',
      );
    }
    return uri;
  }

  /// Let go of the connection. Only one made here: a client handed in is
  /// closed by its owner.
  void close() {
    _own?.close();
    _own = null;
  }

  // --- plumbing --------------------------------------------------------------

  /// With the account's token, and once more with a freshly refreshed one
  /// if Google turns the first away, as the calendar calls do. [build] is
  /// called per try because a request cannot be sent twice. A refresh that
  /// could not reach Google reads as what it is, no connection.
  Future<http.Response> _authorised(http.Request Function() build) async {
    for (var forced = false;; forced = true) {
      final String token;
      try {
        token = await accessToken(force: forced);
      } on SignInUnreachable catch (e) {
        throw ConnectionFailed(e.message);
      }
      final request = build()..headers['Authorization'] = 'Bearer $token';
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request));
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach Google. ($e)');
      }
      if (response.statusCode != 401 || forced) return response;
    }
  }

  /// The response's JSON, or nothing if it has none.
  static Map<String, Object?> _jsonOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON. The status is all there is.
    }
    return const {};
  }

  /// Google's refusal as the failure the app shows.
  ///
  /// The Meet API answers in Google's newer envelope: a status word and,
  /// under `details`, a reason. Three refusals come as 403 and mean
  /// different things. The API not switched on in the app's Google Cloud
  /// project is a setting to change there, and the sentence says which. A
  /// token that does not cover Meet is a sign-in from before the app asked
  /// for it, which a sign-in again fixes. A quota run out is waited out.
  static Exception _failureFor(http.Response response) {
    final status = response.statusCode;
    String? detail;
    var word = '';
    final reasons = <String>{};
    final error = _jsonOf(response)['error'];
    if (error is Map) {
      detail = error['message'] as String?;
      word = '${error['status'] ?? ''}'.toUpperCase();
      final details = error['details'];
      if (details is List) {
        for (final d in details) {
          if (d is Map && d['reason'] is String) {
            reasons.add((d['reason'] as String).toUpperCase());
          }
        }
      }
    }

    if (status == 401) {
      return const AuthenticationFailed(
        'The Google sign-in that makes Meet links is no longer accepted. '
        'Open Settings, Accounts and sign in to the Gmail account again.',
      );
    }
    if (status == 429 || word == 'RESOURCE_EXHAUSTED') {
      return const ConnectionFailed(
        'Google is rate limiting Meet for this account. Try again shortly.',
      );
    }
    if (status == 403) {
      if (reasons.contains('SERVICE_DISABLED') ||
          (detail?.contains('has not been used') ?? false) ||
          (detail?.contains('is disabled') ?? false)) {
        return const ConnectionFailed(
          'The Google Meet API is switched off in the app\'s Google Cloud '
          'project. Open APIs & Services, Library, Google Meet API and '
          'enable it, then try again.',
        );
      }
      return const SignInNeedsConsent(
        'This Google account has not allowed the app to make Meet links. '
        'Sign in with Google again to allow it; nothing cached is lost.',
      );
    }
    if (status >= 500) {
      return ConnectionFailed(
        'Google is having trouble (HTTP $status). Try again shortly.',
      );
    }
    // Google's own sentence, kept: it is what says what was refused.
    return ConnectionFailed(
      'Google refused the Meet link (HTTP $status)'
      '${detail == null || detail.isEmpty ? '' : ': $detail'}',
    );
  }
}
