import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/meeting.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../mail_engine.dart';

/// A thin client over the Microsoft Graph calendar: one call, to put a
/// meeting on the account's calendar with its attendees invited.
///
/// Its own class rather than a method on GraphMailApi, which is the mail
/// endpoints under the mail consent. The calendar is a consent of its own,
/// and the token this is handed is the one for it (see
/// `MicrosoftOAuth.calendarScopes`); keeping the two apart keeps a mailbox
/// that was approved for mail alone reading its mail. The plumbing is
/// GraphMailApi's, in the small: a token refreshed once when Microsoft turns
/// it away, a throttle waited out, and Graph's error envelope read into the
/// failures the rest of the app shows.
class GraphCalendarApi {
  GraphCalendarApi({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _given = httpClient;

  /// The account's token for the calendar. Asked for per request, because
  /// a refused one is asked for again with `force`.
  final Future<String> Function({bool force}) accessToken;

  /// A client handed in, which belongs to whoever handed it in.
  final http.Client? _given;

  /// One made here, and closed by [close].
  http.Client? _own;

  http.Client get _client => _given ?? (_own ??= http.Client());

  /// Overridden by tests, which must not really wait out a throttle.
  final Future<void> Function(Duration)? sleep;

  /// How many times a throttled request is tried again, and the longest
  /// wait worth sitting through: the same limits as the mail calls.
  static const maxThrottleRetries = 3;
  static const maxThrottleWait = Duration(seconds: 30);

  static const base = 'https://graph.microsoft.com/v1.0';

  /// The account's own calendar. Exchange sends the invitations for an
  /// event created here, and keeps the answers on it.
  static final eventsUri = Uri.parse('$base/me/events');

  /// Create the event, invitations and all. Returns its id, or null if Graph
  /// did not say.
  Future<String?> createEvent(MeetingDraft meeting) async {
    final response = await _exchange(
      () => http.Request('POST', eventsUri)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(eventJson(meeting)),
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    final id = _jsonOf(response)['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// The event as Graph takes it.
  ///
  /// The times are wall-clock values with the zone named beside them, which
  /// is Graph's own shape. A whole day ends at the next day's midnight,
  /// because Graph counts the end as exclusive and refuses one on the same
  /// day. Every attendee is required: the screen has no optional list, and
  /// Graph wants each one typed.
  static Map<String, Object?> eventJson(MeetingDraft meeting) {
    final sent = meeting.asSent;
    final end = meeting.allDay ? dayAfter(sent.end) : sent.end;
    final location = meeting.location.trim();
    return {
      'subject': meeting.title.trim(),
      'body': {'contentType': 'text', 'content': meeting.notes},
      'start': {'dateTime': _stamp(sent.start), 'timeZone': sent.timeZone},
      'end': {'dateTime': _stamp(end), 'timeZone': sent.timeZone},
      'isAllDay': meeting.allDay,
      if (location.isNotEmpty) 'location': {'displayName': location},
      'attendees': [
        for (final a in meeting.attendees)
          {
            'emailAddress': {
              'address': a.email,
              if (a.name?.trim().isNotEmpty ?? false) 'name': a.name!.trim(),
            },
            'type': 'required',
          },
      ],
      // A Teams link is a thing the person would have asked for. Left to
      // Graph's default, some tenants add one to every meeting.
      'isOnlineMeeting': false,
    };
  }

  /// Let go of the connection. Only one made here: a client handed in is
  /// closed by its owner.
  void close() {
    _own?.close();
    _own = null;
  }

  // --- plumbing --------------------------------------------------------------

  /// Send what [build] makes, waiting out any throttling Graph asks for.
  /// [build] is called per try because a request cannot be sent twice.
  Future<http.Response> _exchange(http.Request Function() build) async {
    for (var attempt = 0;; attempt++) {
      final response = await _authorised(build);
      final wait = _retryAfter(response);
      if (wait == null || attempt >= maxThrottleRetries) return response;
      await (sleep ?? _realSleep)(wait);
    }
  }

  /// With the account's token, and once more with a freshly refreshed one
  /// if Microsoft turns the first away: a token can look good here and not
  /// be. A refresh that could not reach Microsoft reads as what it is, no
  /// connection, rather than as a refusal. A refresh Microsoft refused for
  /// want of consent is not caught: that is the screen's to answer.
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
        throw ConnectionFailed('Could not reach Microsoft. ($e)');
      }
      if (response.statusCode != 401 || forced) return response;
    }
  }

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// How long to wait before trying again, or null if trying again is not
  /// the answer: Graph sends Retry-After in seconds on a 429 and often on a
  /// 503, and past the cap sitting there is worse than saying what happened.
  static Duration? _retryAfter(http.Response response) {
    if (response.statusCode != 429 && response.statusCode != 503) return null;
    final header = response.headers['retry-after'];
    final seconds = header == null ? null : int.tryParse(header.trim());
    final wait = Duration(seconds: seconds ?? 2);
    return wait > maxThrottleWait ? null : wait;
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

  /// Graph's refusal as the failure the app shows: the same reading as the
  /// mail calls give, with the calendar's own words where they differ.
  static Exception _failureFor(http.Response response) {
    final status = response.statusCode;
    String? code;
    String? detail;
    final error = _jsonOf(response)['error'];
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
        "Microsoft would not let the app use this account's calendar. If it "
        'is a work or school account, an administrator may need to approve '
        'the app for your organisation.',
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
    // Graph's own sentence, kept: it is what says which field it refused.
    return ConnectionFailed(
      'Microsoft refused the meeting (${code ?? 'HTTP $status'})'
      '${detail == null || detail.isEmpty ? '' : ': $detail'}',
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// A wall-clock time the way Graph writes one, with no zone in it: the
  /// zone travels beside it.
  static String _stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)}T'
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}
