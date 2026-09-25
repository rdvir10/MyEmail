import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../domain/meeting.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../mail_engine.dart';

/// A thin client over the Google Calendar API: one call, to put a meeting
/// on the account's calendar with its attendees invited, and a Meet link
/// on it when it is held online.
///
/// For a Gmail account signed in with Google, whose one token carries the
/// calendar beside the mail. Google sends the invitations itself when asked
/// to, and keeps the answers on the event, so nothing here tracks a reply.
class GoogleCalendarApi {
  GoogleCalendarApi({required this.accessToken, http.Client? httpClient})
      : _given = httpClient;

  /// The account's token. Asked for per request, because a refused one is
  /// asked for again with `force`.
  final Future<String> Function({bool force}) accessToken;

  /// A client handed in, which belongs to whoever handed it in.
  final http.Client? _given;

  /// One made here, and closed by [close].
  http.Client? _own;

  http.Client get _client => _given ?? (_own ??= http.Client());

  static const base = 'https://www.googleapis.com/calendar/v3';

  /// The account's own calendar. `sendUpdates=all` is what makes Google
  /// send the invitations; without it the event is created quietly and
  /// nobody in it is told.
  static final eventsUri =
      Uri.parse('$base/calendars/primary/events?sendUpdates=all');

  /// Create the event, invitations and all.
  ///
  /// A meeting held online asks for a Meet link with it. The ask travels in
  /// the event, and `conferenceDataVersion=1` on the request is what makes
  /// the API read it and answer with the link; without it the ask is
  /// dropped without a word.
  Future<CreatedMeeting> createEvent(MeetingDraft meeting) async {
    final uri = meeting.isOnline
        ? eventsUri.replace(queryParameters: {
            ...eventsUri.queryParameters,
            'conferenceDataVersion': '1',
          })
        : eventsUri;
    // Built once: a try sent again after a refused token asks for the same
    // link, and Google makes one link for one ask.
    final body = jsonEncode(eventJson(meeting));
    final response = await _authorised(
      () => http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    final json = _jsonOf(response);
    final id = json['id'];
    return CreatedMeeting(
      id: id is String && id.isNotEmpty ? id : null,
      joinUrl: _joinUrlOf(json),
    );
  }

  /// The event as Google takes it.
  ///
  /// A timed meeting is a wall-clock time with the zone named beside it,
  /// which the API accepts in place of an offset. A whole day is dates, and
  /// ends on the day after the last: Google counts the end as exclusive.
  /// Held online, the event carries the ask for a Meet link, under a
  /// request id that makes the ask one ask however often it is sent.
  static Map<String, Object?> eventJson(MeetingDraft meeting) {
    final sent = meeting.asSent;
    final location = meeting.location.trim();
    return {
      'summary': meeting.title.trim(),
      if (meeting.notes.isNotEmpty) 'description': meeting.notes,
      if (location.isNotEmpty) 'location': location,
      'start': meeting.allDay
          ? {'date': _date(sent.start)}
          : {'dateTime': _stamp(sent.start), 'timeZone': sent.timeZone},
      'end': meeting.allDay
          ? {'date': _date(dayAfter(sent.end))}
          : {'dateTime': _stamp(sent.end), 'timeZone': sent.timeZone},
      'attendees': [
        for (final a in meeting.attendees)
          {
            'email': a.email,
            if (a.name?.trim().isNotEmpty ?? false)
              'displayName': a.name!.trim(),
          },
      ],
      if (meeting.isOnline)
        'conferenceData': {
          'createRequest': {
            'requestId': _requestId(),
            'conferenceSolutionKey': {'type': 'hangoutsMeet'},
          },
        },
    };
  }

  /// Let go of the connection. Only one made here: a client handed in is
  /// closed by its owner.
  void close() {
    _own?.close();
    _own = null;
  }

  // --- plumbing --------------------------------------------------------------

  /// An id for one ask for a link. Random, so two meetings made in a row
  /// are two links: Google answers a repeated id with the link it made the
  /// first time.
  static String _requestId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// The link to join, from the conference Google made: the entry point
  /// that is the video call, not the phone number that may sit beside it.
  static String? _joinUrlOf(Map<String, Object?> json) {
    final conference = json['conferenceData'];
    if (conference is! Map) return null;
    final points = conference['entryPoints'];
    if (points is! List) return null;
    for (final point in points) {
      if (point is! Map || point['entryPointType'] != 'video') continue;
      final uri = point['uri'];
      if (uri is String && uri.isNotEmpty) return uri;
    }
    return null;
  }

  /// With the account's token, and once more with a freshly refreshed one
  /// if Google turns the first away, as the Graph calls do: a token can
  /// look good here and not be. [build] is called per try because a request
  /// cannot be sent twice. A refresh that could not reach Google reads as
  /// what it is, no connection, rather than as a refusal.
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
  /// Google puts a status, a message and a list of reasons in its envelope,
  /// and a 403 is two different things there: the token not covering the
  /// calendar, which a sign-in fixes, and a quota run out, which waiting
  /// does. The reason tells them apart.
  static Exception _failureFor(http.Response response) {
    final status = response.statusCode;
    String? detail;
    var reason = '';
    final error = _jsonOf(response)['error'];
    if (error is Map) {
      detail = error['message'] as String?;
      final errors = error['errors'];
      if (errors is List && errors.isNotEmpty && errors.first is Map) {
        reason = '${(errors.first as Map)['reason']}'.toLowerCase();
      }
    }

    if (status == 401) {
      return const AuthenticationFailed(
        'The sign-in for this account is no longer accepted. Open Settings, '
        'Accounts and sign in again.',
      );
    }
    final throttled = status == 429 ||
        reason.contains('ratelimit') ||
        reason.contains('quota');
    if (throttled) {
      return const ConnectionFailed(
        'Google is rate limiting this account. Try again shortly.',
      );
    }
    if (status == 403) {
      return const AuthenticationFailed(
        "Google would not let the app use this account's calendar. Open "
        'Settings, Accounts and sign in again to allow it.',
      );
    }
    if (status >= 500) {
      return ConnectionFailed(
        'Google is having trouble (HTTP $status). Try again shortly.',
      );
    }
    // Google's own sentence, kept: it is what says which field it refused.
    return ConnectionFailed(
      'Google refused the meeting (HTTP $status)'
      '${detail == null || detail.isEmpty ? '' : ': $detail'}',
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _date(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  /// A wall-clock time in RFC 3339's shape with no offset: the zone travels
  /// beside it.
  static String _stamp(DateTime t) =>
      '${_date(t)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}
