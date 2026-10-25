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
import '../../domain/text_direction.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../imap/imap_mapping.dart' show htmlToText;
import '../mail_engine.dart';

/// A thin client over the Microsoft Graph calendar: a call to put a meeting
/// on the account's calendar with its attendees invited, one to ask where
/// that calendar holds a meeting online, the three that make a Teams
/// meeting ahead of Send and send it later ([createShell], [sendShell],
/// [deleteShell]), and the three for a meeting a message is about: find it
/// ([meetingFor]), take a cancelled one off ([deleteEvent]), and move one
/// to a time proposed ([moveEvent]).
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
  /// is asked for. A meeting changed since a Send of it failed
  /// ([MeetingDraft.changedSinceFailedSend]) has the event Graph answers
  /// with brought up to date.
  Future<CreatedMeeting> createEvent(
    MeetingDraft meeting, {
    String? onlineMeetingProvider,
    String? joinUrl,
  }) async {
    final body = jsonEncode({
      ...eventJson(
        meeting,
        onlineMeetingProvider: onlineMeetingProvider,
        joinUrl: joinUrl,
      ),
      // One event and one set of invitations however often it is sent: a
      // Send tapped again after an answer that never came, or a retry
      // after a throttle, is known by it.
      'transactionId': meeting.transactionId ?? _transactionId(),
    });
    final response = await _exchange(
      () => http.Request('POST', eventsUri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    var json = _jsonOf(response);
    final id = json['id'];
    if (meeting.changedSinceFailedSend && id is String && id.isNotEmpty) {
      json = await _bringUpToDate(
        id,
        json,
        meeting,
        onlineMeetingProvider: onlineMeetingProvider,
        joinUrl: joinUrl,
      );
    }
    final online = json['onlineMeeting'];
    final made = online is Map ? online['joinUrl'] : null;
    return CreatedMeeting(
      id: id is String && id.isNotEmpty ? id : null,
      joinUrl: joinUrl ?? (made is String && made.isNotEmpty ? made : null),
    );
  }

  /// [made], the event Graph answered a create with, given everything
  /// [meeting] has now, and everyone on it told. Its event as it stands.
  ///
  /// Graph answers a transaction id it has seen with the event it made
  /// then, as it was: the meeting of a Send that failed with only its
  /// answer lost, from before the change. It does not say whether it did,
  /// so the event is patched either way; where the failed Send made
  /// nothing, the patch gives the event just made what it has already.
  /// Two things a patch here never does: turn off a link the event has,
  /// or rewrite a body that holds Exchange's Teams block, which loses the
  /// meeting. The notes of a Teams meeting made at Send stay as they went.
  Future<Map<String, Object?>> _bringUpToDate(
    String id,
    Map<String, Object?> made,
    MeetingDraft meeting, {
    String? onlineMeetingProvider,
    String? joinUrl,
  }) async {
    final fields = eventJson(
      meeting,
      onlineMeetingProvider: onlineMeetingProvider,
      joinUrl: joinUrl,
    );
    if (fields['isOnlineMeeting'] != true) fields.remove('isOnlineMeeting');
    final teams = made['isOnlineMeeting'] == true && joinUrl == null;
    if (teams) {
      fields.remove('body');
    } else if (!fields.containsKey('location')) {
      // Emptied as well as filled: a patch leaves out only what it is not
      // given, and the place the failed Send named would stay.
      fields['location'] = {'displayName': ''};
    }
    final body = jsonEncode(fields);
    final response = await _exchange(() => _patch(id, body));
    if (response.statusCode >= 400) throw _failureFor(response);
    final patched = _jsonOf(response);
    return patched.isEmpty ? made : patched;
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
      // A meeting now: reminded of, and shown, as one made at Send is.
      ..._choices(meeting, shell: true),
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

  // --- meetings already on the calendar --------------------------------------

  /// What is read of a meeting a message is about: when, whether it is
  /// cancelled, whose it is, and whether it is a whole series.
  static const meetingFields =
      'id,start,end,isAllDay,isCancelled,isOrganizer,type,originalStart';

  /// Times in UTC, so they are instants without a zone to work out. Graph
  /// otherwise answers in the zone each event was made in, by its Windows
  /// name.
  static const _inUtc = 'outlook.timezone="UTC"';

  /// The meeting [invite] is about, as this calendar has it, or null where
  /// it is not on it.
  ///
  /// [linkedEventId] is the event the message links to, where it does
  /// (`GraphMailApi.linkedEventId`): Exchange's own answer, which for one
  /// meeting of a series is that meeting. Failing that, the invitation's
  /// UID, which finds a single meeting or a whole series; for one meeting
  /// of a series ([CalendarInvite.recurrenceStart]) the series found is
  /// searched for it. Never the series in its place: an action meant for
  /// one meeting must not reach every one.
  Future<CalendarMeeting?> meetingFor(
    CalendarInvite invite, {
    required String accountId,
    String? linkedEventId,
  }) async {
    Map<String, Object?>? json;
    if (linkedEventId != null) json = await _meeting(linkedEventId);
    if (json == null && invite.uid.isNotEmpty) {
      json = await _meetingByUid(invite.uid);
    }
    if (json == null) return null;
    if (json['type'] == 'seriesMaster' && invite.recurrenceId != null) {
      final id = json['id'];
      final at = invite.recurrenceStart;
      if (id is! String || at == null) return null;
      json = await _occurrence(id, at);
      if (json == null) return null;
    }
    return meetingFromJson(json, accountId: accountId);
  }

  /// Take an event off the calendar, into Deleted Items, where Outlook can
  /// still bring it back. For a meeting someone else organised Exchange
  /// tells nobody; one already gone is done.
  Future<void> deleteEvent(String id) async {
    final response = await _exchange(
      () => http.Request('DELETE', _eventUri(id)),
    );
    if (response.statusCode == 404) return;
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// Move [meeting], which this account organised, to the time [proposal]
  /// proposes. Exchange sends everyone on it the new time, as it does for
  /// any change of time the organiser makes.
  ///
  /// The time goes in the zone the proposal was written in, by its name,
  /// so the meeting keeps it; where Graph does not know that name, again in
  /// UTC, which it always does.
  Future<void> moveEvent(
    CalendarMeeting meeting,
    CalendarInvite proposal,
  ) async {
    Future<http.Response> patch(Map<String, Object?> times) => _exchange(
          () => _patch(meeting.eventId, jsonEncode(times)),
        );
    var response = await patch(movedTimes(meeting, proposal));
    if (response.statusCode == 400 && proposal.localStart != null) {
      response = await patch(movedTimes(meeting, proposal, inUtc: true));
    }
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// The start and end a meeting moved to [proposal]'s time is patched
  /// with. Where the proposal has no end, the meeting keeps its length.
  static Map<String, Object?> movedTimes(
    CalendarMeeting meeting,
    CalendarInvite proposal, {
    bool inUtc = false,
  }) {
    final length = meeting.end?.difference(meeting.start);
    if (proposal.isAllDay) {
      final first = proposal.start;
      final after = proposal.end ??
          (length != null && length.inDays > 1
              ? DateTime(first.year, first.month, first.day + length.inDays)
              : dayAfter(first));
      return {
        'start': {'dateTime': _stamp(_midnight(first)), 'timeZone': 'UTC'},
        'end': {'dateTime': _stamp(_midnight(after)), 'timeZone': 'UTC'},
        'isAllDay': true,
      };
    }
    final zone = proposal.timeZone;
    final localStart = proposal.localStart;
    final localEnd = proposal.localEnd;
    if (!inUtc && zone != null && localStart != null && localEnd != null) {
      return {
        'start': {'dateTime': _stamp(localStart), 'timeZone': zone},
        'end': {'dateTime': _stamp(localEnd), 'timeZone': zone},
        'isAllDay': false,
      };
    }
    final start = proposal.start.toUtc();
    final end = proposal.end?.toUtc() ??
        start.add(length ?? const Duration(minutes: 30));
    return {
      'start': {'dateTime': _stamp(start), 'timeZone': 'UTC'},
      'end': {'dateTime': _stamp(end), 'timeZone': 'UTC'},
      'isAllDay': false,
    };
  }

  // --- events the calendar shows ---------------------------------------------

  /// Answer [eventId], a meeting someone else organised, on the calendar
  /// itself: Outlook's Accept, Tentative and Decline. [send] false keeps
  /// the answer from the organiser, [note] goes with it, and [proposal], a
  /// new time, always goes.
  Future<void> respond(
    String eventId,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) async {
    final action = switch (response) {
      InviteResponse.accepted => 'accept',
      InviteResponse.tentative => 'tentativelyAccept',
      InviteResponse.declined => 'decline',
    };
    final body = jsonEncode(answerJson(note: note, send: send, proposal: proposal));
    final answer = await _exchange(
      () => http.Request('POST', Uri.parse('${_eventUri(eventId)}/$action'))
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (answer.statusCode == 404) throw const EventGone();
    if (answer.statusCode >= 400) throw _failureFor(answer);
  }

  /// What an answer is sent with: see [respond].
  static Map<String, Object?> answerJson({
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) =>
      {
        // A new time goes with the answer only, so it is always sent.
        'sendResponse': send || proposal != null,
        if (note.trim().isNotEmpty) 'comment': note.trim(),
        if (proposal != null)
          'proposedNewTime': {
            'start': {'dateTime': _stamp(proposal.start.toUtc()), 'timeZone': 'UTC'},
            'end': {'dateTime': _stamp(proposal.end.toUtc()), 'timeZone': 'UTC'},
          },
      };

  /// [eventId]'s notes, for changing them: its body as text, and on a
  /// Teams meeting the block Exchange wrote, which goes back under any new
  /// notes as it is.
  Future<EventNotes> notes(String eventId) async {
    final json = await _event(eventId);
    if (json == null) throw const EventGone();
    final html = _bodyIn(json) ?? '';
    final split =
        json['isOnlineMeeting'] == true ? splitTeamsBlock(html) : null;
    return EventNotes(
      text: _decodeNumeric(htmlToText(split?.notes ?? html)).trim(),
      keptBelow: split?.block,
    );
  }

  /// [html], an event's body, as what was written above Exchange's Teams
  /// block and the block itself: from the element holding the first line
  /// of underscores the block is fenced with. Null where there is none.
  static ({String notes, String block})? splitTeamsBlock(String html) {
    final fence = RegExp(r'_{20,}').firstMatch(html);
    if (fence == null) return null;
    final before = html.substring(0, fence.start);
    final opens = RegExp(r'<div\b', caseSensitive: false).allMatches(before);
    final at = opens.isEmpty ? fence.start : opens.last.start;
    return (notes: html.substring(0, at), block: html.substring(at));
  }

  /// Change [eventId] as [change] says, everyone on it told by Exchange: a
  /// change of time, place or notes to everyone, and of the people alone,
  /// sent as nothing but the attendees, to those added or taken off.
  /// [before] is the event as it was, for whom each attendee was.
  Future<void> update(
    String eventId,
    EventChange change, {
    required CalendarEvent before,
  }) async {
    final fields = changeJson(change, before: before);
    if (fields.isEmpty) return;
    final body = jsonEncode(fields);
    final response = await _exchange(() => _patch(eventId, body));
    if (response.statusCode == 404) throw const EventGone();
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// [change] as Graph's patch takes it: only what changes.
  static Map<String, Object?> changeJson(
    EventChange change, {
    required CalendarEvent before,
  }) {
    final zone = change.timeZone;
    Map<String, Object?> at(DateTime t, {required bool allDay}) => allDay
        ? {'dateTime': _stamp(DateTime(t.year, t.month, t.day)), 'timeZone': zone ?? 'UTC'}
        : zone == null
            ? {'dateTime': _stamp(t.toUtc()), 'timeZone': 'UTC'}
            : {'dateTime': _stamp(t), 'timeZone': zone};
    final optional = {
      for (final a in before.attendees)
        if (a.optional) a.address.email.trim().toLowerCase(),
    };
    final notes = change.notes;
    final kept = change.keptBelow;
    return {
      if (change.title != null) 'subject': change.title,
      if (change.movesIt) ...{
        'start': at(change.start!, allDay: change.allDay ?? before.allDay),
        'end': at(change.end!, allDay: change.allDay ?? before.allDay),
        'isAllDay': change.allDay ?? before.allDay,
      },
      if (change.location != null) 'location': {'displayName': change.location},
      if (change.reminder case final r?) ...{
        'isReminderOn': r.isOn,
        if (r.isOn) 'reminderMinutesBeforeStart': r.minutes,
      },
      if (change.showAs case final showAs?) 'showAs': graphShowAs(showAs),
      if (change.isPrivate case final private?)
        'sensitivity': private ? 'private' : 'normal',
      if (notes != null)
        'body': kept == null
            ? {'contentType': 'text', 'content': notes}
            : {'contentType': 'html', 'content': bodyWithNotes(kept, notes)},
      if (change.attendees case final people?)
        'attendees': [
          for (final a in people)
            {
              'emailAddress': {
                'address': a.email,
                if (a.name?.trim().isNotEmpty ?? false) 'name': a.name!.trim(),
              },
              'type': optional.contains(a.email.trim().toLowerCase())
                  ? 'optional'
                  : 'required',
            },
        ],
    };
  }

  /// Cancel [eventId], which this account organised: Exchange sends
  /// everyone on it the cancellation, with [note]. One gone already is
  /// done.
  Future<void> cancel(String eventId, {String note = ''}) async {
    final body = jsonEncode({if (note.trim().isNotEmpty) 'Comment': note.trim()});
    final response = await _exchange(
      () => http.Request('POST', Uri.parse('${_eventUri(eventId)}/cancel'))
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode == 404) return;
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// Forward [eventId] to [to]: Exchange sends them the invitation, and
  /// for a meeting this account was invited to, tells the organiser and
  /// adds them to the organiser's copy.
  Future<void> forward(
    String eventId,
    List<MailAddress> to, {
    String note = '',
  }) async {
    final body = jsonEncode({
      'ToRecipients': [
        for (final a in to)
          {
            'EmailAddress': {
              'Address': a.email,
              if (a.name?.trim().isNotEmpty ?? false) 'Name': a.name!.trim(),
            },
          },
      ],
      if (note.trim().isNotEmpty) 'Comment': note.trim(),
    });
    final response = await _exchange(
      () => http.Request('POST', Uri.parse('${_eventUri(eventId)}/forward'))
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode == 404) throw const EventGone();
    if (response.statusCode >= 400) throw _failureFor(response);
  }

  /// When series [seriesId] starts and ends, its first meeting's times,
  /// for a change to every meeting of it. Null where it is gone.
  Future<SeriesTimes?> seriesTimes(String seriesId) async {
    final json = await _meeting(seriesId);
    if (json == null) return null;
    final allDay = json['isAllDay'] == true;
    final start = _utcTimeOf(json['start'], wholeDay: allDay);
    final end = _utcTimeOf(json['end'], wholeDay: allDay);
    if (start == null || end == null) return null;
    return (start: start, end: end, allDay: allDay);
  }

  /// A meeting as Graph gives it, asked for with [meetingFields] in UTC; null
  /// for one with no id or no start.
  static CalendarMeeting? meetingFromJson(
    Map<String, Object?> json, {
    required String accountId,
  }) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final allDay = json['isAllDay'] == true;
    final start = _utcTimeOf(json['start'], wholeDay: allDay);
    if (start == null) return null;
    return CalendarMeeting(
      accountId: accountId,
      eventId: id,
      start: start,
      end: _utcTimeOf(json['end'], wholeDay: allDay),
      isAllDay: allDay,
      isCancelled: json['isCancelled'] == true,
      isOrganizer: json['isOrganizer'] == true,
      isSeries: json['type'] == 'seriesMaster',
    );
  }

  /// A time Graph gave in UTC, which it writes with no Z and seven places of
  /// seconds: "2026-10-16T18:00:00.0000000". A whole day is its date.
  static DateTime? _utcTimeOf(Object? value, {required bool wholeDay}) {
    final text = value is Map ? value['dateTime'] : null;
    if (text is! String) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})')
        .firstMatch(text);
    if (m == null) return null;
    final n = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
    return wholeDay
        ? DateTime.utc(n[0], n[1], n[2])
        : DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]);
  }

  static DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

  /// One event, for a meeting, in UTC; null where it is gone.
  Future<Map<String, Object?>?> _meeting(String id) async {
    final response = await _exchange(
      () => http.Request(
        'GET',
        _eventUri(id).replace(queryParameters: {r'$select': meetingFields}),
      )..headers['Prefer'] = _inUtc,
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) throw _failureFor(response);
    return _jsonOf(response);
  }

  /// The single meeting or series with this invitation UID. Graph gives a
  /// series and a meeting not in one the UID their invitations carry; each
  /// meeting of a series has one of its own, which is why it is looked for
  /// in the series instead.
  Future<Map<String, Object?>?> _meetingByUid(String uid) async {
    final response = await _exchange(
      () => http.Request(
        'GET',
        eventsUri.replace(queryParameters: {
          r'$filter': "iCalUId eq '${uid.replaceAll("'", "''")}'",
          r'$select': meetingFields,
          r'$top': '1',
        }),
      )..headers['Prefer'] = _inUtc,
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    final value = _jsonOf(response)['value'];
    if (value is! List || value.isEmpty || value.first is! Map) return null;
    return (value.first as Map).cast<String, Object?>();
  }

  /// The meeting of series [seriesId] that was set for [at], moved or not,
  /// cancelled or not; null where it is not on the calendar any more.
  Future<Map<String, Object?>?> _occurrence(String seriesId, DateTime at) async {
    // The day either side: a meeting moved since is still listed by when it
    // is now, and the search is by when it was set for.
    final from = at.toUtc().subtract(const Duration(days: 2));
    final to = at.toUtc().add(const Duration(days: 2));
    final response = await _exchange(
      () => http.Request(
        'GET',
        Uri.parse('${_eventUri(seriesId)}/instances').replace(
          queryParameters: {
            'startDateTime': from.toIso8601String(),
            'endDateTime': to.toIso8601String(),
            r'$select': meetingFields,
          },
        ),
      )..headers['Prefer'] = _inUtc,
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) throw _failureFor(response);
    final value = _jsonOf(response)['value'];
    if (value is! List) return null;
    return occurrenceAt([
      for (final item in value.whereType<Map>())
        if (DateTime.tryParse('${item['originalStart']}') case final original?)
          (original, item.cast<String, Object?>()),
    ], at);
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
      ..._choices(meeting),
    };
  }

  /// What the screen chose beyond the when and where: the repeat, the
  /// reminder, how it shows, and privacy. Left out where nothing was
  /// chosen, so the calendar's own way stands; for a meeting made ahead of
  /// Send ([shell]), which was made quiet and free, the reminder and busy
  /// are said either way.
  static Map<String, Object?> _choices(
    MeetingDraft meeting, {
    bool shell = false,
  }) {
    final sent = meeting.asSent;
    final reminder = meeting.reminder;
    final showAs = meeting.showAs;
    return {
      if (meeting.recurrence case final r?)
        // From the first meeting's own day, on its own clock: in UTC a
        // late evening is the next day.
        'recurrence': r.toGraph(meeting.start, timeZone: sent.timeZone),
      if (reminder != null) ...{
        'isReminderOn': reminder.isOn,
        if (reminder.isOn) 'reminderMinutesBeforeStart': reminder.minutes,
      } else if (shell)
        'isReminderOn': true,
      if (showAs != null)
        'showAs': graphShowAs(showAs)
      else if (shell)
        'showAs': 'busy',
      if (meeting.isPrivate) 'sensitivity': 'private',
    };
  }

  /// Graph's name for how an event shows.
  static String graphShowAs(EventShowAs showAs) => switch (showAs) {
        EventShowAs.free => 'free',
        EventShowAs.tentative => 'tentative',
        EventShowAs.busy => 'busy',
        EventShowAs.outOfOffice => 'oof',
        EventShowAs.workingElsewhere => 'workingElsewhere',
      };

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

  /// When the calendar is busy between [start] and [end]: everything on it
  /// but what is shown as free or working elsewhere, cancelled, or turned
  /// down.
  Future<List<TimeSpan>> busy(DateTime start, DateTime end) async {
    final busy = <TimeSpan>[];
    var next = Uri.parse('$base/me/calendarView').replace(queryParameters: {
      'startDateTime': start.toUtc().toIso8601String(),
      'endDateTime': end.toUtc().toIso8601String(),
      r'$select': 'start,end,showAs,isCancelled,responseStatus',
      r'$top': '200',
    });
    for (var page = 0; page < 10; page++) {
      final response = await _exchange(
        () => http.Request('GET', next)..headers['Prefer'] = _inUtc,
      );
      if (response.statusCode >= 400) throw _failureFor(response);
      final json = _jsonOf(response);
      final value = json['value'];
      for (final e in value is List ? value : const []) {
        if (e is! Map) continue;
        final event = e.cast<String, Object?>();
        if (event['isCancelled'] == true) continue;
        if (_notBusy.contains('${event['showAs']}')) continue;
        final status = event['responseStatus'];
        if (status is Map && status['response'] == 'declined') continue;
        final span = _spanOf(event);
        if (span != null) busy.add(span);
      }
      final link = json['@odata.nextLink'];
      if (link is! String) break;
      next = Uri.parse(link);
    }
    return busy;
  }

  /// Every event on the calendar between [start] and [end], each
  /// occurrence of a series on its own, as [accountId]'s.
  Future<List<CalendarEvent>> events(
    DateTime start,
    DateTime end, {
    required String accountId,
  }) async {
    final found = <CalendarEvent>[];
    var next = Uri.parse('$base/me/calendarView').replace(queryParameters: {
      'startDateTime': start.toUtc().toIso8601String(),
      'endDateTime': end.toUtc().toIso8601String(),
      r'$select': 'subject,start,end,isAllDay,location,organizer,attendees,'
          'onlineMeeting,webLink,showAs,responseStatus,isOrganizer,'
          'isCancelled,isReminderOn,reminderMinutesBeforeStart,bodyPreview,'
          'seriesMasterId,sensitivity,originalStartTimeZone',
      r'$orderby': 'start/dateTime',
      r'$top': '200',
    });
    for (var page = 0; page < 20; page++) {
      final response = await _exchange(
        () => http.Request('GET', next)..headers['Prefer'] = _inUtc,
      );
      if (response.statusCode >= 400) throw _failureFor(response);
      final json = _jsonOf(response);
      final value = json['value'];
      for (final e in value is List ? value : const []) {
        if (e is! Map) continue;
        final event = eventFrom(e.cast<String, Object?>(), accountId);
        if (event != null) found.add(event);
      }
      final link = json['@odata.nextLink'];
      if (link is! String) break;
      next = Uri.parse(link);
    }
    return found;
  }

  /// One of calendarView's events, asked for in UTC, as a [CalendarEvent]
  /// in local time; null for one with no id or no time.
  static CalendarEvent? eventFrom(Map<String, Object?> json, String accountId) {
    final id = json['id'];
    if (id is! String) return null;
    final allDay = json['isAllDay'] == true;
    DateTime? at(Object? value) {
      if (value is! Map) return null;
      final text = value['dateTime'];
      if (text is! String) return null;
      final utc = DateTime.tryParse(text.endsWith('Z') ? text : '${text}Z');
      if (utc == null) return null;
      // A whole day is the day it names, from the phone's own midnight.
      return allDay ? DateTime(utc.year, utc.month, utc.day) : utc.toLocal();
    }

    final start = at(json['start']), end = at(json['end']);
    if (start == null || end == null) return null;
    MailAddress? address(Object? v) {
      final e = v is Map ? v['emailAddress'] : null;
      if (e is! Map) return null;
      final email = '${e['address'] ?? ''}'.trim();
      if (email.isEmpty) return null;
      final name = '${e['name'] ?? ''}'.trim();
      return MailAddress(email: email, name: name.isEmpty ? null : name);
    }

    EventResponse response(Object? status) =>
        switch (status is Map ? '${status['response']}' : '') {
          'organizer' => EventResponse.organizer,
          'accepted' => EventResponse.accepted,
          'tentativelyAccepted' => EventResponse.tentative,
          'declined' => EventResponse.declined,
          'notResponded' => EventResponse.notResponded,
          _ => EventResponse.none,
        };
    final attendees = json['attendees'];
    final location = json['location'];
    final online = json['onlineMeeting'];
    final joinUrl = online is Map ? online['joinUrl'] : null;
    final minutes = json['reminderMinutesBeforeStart'];
    return CalendarEvent(
      id: id,
      accountId: accountId,
      title: '${json['subject'] ?? ''}'.trim(),
      start: start,
      end: end.isBefore(start) ? start : end,
      allDay: allDay,
      location: location is Map ? '${location['displayName'] ?? ''}'.trim() : '',
      organizer: address(json['organizer']),
      attendees: [
        for (final a in attendees is List ? attendees : const [])
          if (a is Map && a['type'] != 'resource')
            if (address(a) case final who?)
              EventAttendee(
                who,
                response: response(a['status']),
                optional: a['type'] == 'optional',
              ),
      ],
      joinUrl: joinUrl is String && joinUrl.isNotEmpty ? joinUrl : null,
      webLink: json['webLink'] is String ? json['webLink'] as String : null,
      showAs: switch ('${json['showAs']}') {
        'free' => EventShowAs.free,
        'tentative' => EventShowAs.tentative,
        'oof' => EventShowAs.outOfOffice,
        'workingElsewhere' => EventShowAs.workingElsewhere,
        _ => EventShowAs.busy,
      },
      response: response(json['responseStatus']),
      isOrganizer: json['isOrganizer'] == true,
      cancelled: json['isCancelled'] == true,
      reminderMinutes:
          json['isReminderOn'] == true && minutes is num ? minutes.toInt() : null,
      preview: '${json['bodyPreview'] ?? ''}'.trim(),
      seriesId: json['seriesMasterId'] is String &&
              (json['seriesMasterId'] as String).isNotEmpty
          ? json['seriesMasterId'] as String
          : null,
      isPrivate: json['sensitivity'] == 'private' ||
          json['sensitivity'] == 'confidential',
      timeZone: switch (json['originalStartTimeZone']) {
        final String zone when zone.isNotEmpty && zone != 'tzone://Microsoft/Utc' =>
          zone,
        _ => null,
      },
    );
  }

  /// When each of [emails] is busy between [start] and [end], as Exchange
  /// lets the organisation see: Outlook's Scheduling Assistant. Null for
  /// one it will not say for (outside the organisation, say).
  Future<Map<String, List<TimeSpan>?>> schedules(
    List<String> emails,
    DateTime start,
    DateTime end,
  ) async {
    if (emails.isEmpty) return const {};
    String utc(DateTime t) =>
        t.toUtc().toIso8601String().replaceFirst(RegExp(r'Z$'), '');
    final response = await _exchange(
      () => http.Request('POST', Uri.parse('$base/me/calendar/getSchedule'))
        ..headers['Content-Type'] = 'application/json'
        ..headers['Prefer'] = _inUtc
        ..body = jsonEncode({
          'schedules': emails,
          'startTime': {'dateTime': utc(start), 'timeZone': 'UTC'},
          'endTime': {'dateTime': utc(end), 'timeZone': 'UTC'},
          'availabilityViewInterval': 30,
        }),
    );
    if (response.statusCode >= 400) throw _failureFor(response);
    final value = _jsonOf(response)['value'];
    final found = <String, List<TimeSpan>?>{};
    for (final s in value is List ? value : const []) {
      if (s is! Map) continue;
      final id = '${s['scheduleId'] ?? ''}'.toLowerCase();
      if (id.isEmpty) continue;
      if (s['error'] != null) {
        found[id] = null;
        continue;
      }
      final items = s['scheduleItems'];
      found[id] = [
        for (final item in items is List ? items : const [])
          if (item is Map && !_notBusy.contains('${item['status']}'))
            ?_spanOf(item.cast<String, Object?>()),
      ];
    }
    return found;
  }

  /// What an event can be shown as and still leave the time free: working
  /// elsewhere is working, as Outlook's Scheduling Assistant has it.
  static const _notBusy = {'free', 'workingElsewhere'};

  /// An event's or a schedule item's start and end, in UTC as asked.
  static TimeSpan? _spanOf(Map<String, Object?> json) {
    DateTime? at(Object? value) {
      if (value is! Map) return null;
      final text = value['dateTime'];
      if (text is! String) return null;
      return DateTime.tryParse(text.endsWith('Z') ? text : '${text}Z');
    }

    final start = at(json['start']), end = at(json['end']);
    if (start == null || end == null || !end.isAfter(start)) return null;
    return (start: start, end: end);
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
