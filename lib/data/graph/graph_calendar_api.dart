import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/meeting.dart';
import '../../domain/text_direction.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../imap/imap_mapping.dart' show htmlToText;
import '../mail_engine.dart';

/// A thin client over the Microsoft Graph calendar: a call to put a meeting
/// on the account's calendar with its attendees invited, one to ask where
/// that calendar holds a meeting online, and the three that make a Teams
/// meeting ahead of Send and send it later ([createShell], [sendShell],
/// [deleteShell]).
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

  /// The calendar itself, for the two properties that say where it holds
  /// a meeting online.
  static final calendarUri = Uri.parse('$base/me/calendar').replace(
    queryParameters: {
      r'$select': 'allowedOnlineMeetingProviders,defaultOnlineMeetingProvider',
    },
  );

  /// Create the event, invitations and all.
  ///
  /// [onlineMeetingProvider] is Graph's name for where the calendar holds
  /// a meeting online, as [onlineMeetings] found it, and goes with a
  /// meeting held online. Without one, Graph holds it at the calendar's
  /// default. [joinUrl] is a link made elsewhere, Google Meet's, for a
  /// meeting held there instead: the event carries it, and no Teams link
  /// is asked for.
  Future<CreatedMeeting> createEvent(
    MeetingDraft meeting, {
    String? onlineMeetingProvider,
    String? joinUrl,
  }) async {
    final body = jsonEncode(eventJson(
      meeting,
      onlineMeetingProvider: onlineMeetingProvider,
      joinUrl: joinUrl,
    ));
    final response = await _exchange(
      () => http.Request('POST', eventsUri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    final json = _jsonOf(response);
    final id = json['id'];
    final online = json['onlineMeeting'];
    final made = online is Map ? online['joinUrl'] : null;
    return CreatedMeeting(
      id: id is String && id.isNotEmpty ? id : null,
      joinUrl: joinUrl ?? (made is String && made.isNotEmpty ? made : null),
    );
  }

  /// Where the calendar holds a meeting online, or null when nowhere: what
  /// the screen's switch is labelled with, and what [createEvent] is told.
  ///
  /// Teams wherever the mailbox allows it, which every work mailbox does.
  /// Otherwise whatever the calendar defaults to, if anything: Skype, on a
  /// personal mailbox that still has it. Graph keeps both on the calendar.
  Future<GraphOnlineMeetings?> onlineMeetings() async {
    final response = await _exchange(() => http.Request('GET', calendarUri));
    if (response.statusCode >= 400) throw _failureFor(response);
    return GraphOnlineMeetings.fromCalendarJson(_jsonOf(response));
  }

  /// Make the meeting's Teams meeting now, on an event with nobody on it,
  /// so the invite text can be shown before Send; see [PreparedMeeting].
  ///
  /// Exchange writes the Teams block into the event's body as it makes the
  /// meeting, and the block is kept as it wrote it: it varies by tenant
  /// and language, and a body sent back without it, or with it rewritten,
  /// loses the meeting. Null, with the event deleted again, where the
  /// calendar did not hold it online after all or wrote no block to show:
  /// Send then asks for the meeting as it always did.
  Future<PreparedMeeting?> createShell(
    MeetingDraft meeting, {
    String? onlineMeetingProvider,
  }) async {
    final kind = meeting.online;
    if (kind == null) {
      throw ArgumentError('A meeting held in the room alone has no link.');
    }
    final body = jsonEncode({
      ...eventJson(meeting.shell, onlineMeetingProvider: onlineMeetingProvider),
      // Not a meeting yet: no reminder of it, and not shown as busy, while
      // it is being written. Send turns both on.
      'isReminderOn': false,
      'showAs': 'free',
      // One event however often the request is sent: a retry after a
      // throttle, or one whose answer was lost, is known by it.
      'transactionId': _transactionId(),
    });
    final response = await _exchange(
      () => http.Request('POST', eventsUri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    var json = _jsonOf(response);
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    // The event is there now. A failure from here deletes it before saying
    // so; one that cannot be deleted either is handed back to be put on
    // the ledger, or an event nobody knows of would stay on the calendar.
    final left = PreparedMeeting(
      accountId: meeting.accountId,
      kind: kind,
      eventId: id,
      joinUrl: '',
      inviteText: '',
    );
    if (_joinUrlIn(json) == null || _bodyIn(json) == null) {
      // Written a moment after the event, on some tenants.
      try {
        await (sleep ?? _realSleep)(const Duration(seconds: 1));
        json = await _event(id) ?? json;
      } catch (e) {
        if (!await deleteShell(id)) throw PreparedMeetingLeft(left, e);
        rethrow;
      }
    }
    final joinUrl = _joinUrlIn(json);
    final html = _bodyIn(json);
    if (json['isOnlineMeeting'] == false ||
        joinUrl == null ||
        html == null ||
        !_hasTeamsBlock(html, joinUrl)) {
      if (!await deleteShell(id)) {
        throw PreparedMeetingLeft(left, 'no Teams block came');
      }
      return null;
    }
    return PreparedMeeting(
      accountId: meeting.accountId,
      kind: kind,
      eventId: id,
      joinUrl: joinUrl,
      inviteText: inviteTextOf(html),
      bodyHtml: html,
    );
  }

  /// Send a meeting made by [createShell]: its details and the notes, above
  /// the Teams block as Exchange wrote it, then its attendees, whose
  /// arrival on it is what sends the invitations.
  ///
  /// In two steps, so an invitation never goes without its link: where the
  /// first leaves the event no longer online, nobody has been asked yet,
  /// and [PreparedMeetingLost] says so, as it does for an event deleted
  /// meanwhile. The caller makes a new meeting then.
  Future<CreatedMeeting> sendShell(
    PreparedMeeting prepared,
    MeetingDraft meeting,
  ) async {
    final id = prepared.eventId;
    final html = prepared.bodyHtml;
    if (id == null || html == null) {
      throw const PreparedMeetingLost('nothing was made ahead of Send');
    }
    final location = meeting.location.trim();
    final details = jsonEncode({
      'subject': meeting.title.trim(),
      'body': {
        'contentType': 'html',
        'content': bodyWithNotes(html, meeting.notes),
      },
      ..._times(meeting),
      'isAllDay': meeting.allDay,
      // Left out when empty, so Exchange's own for a Teams meeting stands.
      if (location.isNotEmpty) 'location': {'displayName': location},
      // A meeting now: reminded of, and busy, as one made at Send is.
      'isReminderOn': true,
      'showAs': 'busy',
    });
    final first = await _exchange(() => _patch(id, details));
    if (first.statusCode == 404) {
      throw const PreparedMeetingLost('the event was deleted');
    }
    if (first.statusCode >= 400) throw _failureFor(first);
    var json = _jsonOf(first);
    if (!json.containsKey('isOnlineMeeting')) json = await _event(id) ?? json;
    final joinUrl = _joinUrlIn(json);
    if (json['isOnlineMeeting'] == false || joinUrl == null) {
      throw const PreparedMeetingLost('the calendar dropped the Teams meeting');
    }
    if (meeting.hasAttendees) {
      final invited = jsonEncode({'attendees': _attendees(meeting)});
      final second = await _exchange(() => _patch(id, invited));
      if (second.statusCode >= 400) throw _failureFor(second);
    }
    return CreatedMeeting(id: id, joinUrl: joinUrl);
  }

  /// Delete an event [createShell] made, provided nobody is on it: one that
  /// has attendees was sent after all, and deleting it would send them a
  /// cancellation. Never throws. With nobody on it, nobody is told; the
  /// Teams meeting it had simply goes unused. False where it could not be
  /// done now; see `MailEngine.discardPreparedMeeting`.
  Future<bool> deleteShell(String id) async {
    try {
      final event = await _event(id);
      if (event == null) return true;
      final attendees = event['attendees'];
      if (attendees is List && attendees.isNotEmpty) return true;
      // For good, rather than into Deleted Items, where each one undone
      // would pile up in Outlook as a "New meeting".
      final purged = await _exchange(
        () => http.Request(
          'POST',
          Uri.parse('${_eventUri(id)}/permanentDelete'),
        ),
      );
      if (purged.statusCode < 400 || purged.statusCode == 404) return true;
      // Refused (a mailbox without it): into Deleted Items, then.
      final response = await _exchange(
        () => http.Request('DELETE', _eventUri(id)),
      );
      if (response.statusCode >= 400 && response.statusCode != 404) {
        throw _failureFor(response);
      }
      return true;
    } catch (e) {
      debugPrint('[myemail] could not delete the meeting made ahead: $e');
      return false;
    }
  }

  /// The text of a Teams block for the screen: the lines as they read,
  /// without the rows of underscores that fence it in.
  static String inviteTextOf(String html) {
    // Exchange wraps long lines of its HTML, inside the text as well: a
    // browser reads those breaks as spaces, and so does this. The block's
    // own lines are its divs and breaks.
    final text = _decodeNumeric(
      htmlToText(html.replaceAll(RegExp(r'\s+'), ' ')),
    );
    return text
        .split('\n')
        .where((line) => !RegExp(r'^[_\s]+$').hasMatch(line))
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// [html], the body Exchange wrote, with [notes] as the person wrote them
  /// at the top of it, where Outlook puts them above the Teams block.
  static String bodyWithNotes(String html, String notes) {
    final text = notes.trim();
    if (text.isEmpty) return html;
    final escaped = const HtmlEscape(HtmlEscapeMode.element)
        .convert(text)
        .replaceAll('\r\n', '\n')
        .replaceAll('\n', '<br>\n');
    final block = '<div${dirAttribute(text)}>$escaped</div>\n<br>\n';
    final open = RegExp(r'<body[^>]*>', caseSensitive: false).firstMatch(html);
    if (open == null) return '$block$html';
    return html.replaceRange(open.end, open.end, '\n$block');
  }

  /// The line a Google Meet link goes out as on a Microsoft invitation,
  /// shown before Send as it is sent.
  static String meetLine(String joinUrl) => 'Join with Google Meet: $joinUrl';

  /// The event as Graph takes it.
  ///
  /// The times are wall-clock values with the zone named beside them, which
  /// is Graph's own shape. A whole day ends at the next day's midnight,
  /// because Graph counts the end as exclusive and refuses one on the same
  /// day. Every attendee is required: the screen has no optional list, and
  /// Graph wants each one typed. A link made elsewhere goes where a person
  /// pasting one would put it: the body's last line, and the location
  /// where none was given, so every client shows it and Outlook's Join
  /// finds it.
  static Map<String, Object?> eventJson(
    MeetingDraft meeting, {
    String? onlineMeetingProvider,
    String? joinUrl,
  }) {
    final location = meeting.location.trim();
    final elsewhere = joinUrl != null;
    final notes = !elsewhere
        ? meeting.notes
        : meeting.notes.trim().isEmpty
            ? meetLine(joinUrl)
            : '${meeting.notes.trimRight()}\n\n${meetLine(joinUrl)}';
    return {
      'subject': meeting.title.trim(),
      'body': {'contentType': 'text', 'content': notes},
      ..._times(meeting),
      'isAllDay': meeting.allDay,
      if (location.isNotEmpty)
        'location': {'displayName': location}
      else if (elsewhere)
        'location': {'displayName': joinUrl},
      'attendees': _attendees(meeting),
      // A Teams link only when asked for, and not beside a link made
      // elsewhere. Left to Graph's default, some tenants add one to every
      // meeting.
      'isOnlineMeeting': meeting.isOnline && !elsewhere,
      if (meeting.isOnline && !elsewhere && onlineMeetingProvider != null)
        'onlineMeetingProvider': onlineMeetingProvider,
    };
  }

  /// Start and end as Graph takes them: wall-clock values with the zone
  /// beside them, and a whole day ending at the next day's midnight.
  static Map<String, Object?> _times(MeetingDraft meeting) {
    final sent = meeting.asSent;
    final end = meeting.allDay ? dayAfter(sent.end) : sent.end;
    return {
      'start': {'dateTime': _stamp(sent.start), 'timeZone': sent.timeZone},
      'end': {'dateTime': _stamp(end), 'timeZone': sent.timeZone},
    };
  }

  /// Every attendee, required: the screen has no optional list, and Graph
  /// wants each one typed.
  static List<Map<String, Object?>> _attendees(MeetingDraft meeting) => [
        for (final a in meeting.attendees)
          {
            'emailAddress': {
              'address': a.email,
              if (a.name?.trim().isNotEmpty ?? false) 'name': a.name!.trim(),
            },
            'type': 'required',
          },
      ];

  /// Graph's own key against a create sent twice: 32 random hex digits.
  static String _transactionId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// One event on the account's calendar. A Graph id can hold `/`, `+`
  /// and `=`, so it goes encoded.
  static Uri _eventUri(String id) =>
      Uri.parse('$base/me/events/${Uri.encodeComponent(id)}');

  http.Request _patch(String id, String body) =>
      http.Request('PATCH', _eventUri(id))
        ..headers['Content-Type'] = 'application/json'
        ..body = body;

  /// The event as it stands, or null where it is gone.
  Future<Map<String, Object?>?> _event(String id) async {
    final response = await _exchange(
      () => http.Request(
        'GET',
        _eventUri(id).replace(queryParameters: {
          r'$select': 'id,body,isOnlineMeeting,onlineMeeting,attendees',
        }),
      ),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) throw _failureFor(response);
    return _jsonOf(response);
  }

  static String? _joinUrlIn(Map<String, Object?> json) {
    final online = json['onlineMeeting'];
    final url = online is Map ? online['joinUrl'] : null;
    return url is String && url.isNotEmpty ? url : null;
  }

  static String? _bodyIn(Map<String, Object?> json) {
    final body = json['body'];
    final content = body is Map ? body['content'] : null;
    return content is String && content.trim().isNotEmpty ? content : null;
  }

  /// Whether Exchange's block is in [html]: the join link as the event
  /// gives it, or any Teams link, since newer blocks write a shorter one.
  static bool _hasTeamsBlock(String html, String joinUrl) =>
      html.contains(joinUrl) ||
      html.contains(joinUrl.replaceAll('&', '&amp;')) ||
      RegExp(r'https://teams\.(microsoft|live)\.com/').hasMatch(html);

  /// `&#8203;` and `&#x2019;` as the characters they are: [htmlToText]
  /// knows only the named few. Zero-width spaces, which Teams blocks carry,
  /// go altogether.
  static String _decodeNumeric(String text) => text
      .replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'),
          (m) => _char(int.tryParse(m[1]!, radix: 16)))
      .replaceAllMapped(
          RegExp(r'&#(\d+);'), (m) => _char(int.tryParse(m[1]!)))
      .replaceAll('\u200b', '');

  static String _char(int? code) =>
      code == null || code > 0x10FFFF ? '' : String.fromCharCode(code);

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

/// Where a mailbox's calendar holds a meeting online: the kind, and Graph's
/// own name for the provider, which goes back to Graph on an event held
/// there.
class GraphOnlineMeetings {
  const GraphOnlineMeetings({required this.kind, required this.provider});

  final OnlineMeetingKind kind;
  final String provider;

  /// Read from the calendar's `allowedOnlineMeetingProviders` and
  /// `defaultOnlineMeetingProvider`. Null for a calendar that holds
  /// meetings nowhere, whose default is `unknown`.
  static GraphOnlineMeetings? fromCalendarJson(Map<String, Object?> json) {
    final allowed = json['allowedOnlineMeetingProviders'];
    if (allowed is List && allowed.contains('teamsForBusiness')) {
      return const GraphOnlineMeetings(
        kind: OnlineMeetingKind.teams,
        provider: 'teamsForBusiness',
      );
    }
    final fallback = json['defaultOnlineMeetingProvider'];
    if (fallback is! String || fallback.isEmpty || fallback == 'unknown') {
      return null;
    }
    return GraphOnlineMeetings(
      kind: switch (fallback) {
        'teamsForBusiness' => OnlineMeetingKind.teams,
        'skypeForConsumer' => OnlineMeetingKind.skype,
        _ => OnlineMeetingKind.other,
      },
      provider: fallback,
    );
  }
}
