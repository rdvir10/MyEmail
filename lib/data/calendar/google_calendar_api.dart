import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/meeting.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../mail_engine.dart';

/// A thin client over the Google Calendar API: one call, to put a meeting
/// on the account's calendar with its attendees invited, and a Meet link
/// on it when it is held online; and three that make the Meet meeting
/// ahead of Send and send it later ([createShell], [sendShell],
/// [deleteShell]).
///
/// For a Gmail account signed in with Google, whose one token carries the
/// calendar beside the mail. Google sends the invitations itself when asked
/// to, and keeps the answers on the event, so nothing here tracks a reply.
class GoogleCalendarApi {
  GoogleCalendarApi({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _given = httpClient;

  /// Overridden by tests, which must not really wait for a Meet link.
  final Future<void> Function(Duration)? sleep;

  /// How long a Meet link Google is still making is waited for, a second
  /// at a time.
  static const maxMeetWaits = 10;

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

  /// Make the meeting's Meet meeting now, on an event with nobody on it
  /// and nobody told, so its invite text can be shown before Send; see
  /// [PreparedMeeting].
  ///
  /// Google may answer before the link is made; it is waited for. Null,
  /// with the event deleted again, where no link came: Send then asks for
  /// one as it always did.
  Future<PreparedMeeting?> createShell(MeetingDraft meeting) async {
    final kind = meeting.online;
    if (kind == null) {
      throw ArgumentError('A meeting held in the room alone has no link.');
    }
    final uri = _eventsAt(null, {
      'sendUpdates': 'none',
      'conferenceDataVersion': '1',
    });
    final body = jsonEncode({
      ...eventJson(meeting.shell),
      // Not a meeting yet: no reminder of it, and not shown as busy, while
      // it is being written. Send turns both on.
      'reminders': {'useDefault': false},
      'transparency': 'transparent',
    });
    final response = await _authorised(
      () => http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    var json = _jsonOf(response);
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    // The event is there now. A failure while the link is waited for
    // deletes it before saying so; one that cannot be deleted either is
    // handed back to be put on the ledger, or it would stay for good.
    final left = PreparedMeeting(
      accountId: meeting.accountId,
      kind: kind,
      eventId: id,
      joinUrl: '',
      inviteText: '',
    );
    try {
      for (var wait = 0; wait < maxMeetWaits && _pending(json); wait++) {
        await (sleep ?? _realSleep)(const Duration(seconds: 1));
        json = await _event(id) ?? const {};
      }
    } catch (e) {
      if (!await deleteShell(id)) throw PreparedMeetingLeft(left, e);
      rethrow;
    }
    final joinUrl = _joinUrlOf(json);
    if (joinUrl == null) {
      if (!await deleteShell(id)) {
        throw PreparedMeetingLeft(left, 'no Meet link came');
      }
      return null;
    }
    return PreparedMeeting(
      accountId: meeting.accountId,
      kind: kind,
      eventId: id,
      joinUrl: joinUrl,
      inviteText: inviteTextOf(json['conferenceData']),
    );
  }

  /// Send a meeting made by [createShell]: everything as it now stands,
  /// the attendees with it, and Google told to invite them. The conference
  /// is left as it is, and so is the description: Google adds the joining
  /// block to every invitation itself, and one in the notes too would show
  /// twice. [PreparedMeetingLost] where the event was deleted meanwhile.
  Future<CreatedMeeting> sendShell(
    PreparedMeeting prepared,
    MeetingDraft meeting,
  ) async {
    final id = prepared.eventId;
    if (id == null) {
      throw const PreparedMeetingLost('nothing was made ahead of Send');
    }
    // Looked at first: Google keeps a deleted event, marked cancelled, and
    // a patch to it answers as though nothing were wrong. Invitations to a
    // meeting that is not there must not go.
    final current = await _event(id);
    if (current == null ||
        current['status'] == 'cancelled' ||
        _joinUrlOf(current) == null) {
      throw const PreparedMeetingLost('the event was deleted');
    }
    final fields = eventJson(meeting)..remove('conferenceData');
    // A meeting now: reminded of as the calendar reminds, and busy.
    fields['reminders'] = {'useDefault': true};
    fields['transparency'] = 'opaque';
    // Emptied as well as filled: the event had none, but a patch leaves out
    // only what it is not given.
    fields['description'] = meeting.notes;
    fields['location'] = meeting.location.trim();
    // A patch merges into what the event has, and All day may have changed
    // since it was made: the other way of giving a time is emptied, or the
    // event holds a date and a time at once and Google refuses it.
    for (final key in const ['start', 'end']) {
      fields[key] = meeting.allDay
          ? {...fields[key] as Map, 'dateTime': null, 'timeZone': null}
          : {...fields[key] as Map, 'date': null};
    }
    final body = jsonEncode(fields);
    final response = await _authorised(
      () => http.Request(
        'PATCH',
        _eventsAt(id, {'sendUpdates': 'all', 'conferenceDataVersion': '1'}),
      )
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode == 404 || response.statusCode == 410) {
      throw const PreparedMeetingLost('the event was deleted');
    }
    if (response.statusCode >= 400) throw _failureFor(response);
    return CreatedMeeting(
      id: id,
      joinUrl: _joinUrlOf(_jsonOf(response)) ?? prepared.joinUrl,
    );
  }

  /// Delete an event [createShell] made, telling nobody, provided nobody is
  /// on it: one with attendees was sent after all. Never throws. Its Meet
  /// code goes unused and lapses on its own. False where it could not be
  /// done now; see `MailEngine.discardPreparedMeeting`.
  Future<bool> deleteShell(String id) async {
    try {
      final event = await _event(id);
      if (event == null) return true;
      final attendees = event['attendees'];
      if (attendees is List && attendees.isNotEmpty) return true;
      final response = await _authorised(
        () => http.Request('DELETE', _eventsAt(id, {'sendUpdates': 'none'})),
      );
      final status = response.statusCode;
      if (status >= 400 && status != 404 && status != 410) {
        throw _failureFor(response);
      }
      return true;
    } catch (e) {
      debugPrint('[myemail] could not delete the meeting made ahead: $e');
      return false;
    }
  }

  /// The joining block of a Google invitation, as Google's own email writes
  /// it, from the conference Google made: the Meet link, and where the
  /// organiser's account has dial-in, the first number, its PIN and the
  /// page of the others. A personal Gmail account has only the link.
  static String inviteTextOf(Object? conference) {
    final points = conference is Map ? conference['entryPoints'] : null;
    Map? of(String type) => points is List
        ? points.whereType<Map>().where((p) => p['entryPointType'] == type)
            .firstOrNull
        : null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    final video = of('video');
    final phone = of('phone');
    final more = of('more');
    final lines = <String>[];
    final videoUri = text(video?['uri']);
    if (videoUri != null) lines.addAll(['Join with Google Meet', videoUri]);
    final number = text(phone?['label']) ??
        text(phone?['uri'])?.replaceFirst(RegExp('^tel:'), '');
    if (number != null) {
      final region = text(phone?['regionCode']);
      final pin = text(phone?['pin']);
      lines.addAll([
        if (lines.isNotEmpty) '',
        'Join by phone',
        region == null ? number : '($region) $number',
        if (pin != null) 'PIN: $pin',
      ]);
      final others = text(more?['uri']);
      if (others != null) lines.addAll(['', 'More phone numbers', others]);
    }
    return lines.join('\n');
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

  /// The account's events, or one of them, with [query]. Ids Google makes
  /// are letters and digits, but one is encoded all the same.
  static Uri _eventsAt(String? id, Map<String, String> query) => Uri.parse(
        '$base/calendars/primary/events'
        '${id == null ? '' : '/${Uri.encodeComponent(id)}'}',
      ).replace(queryParameters: query);

  /// The event as it stands, or null where it is gone.
  Future<Map<String, Object?>?> _event(String id) async {
    final response = await _authorised(
      () => http.Request('GET', _eventsAt(id, {'conferenceDataVersion': '1'})),
    );
    if (response.statusCode == 404 || response.statusCode == 410) return null;
    if (response.statusCode >= 400) throw _failureFor(response);
    return _jsonOf(response);
  }

  /// Whether Google is still making the conference: its answer to the ask
  /// sits under the ask, not beside the entry points.
  static bool _pending(Map<String, Object?> json) {
    final conference = json['conferenceData'];
    final ask = conference is Map ? conference['createRequest'] : null;
    final status = ask is Map ? ask['status'] : null;
    return status is Map && status['statusCode'] == 'pending';
  }

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

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
