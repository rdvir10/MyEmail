import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/calendar_change.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/calendar_meeting.dart';
import '../../domain/mail_message.dart' show MailAddress;
import '../../domain/meeting.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../imap/imap_mapping.dart' show htmlToText;
import '../mail_engine.dart';

/// A thin client over the Google Calendar API: one call, to put a meeting
/// on the account's calendar with its attendees invited, and a Meet link
/// on it when it is held online; three that make the Meet meeting ahead of
/// Send and send it later ([createShell], [sendShell], [deleteShell]); and
/// three for a meeting a message is about: find it ([meetingFor]), take a
/// cancelled one off ([deleteEvent]), and move one to a time proposed
/// ([moveEvent]).
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
  /// dropped without a word. A meeting changed since a Send of it failed
  /// ([MeetingDraft.changedSinceFailedSend]) has the event that Send made,
  /// if it did, brought up to date.
  Future<CreatedMeeting> createEvent(MeetingDraft meeting) async {
    final uri = meeting.isOnline
        ? eventsUri.replace(queryParameters: {
            ...eventsUri.queryParameters,
            'conferenceDataVersion': '1',
          })
        : eventsUri;
    // The event's id is chosen here, so that a Send tapped again after an
    // answer that never came is refused as a duplicate rather than making
    // a second event and inviting everyone twice.
    final key = meeting.transactionId ?? MeetingDraft.newTransactionId();
    // Built once: a try sent again after a refused token asks for the same
    // link, and Google makes one link for one ask.
    final body = jsonEncode({...eventJson(meeting), 'id': key});
    final response = await _authorised(
      () => http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode == 409) {
      // Made by the Send before, invitations and all: that is the answer,
      // once it has what was changed since. One deleted since is not, and
      // the refusal stands.
      final made = await _event(key);
      if (made != null && made['status'] != 'cancelled') {
        if (meeting.changedSinceFailedSend) {
          return _bringUpToDate(key, made, meeting);
        }
        return CreatedMeeting(id: key, joinUrl: _joinUrlOf(made));
      }
    }
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
    final fields = _patchOf(meeting);
    // A meeting now: reminded of as the calendar reminds, and busy.
    fields['reminders'] = {'useDefault': true};
    fields['transparency'] = 'opaque';
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

  /// [made], the event a Send that failed made after all, given everything
  /// [meeting] has now, and everyone on it told: added, taken off, or sent
  /// the change. The Meet link it has is kept; one asked for since is made,
  /// and one no longer wanted is taken off.
  Future<CreatedMeeting> _bringUpToDate(
    String id,
    Map<String, Object?> made,
    MeetingDraft meeting,
  ) async {
    final fields = _patchOf(meeting);
    final linked = _joinUrlOf(made) != null;
    if (meeting.isOnline && !linked) {
      fields['conferenceData'] = eventJson(meeting)['conferenceData'];
    } else if (!meeting.isOnline && linked) {
      fields['conferenceData'] = null;
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
    if (response.statusCode >= 400) throw _failureFor(response);
    return CreatedMeeting(
      id: id,
      joinUrl: meeting.isOnline
          ? _joinUrlOf(_jsonOf(response)) ?? _joinUrlOf(made)
          : null,
    );
  }

  /// [meeting] as a patch to an event made already: [eventJson] less the
  /// ask for a link, which the event has or is given on its own.
  static Map<String, Object?> _patchOf(MeetingDraft meeting) {
    final fields = eventJson(meeting)..remove('conferenceData');
    // Emptied as well as filled: a patch leaves out only what it is not
    // given, and notes or a place the event had would stay.
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
    return fields;
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

  // --- meetings already on the calendar --------------------------------------

  /// The meeting [invite] is about, as this calendar has it, or null where
  /// it is not on it. One Google has as cancelled is not: Google hides it,
  /// and it is gone from every view of the calendar.
  ///
  /// Found by the invitation's UID, which Google keeps as the event's
  /// `iCalUID`. For one meeting of a series, the one set for
  /// [CalendarInvite.recurrenceStart]: a meeting of a series changed before
  /// is an event of its own, listed beside the series; any other is one of
  /// the series' instances. Never the series in its place.
  Future<CalendarMeeting?> meetingFor(
    CalendarInvite invite, {
    required String accountId,
  }) async {
    if (invite.uid.isEmpty) return null;
    final listed = await _list(_eventsAt(null, {'iCalUID': invite.uid}));
    if (invite.recurrenceId == null) {
      final one = listed.where((e) => e['recurringEventId'] == null).firstOrNull;
      return one == null ? null : meetingFromJson(one, accountId: accountId);
    }
    final at = invite.recurrenceStart;
    if (at == null) return null;
    Map<String, Object?>? found = occurrenceAt([
      for (final e in listed)
        if (e['recurringEventId'] != null)
          if (_timeOf(e['originalStartTime']) case final original?)
            (original, e),
    ], at);
    final series = listed.where((e) => e['recurrence'] is List).firstOrNull;
    final seriesId = series?['id'];
    if (found == null && seriesId is String && seriesId.isNotEmpty) {
      // The day either side: a meeting moved since is listed by when it is
      // now, and looked for by when it was set for.
      final instances = await _list(
        Uri.parse(
          '$base/calendars/primary/events/'
          '${Uri.encodeComponent(seriesId)}/instances',
        ).replace(queryParameters: {
          'timeMin': _utc(at.toUtc().subtract(const Duration(days: 2))),
          'timeMax': _utc(at.toUtc().add(const Duration(days: 2))),
        }),
      );
      found = occurrenceAt([
        for (final e in instances)
          if (_timeOf(e['originalStartTime']) case final original?)
            (original, e),
      ], at);
    }
    return found == null ? null : meetingFromJson(found, accountId: accountId);
  }

  /// Take an event off the calendar, telling nobody: the organiser of a
  /// meeting cancelled already knows. One already gone is done.
  Future<void> deleteEvent(String id) async {
    final response = await _authorised(
      () => http.Request('DELETE', _eventsAt(id, {'sendUpdates': 'none'})),
    );
    final status = response.statusCode;
    if (status >= 400 && status != 404 && status != 410) {
      throw _failureFor(response);
    }
  }

  /// Move [meeting], which this account organised, to the time [proposal]
  /// proposes, and have Google send everyone on it the new time.
  Future<void> moveEvent(
    CalendarMeeting meeting,
    CalendarInvite proposal,
  ) async {
    final body = jsonEncode(movedTimes(meeting, proposal));
    final response = await _authorised(
      () => http.Request(
        'PATCH',
        _eventsAt(meeting.eventId, {'sendUpdates': 'all'}),
      )
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// The start and end a meeting moved to [proposal]'s time is patched
  /// with, in the zone the event keeps (an instant in UTC carries its own
  /// offset). The other way of giving a time is emptied, or an event moved
  /// between a time and a whole day would hold both. Where the proposal has
  /// no end, the meeting keeps its length.
  static Map<String, Object?> movedTimes(
    CalendarMeeting meeting,
    CalendarInvite proposal,
  ) {
    final length = meeting.end?.difference(meeting.start);
    if (proposal.isAllDay) {
      final first = proposal.start;
      final after = proposal.end ??
          (length != null && length.inDays > 1
              ? DateTime(first.year, first.month, first.day + length.inDays)
              : dayAfter(first));
      return {
        'start': {'date': _date(first), 'dateTime': null, 'timeZone': null},
        'end': {'date': _date(after), 'dateTime': null, 'timeZone': null},
      };
    }
    final start = proposal.start.toUtc();
    final end = proposal.end?.toUtc() ??
        start.add(length ?? const Duration(minutes: 30));
    return {
      'start': {
        'dateTime': _utc(start),
        'timeZone': meeting.timeZone,
        'date': null,
      },
      'end': {'dateTime': _utc(end), 'timeZone': meeting.timeZone, 'date': null},
    };
  }

  /// A meeting as Google gives it; null for one with no id or no start.
  static CalendarMeeting? meetingFromJson(
    Map<String, Object?> json, {
    required String accountId,
  }) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final start = json['start'];
    final from = _timeOf(start);
    if (from == null) return null;
    final organizer = json['organizer'];
    final recurrence = json['recurrence'];
    final zone = start is Map ? start['timeZone'] : null;
    return CalendarMeeting(
      accountId: accountId,
      eventId: id,
      start: from,
      end: _timeOf(json['end']),
      isAllDay: start is Map && start['date'] is String,
      isCancelled: json['status'] == 'cancelled',
      isOrganizer: organizer is Map && organizer['self'] == true,
      isSeries: recurrence is List && recurrence.isNotEmpty,
      timeZone: zone is String && zone.isNotEmpty ? zone : null,
    );
  }

  /// A start or end as Google gives one: an instant with its offset, or a
  /// whole day's date, as that day at midnight UTC.
  static DateTime? _timeOf(Object? value) {
    if (value is! Map) return null;
    final date = value['date'];
    if (date is String) {
      final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
      if (m == null) return null;
      return DateTime.utc(
          int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    }
    final at = value['dateTime'];
    return at is String ? DateTime.tryParse(at)?.toUtc() : null;
  }

  /// When the account's own calendar is busy between [start] and [end]:
  /// every event on it but those shown as free (transparent) and those
  /// turned down. Read as a listing, which the calendar permission the app
  /// has already covers; Google's free/busy question would need another.
  Future<List<TimeSpan>> busy(DateTime start, DateTime end) async {
    final events = await _list(_eventsAt(null, {
      'timeMin': start.toUtc().toIso8601String(),
      'timeMax': end.toUtc().toIso8601String(),
      'singleEvents': 'true',
      'orderBy': 'startTime',
      'maxResults': '250',
    }));
    final busy = <TimeSpan>[];
    for (final e in events) {
      if (e['transparency'] == 'transparent') continue;
      final attendees = e['attendees'];
      final me = attendees is List
          ? attendees.whereType<Map>().where((a) => a['self'] == true).firstOrNull
          : null;
      if (me != null && me['responseStatus'] == 'declined') continue;
      final from = _busyAt(e['start']), to = _busyAt(e['end']);
      if (from == null || to == null || !to.isAfter(from)) continue;
      busy.add((start: from, end: to));
    }
    return busy;
  }

  /// Every event on the primary calendar between [start] and [end], each
  /// occurrence of a series on its own, as [accountId]'s.
  Future<List<CalendarEvent>> events(
    DateTime start,
    DateTime end, {
    required String accountId,
  }) async {
    final found = <CalendarEvent>[];
    String? token;
    for (var page = 0; page < 10; page++) {
      final response = await _authorised(() => http.Request(
            'GET',
            _eventsAt(null, {
              'timeMin': start.toUtc().toIso8601String(),
              'timeMax': end.toUtc().toIso8601String(),
              'singleEvents': 'true',
              'orderBy': 'startTime',
              'maxResults': '250',
              'pageToken': ?token,
            }),
          ));
      if (response.statusCode >= 400) throw _failureFor(response);
      final json = _jsonOf(response);
      final items = json['items'];
      for (final e in items is List ? items : const []) {
        if (e is! Map) continue;
        final event = eventFrom(e.cast<String, Object?>(), accountId);
        if (event != null) found.add(event);
      }
      final next = json['nextPageToken'];
      if (next is! String || next.isEmpty) break;
      token = next;
    }
    return found;
  }

  /// One of Google's events as a [CalendarEvent] in local time; null for
  /// one with no id or no time, or cancelled.
  static CalendarEvent? eventFrom(Map<String, Object?> json, String accountId) {
    final id = json['id'];
    if (id is! String || json['status'] == 'cancelled') return null;
    final allDay = json['start'] is Map && (json['start'] as Map)['date'] is String;
    DateTime? at(Object? value) {
      final t = _timeOf(value);
      if (t == null) return null;
      return allDay ? DateTime(t.year, t.month, t.day) : t.toLocal();
    }

    final start = at(json['start']), end = at(json['end']);
    if (start == null || end == null) return null;
    MailAddress? address(Object? v) {
      if (v is! Map) return null;
      final email = '${v['email'] ?? ''}'.trim();
      if (email.isEmpty) return null;
      final name = '${v['displayName'] ?? ''}'.trim();
      return MailAddress(email: email, name: name.isEmpty ? null : name);
    }

    EventResponse response(Object? status) => switch ('$status') {
          'accepted' => EventResponse.accepted,
          'tentative' => EventResponse.tentative,
          'declined' => EventResponse.declined,
          'needsAction' => EventResponse.notResponded,
          _ => EventResponse.none,
        };
    final attendees = json['attendees'] is List
        ? (json['attendees'] as List).whereType<Map>().toList()
        : const <Map>[];
    final organizer = json['organizer'];
    final mine = attendees.where((a) => a['self'] == true).firstOrNull;
    final isOrganizer = organizer is Map && organizer['self'] == true;
    final points = json['conferenceData'] is Map
        ? (json['conferenceData'] as Map)['entryPoints']
        : null;
    final Map? videoPoint = points is List
        ? points
            .whereType<Map>()
            .where((p) => p['entryPointType'] == 'video')
            .firstOrNull
        : null;
    final video = videoPoint?['uri'];
    final hangout = json['hangoutLink'];
    final reminders = json['reminders'];
    final overrides = reminders is Map ? reminders['overrides'] : null;
    final minutes = [
      for (final o in overrides is List ? overrides : const [])
        if (o is Map && o['minutes'] is num) (o['minutes'] as num).toInt(),
    ];
    final description = json['description'];
    var preview = description is String ? htmlToText(description).trim() : '';
    if (preview.length > 300) preview = '${preview.substring(0, 300)}…';
    return CalendarEvent(
      id: id,
      accountId: accountId,
      title: '${json['summary'] ?? ''}'.trim(),
      start: start,
      end: end.isBefore(start) ? start : end,
      allDay: allDay,
      location: '${json['location'] ?? ''}'.trim(),
      organizer: address(organizer),
      attendees: [
        for (final a in attendees)
          if (a['resource'] != true)
            if (address(a) case final who?)
              EventAttendee(
                who,
                response: a['organizer'] == true
                    ? EventResponse.organizer
                    : response(a['responseStatus']),
                optional: a['optional'] == true,
              ),
      ],
      joinUrl: video is String
          ? video
          : hangout is String
              ? hangout
              : null,
      webLink: json['htmlLink'] is String ? json['htmlLink'] as String : null,
      showAs: json['transparency'] == 'transparent'
          ? EventShowAs.free
          : mine?['responseStatus'] == 'tentative'
              ? EventShowAs.tentative
              : EventShowAs.busy,
      response: isOrganizer
          ? EventResponse.organizer
          : mine == null
              ? EventResponse.none
              : response(mine['responseStatus']),
      isOrganizer: isOrganizer,
      reminderMinutes: minutes.isEmpty
          ? null
          : minutes.reduce((a, b) => a > b ? a : b),
      preview: preview,
      seriesId: json['recurringEventId'] is String &&
              (json['recurringEventId'] as String).isNotEmpty
          ? json['recurringEventId'] as String
          : null,
    );
  }

  // --- events the calendar shows ---------------------------------------------

  /// Answer [eventId], a meeting someone else organised, as its guest: the
  /// account's own entry among the attendees given the answer and [note],
  /// everyone else's sent back as they are. [send] false answers without
  /// Google writing to the organiser, who sees it on a Google calendar all
  /// the same. Google takes no new time from a guest.
  Future<void> respond(
    String eventId,
    InviteResponse response, {
    String note = '',
    bool send = true,
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final event = await _event(eventId, calendarId: calendarId);
    if (event == null || event['status'] == 'cancelled') {
      throw const EventGone();
    }
    final attendees = answeredAttendees(event, response, note: note);
    if (attendees == null) {
      throw const CalendarRefused(
        'This meeting does not list you among those invited, so there is '
        'no answer to give.',
      );
    }
    await _patchEvent(
      eventId,
      {'attendees': attendees},
      calendarId: calendarId,
      sendUpdates: send ? 'all' : 'none',
    );
  }

  /// [event]'s attendees with the account's own entry answered [response],
  /// with [note], or null where the account is not among them.
  static List<Map<String, Object?>>? answeredAttendees(
    Map<String, Object?> event,
    InviteResponse response, {
    String note = '',
  }) {
    final attendees = event['attendees'];
    if (attendees is! List) return null;
    var mine = false;
    final out = <Map<String, Object?>>[];
    for (final a in attendees.whereType<Map>()) {
      final entry = a.cast<String, Object?>();
      if (entry['self'] != true) {
        out.add(entry);
        continue;
      }
      mine = true;
      out.add({
        ...entry,
        'responseStatus': switch (response) {
          InviteResponse.accepted => 'accepted',
          InviteResponse.tentative => 'tentative',
          InviteResponse.declined => 'declined',
        },
        if (note.trim().isNotEmpty) 'comment': note.trim(),
      });
    }
    return mine ? out : null;
  }

  /// [eventId]'s notes, for changing them: its description, as text. Google
  /// keeps the Meet details beside it, not in it, so there is nothing to
  /// keep below.
  Future<EventNotes> notes(
    String eventId, {
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final event = await _event(eventId, calendarId: calendarId);
    if (event == null || event['status'] == 'cancelled') {
      throw const EventGone();
    }
    final description = event['description'];
    final text = description is! String
        ? ''
        : description.contains('<')
            ? htmlToText(description)
            : description;
    return EventNotes(text: text.trim());
  }

  /// Change [eventId] as [change] says, and have Google send everyone on it
  /// the change. A new list of people is merged into the one the event
  /// has, so those who stay keep their answers. [before] is the event as
  /// it was.
  Future<void> update(
    String eventId,
    EventChange change, {
    required CalendarEvent before,
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final fields = changeJson(change, before: before);
    final people = change.attendees;
    if (people != null) {
      final event = await _event(eventId, calendarId: calendarId);
      if (event == null || event['status'] == 'cancelled') {
        throw const EventGone();
      }
      fields['attendees'] = mergedAttendees(event['attendees'], people);
    }
    if (fields.isEmpty) return;
    await _patchEvent(eventId, fields, calendarId: calendarId);
  }

  /// [change] as Google's patch takes it, less the people: see [update].
  /// The other way of giving a time is emptied, or an event moved between
  /// a time and a whole day would hold both.
  static Map<String, Object?> changeJson(
    EventChange change, {
    required CalendarEvent before,
  }) {
    final allDay = change.allDay ?? before.allDay;
    final zone = change.timeZone;
    Map<String, Object?> at(DateTime t) => allDay
        ? {'date': _date(t), 'dateTime': null, 'timeZone': null}
        : zone == null
            ? {'dateTime': _utc(t), 'timeZone': null, 'date': null}
            : {'dateTime': _stamp(t), 'timeZone': zone, 'date': null};
    return {
      if (change.title != null) 'summary': change.title,
      if (change.movesIt) ...{
        'start': at(change.start!),
        'end': at(change.end!),
      },
      if (change.location != null) 'location': change.location,
      if (change.notes != null) 'description': change.notes,
    };
  }

  /// [now], everyone who should be on the event after a change, as Google
  /// takes them: the entries the event has for those who stay, answers and
  /// all, the organiser's own among them, and a new one for each person
  /// added.
  static List<Map<String, Object?>> mergedAttendees(
    Object? had,
    List<MailAddress> now,
  ) {
    String key(Object? email) => '${email ?? ''}'.trim().toLowerCase();
    final wanted = {for (final a in now) key(a.email)};
    final kept = <String, Map<String, Object?>>{};
    for (final a in had is List ? had.whereType<Map>() : const <Map>[]) {
      final entry = a.cast<String, Object?>();
      final email = key(entry['email']);
      if (entry['organizer'] == true || wanted.contains(email)) {
        kept[email] = entry;
      }
    }
    return [
      ...kept.values,
      for (final a in now)
        if (!kept.containsKey(key(a.email)))
          {
            'email': a.email.trim(),
            if (a.name?.trim().isNotEmpty ?? false) 'displayName': a.name!.trim(),
          },
    ];
  }

  /// Cancel [eventId], which this account organised: Google deletes it and
  /// sends everyone on it the cancellation. One gone already is done.
  Future<void> cancel(
    String eventId, {
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final response = await _authorised(
      () => http.Request(
        'DELETE',
        _eventsAt(eventId, {'sendUpdates': 'all'}, calendarId: calendarId),
      ),
    );
    final status = response.statusCode;
    if (status >= 400 && status != 404 && status != 410) {
      throw _failureFor(response);
    }
  }

  /// Take [eventId] off [calendarId], telling nobody: an appointment, or a
  /// meeting already declined. One gone already is done.
  Future<void> removeQuietly(
    String eventId, {
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final response = await _authorised(
      () => http.Request(
        'DELETE',
        _eventsAt(eventId, {'sendUpdates': 'none'}, calendarId: calendarId),
      ),
    );
    final status = response.statusCode;
    if (status >= 400 && status != 404 && status != 410) {
      throw _failureFor(response);
    }
  }

  /// When series [seriesId] starts and ends, its first meeting's times,
  /// for a change to every meeting of it. Null where it is gone.
  Future<SeriesTimes?> seriesTimes(
    String seriesId, {
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final event = await _event(seriesId, calendarId: calendarId);
    if (event == null || event['status'] == 'cancelled') return null;
    final start = event['start'];
    final from = _timeOf(start), to = _timeOf(event['end']);
    if (from == null || to == null) return null;
    return (
      start: from,
      end: to,
      allDay: start is Map && start['date'] is String,
    );
  }

  /// A patch to [eventId] with [fields], Google told to write to everyone
  /// on it unless [sendUpdates] says otherwise.
  Future<void> _patchEvent(
    String eventId,
    Map<String, Object?> fields, {
    String calendarId = CalendarEvent.mainCalendar,
    String sendUpdates = 'all',
  }) async {
    final body = jsonEncode(fields);
    final response = await _authorised(
      () => http.Request(
        'PATCH',
        _eventsAt(eventId, {'sendUpdates': sendUpdates}, calendarId: calendarId),
      )
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode == 404 || response.statusCode == 410) {
      throw const EventGone();
    }
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// An event's start or end for [busy]: a whole day's from the phone's
  /// own midnight, which is the day it means, not UTC's.
  static DateTime? _busyAt(Object? value) {
    final date = value is Map ? value['date'] : null;
    if (date is String) {
      final day = _timeOf(value);
      return day == null ? null : DateTime(day.year, day.month, day.day);
    }
    return _timeOf(value);
  }

  /// Every event a listing gives, less those Google has as cancelled.
  Future<List<Map<String, Object?>>> _list(Uri uri) async {
    final response = await _authorised(() => http.Request('GET', uri));
    if (response.statusCode == 404 || response.statusCode == 410) {
      return const [];
    }
    if (response.statusCode >= 400) throw _failureFor(response);
    final items = _jsonOf(response)['items'];
    return [
      if (items is List)
        for (final e in items.whereType<Map>())
          if (e['status'] != 'cancelled') e.cast<String, Object?>(),
    ];
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

  /// The account's events, or one of them, with [query], on [calendarId]
  /// (`CalendarEvent.mainCalendar` for the primary one). Ids Google makes
  /// are letters and digits, but one is encoded all the same.
  static Uri _eventsAt(
    String? id,
    Map<String, String> query, {
    String calendarId = CalendarEvent.mainCalendar,
  }) =>
      Uri.parse(
        '$base/calendars/'
        '${calendarId == CalendarEvent.mainCalendar ? 'primary' : Uri.encodeComponent(calendarId)}'
        '/events${id == null ? '' : '/${Uri.encodeComponent(id)}'}',
      ).replace(queryParameters: query);

  /// The event as it stands, or null where it is gone.
  Future<Map<String, Object?>?> _event(
    String id, {
    String calendarId = CalendarEvent.mainCalendar,
  }) async {
    final response = await _authorised(
      () => http.Request(
        'GET',
        _eventsAt(id, {'conferenceDataVersion': '1'}, calendarId: calendarId),
      ),
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

  /// An instant in RFC 3339's UTC form.
  static String _utc(DateTime t) {
    final u = t.toUtc();
    return '${_date(u)}T${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)}Z';
  }

  /// A wall-clock time in RFC 3339's shape with no offset: the zone travels
  /// beside it.
  static String _stamp(DateTime t) =>
      '${_date(t)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}
