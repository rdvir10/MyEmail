import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show answerCounts, describeAnswers;

/// Acting on a meeting from the calendar (calendar ideas #12 to #19, #35):
/// what goes to Microsoft and Google, and the rules around it.
void main() {
  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  Map<String, Object?> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, Object?>();

  const dana = MailAddress(email: 'dana@hadco.example', name: 'Dana Levi');
  const yossi = MailAddress(email: 'yossi@hadco.example', name: 'Yossi');
  const me = 'ron@hadco.example';

  CalendarEvent meeting({
    String id = 'e1',
    bool own = true,
    List<EventAttendee> attendees = const [
      EventAttendee(yossi, response: EventResponse.accepted),
    ],
    String? seriesId,
    String calendarId = CalendarEvent.mainCalendar,
    bool allDay = false,
  }) =>
      CalendarEvent(
        id: id,
        accountId: 'a',
        calendarId: calendarId,
        title: 'Project review',
        start: allDay ? DateTime(2026, 10, 27) : DateTime(2026, 10, 27, 14),
        end: allDay ? DateTime(2026, 10, 28) : DateTime(2026, 10, 27, 15),
        allDay: allDay,
        organizer: own ? null : dana,
        attendees: attendees,
        isOrganizer: own,
        response: own ? EventResponse.organizer : EventResponse.notResponded,
        seriesId: seriesId,
      );

  group('the rules', () {
    test('a change is only what differs, people compared by address', () {
      final before = meeting();
      const notes = EventNotes(text: 'Agenda');
      final none = EventChange.between(
        before,
        notesBefore: notes,
        title: ' Project review ',
        start: before.start,
        end: before.end,
        allDay: false,
        location: '',
        notes: 'Agenda',
        attendees: const [MailAddress(email: 'YOSSI@hadco.example')],
      );
      expect(none.isEmpty, isTrue);

      final some = EventChange.between(
        before,
        notesBefore: notes,
        title: 'Board review',
        start: before.start.add(const Duration(hours: 1)),
        end: before.end.add(const Duration(hours: 1)),
        allDay: false,
        location: 'Room 2',
        notes: 'Agenda',
        attendees: const [yossi, dana],
        timeZone: 'Asia/Jerusalem',
      );
      expect(some.title, 'Board review');
      expect(some.movesIt, isTrue);
      expect(some.location, 'Room 2');
      expect(some.notes, isNull, reason: 'the notes are as they were');
      expect(some.attendees, [yossi, dana]);
      expect(some.timeZone, 'Asia/Jerusalem');
      expect(some.onlyPeople, isFalse);
      expect(const EventChange(attendees: [yossi]).onlyPeople, isTrue);
    });

    test('every meeting of a series keeps its day and takes the new time',
        () {
      // One meeting of a weekly series, the series' first on 6 October,
      // moved from 14:00–15:00 to 15:30–16:15.
      final moved = EventChange(
        start: DateTime(2026, 10, 27, 15, 30),
        end: DateTime(2026, 10, 27, 16, 15),
        allDay: false,
      );
      final series = forSeries(moved, (
        start: DateTime(2026, 10, 6, 14).toUtc(),
        end: DateTime(2026, 10, 6, 15).toUtc(),
        allDay: false,
      ));
      expect(series.start, DateTime(2026, 10, 6, 15, 30));
      expect(series.end, DateTime(2026, 10, 6, 16, 15));

      final days = forSeries(
        EventChange(
          start: DateTime(2026, 10, 27),
          end: DateTime(2026, 10, 29),
          allDay: true,
        ),
        (start: DateTime.utc(2026, 10, 6), end: DateTime.utc(2026, 10, 7), allDay: true),
      );
      expect(days.start, DateTime(2026, 10, 6));
      expect(days.end, DateTime(2026, 10, 8), reason: 'two days, as moved');
      expect(forSeries(const EventChange(title: 'x'), (
        start: DateTime.utc(2026),
        end: DateTime.utc(2026),
        allDay: false,
      )).title, 'x');
    });

    test('who is on it, who has not answered, and how they answered', () {
      final e = meeting(attendees: const [
        EventAttendee(MailAddress(email: me), response: EventResponse.organizer),
        EventAttendee(yossi, response: EventResponse.accepted),
        EventAttendee(dana, response: EventResponse.notResponded),
        EventAttendee(MailAddress(email: 'ori@hadco.example'),
            response: EventResponse.declined),
      ]);
      expect([for (final a in everyoneOn(e, me)) a.email],
          ['yossi@hadco.example', 'dana@hadco.example', 'ori@hadco.example']);
      expect(notAnswered(e, me), [dana]);
      final counts = answerCounts(e, me);
      expect(describeAnswers(counts), '1 accepted · 1 declined · 1 not answered');
      expect(
        everyoneOn(meeting(own: false, attendees: const [EventAttendee(dana)]), me),
        [dana],
        reason: 'the organiser once, though also an attendee',
      );
      expect(hasOthers(meeting(attendees: const []), me), isFalse);
      expect(isOwnEvent(meeting(own: false)), isFalse);
      expect(
        isOwnEvent(CalendarEvent(
          id: 'x',
          accountId: 'a',
          title: 'Dentist',
          start: DateTime(2026),
          end: DateTime(2026),
        )),
        isTrue,
        reason: 'an appointment, with nobody on it',
      );
    });
  });

  group('on a Microsoft calendar', () {
    late List<http.Request> sent;

    GraphCalendarApi api([
      http.Response Function(http.Request)? answer,
    ]) {
      sent = [];
      return GraphCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer?.call(request) ?? http.Response('', 202);
        }),
        sleep: (_) async {},
      );
    }

    test('an answer goes to the event, with the note, the organiser told or '
        'not', () async {
      await api().respond('e/1', InviteResponse.accepted, note: ' See you ');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/v1.0/me/events/e%2F1/accept');
      expect(bodyOf(sent.single), {'sendResponse': true, 'comment': 'See you'});

      await api().respond('e1', InviteResponse.declined, send: false);
      expect(sent.single.url.path, endsWith('/decline'));
      expect(bodyOf(sent.single)['sendResponse'], isFalse);

      await api().respond('e1', InviteResponse.tentative,
          send: false,
          proposal: (
            start: DateTime.utc(2026, 10, 27, 16),
            end: DateTime.utc(2026, 10, 27, 17),
          ));
      final body = bodyOf(sent.single);
      expect(sent.single.url.path, endsWith('/tentativelyAccept'));
      expect(body['sendResponse'], isTrue, reason: 'a new time always goes');
      expect(body['proposedNewTime'], {
        'start': {'dateTime': '2026-10-27T16:00:00', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-10-27T17:00:00', 'timeZone': 'UTC'},
      });
    });

    test('a change of the people alone is sent as the people alone, each '
        'as they were', () async {
      final before = meeting(attendees: const [
        EventAttendee(yossi, response: EventResponse.accepted, optional: true),
      ]);
      await api().update('e1', const EventChange(attendees: [yossi, dana]),
          before: before);
      final body = bodyOf(sent.single);
      expect(sent.single.method, 'PATCH');
      expect(body.keys, ['attendees'],
          reason: 'so Exchange writes to those added and nobody else');
      expect(body['attendees'], [
        {
          'emailAddress': {'address': 'yossi@hadco.example', 'name': 'Yossi'},
          'type': 'optional',
        },
        {
          'emailAddress': {'address': 'dana@hadco.example', 'name': 'Dana Levi'},
          'type': 'required',
        },
      ]);
    });

    test('a move goes in the device zone, a whole day as midnights', () async {
      await api().update(
        'e1',
        EventChange(
          start: DateTime(2026, 10, 28, 9),
          end: DateTime(2026, 10, 28, 9, 30),
          allDay: false,
          timeZone: 'Asia/Jerusalem',
        ),
        before: meeting(),
      );
      expect(bodyOf(sent.single), {
        'start': {'dateTime': '2026-10-28T09:00:00', 'timeZone': 'Asia/Jerusalem'},
        'end': {'dateTime': '2026-10-28T09:30:00', 'timeZone': 'Asia/Jerusalem'},
        'isAllDay': false,
      });

      await api().update(
        'e1',
        EventChange(
          start: DateTime(2026, 11, 2),
          end: DateTime(2026, 11, 4),
          allDay: true,
        ),
        before: meeting(),
      );
      expect(bodyOf(sent.single)['start'],
          {'dateTime': '2026-11-02T00:00:00', 'timeZone': 'UTC'});
      expect(bodyOf(sent.single)['end'],
          {'dateTime': '2026-11-04T00:00:00', 'timeZone': 'UTC'});
    });

    const teamsBody = '<html><body><div>Agenda: the budget</div><br>'
        '<div style="width:100%"><span>'
        '________________________________________________________________'
        '</span></div><div>Microsoft Teams meeting</div>'
        '<a href="https://teams.microsoft.com/l/meetup-join/x">Join</a>'
        '</body></html>';

    test("a Teams meeting's notes are read apart from its block, and new "
        'notes go back above it', () async {
      final notes = await api((_) => json({
            'id': 'e1',
            'isOnlineMeeting': true,
            'body': {'contentType': 'html', 'content': teamsBody},
          })).notes('e1');
      expect(notes.text, 'Agenda: the budget');
      expect(notes.keptBelow, startsWith('<div style="width:100%">'));
      expect(notes.keptBelow, contains('teams.microsoft.com'));

      await api().update(
        'e1',
        EventChange(notes: 'Agenda: the budget, and hiring', keptBelow: notes.keptBelow),
        before: meeting(),
      );
      final body = bodyOf(sent.single)['body'] as Map;
      expect(body['contentType'], 'html');
      expect(body['content'], contains('and hiring'));
      expect(body['content'], contains('teams.microsoft.com/l/meetup-join/x'),
          reason: 'the meeting is lost without its block');

      await api().update('e1', const EventChange(notes: 'Plain'),
          before: meeting());
      expect(bodyOf(sent.single)['body'],
          {'contentType': 'text', 'content': 'Plain'});
    });

    test('cancel and forward', () async {
      await api().cancel('e1', note: 'Sorry, moved to next week');
      expect(sent.single.url.path, endsWith('/e1/cancel'));
      expect(bodyOf(sent.single), {'Comment': 'Sorry, moved to next week'});

      await api().forward('e1', const [yossi]);
      expect(sent.single.url.path, endsWith('/e1/forward'));
      expect(bodyOf(sent.single), {
        'ToRecipients': [
          {
            'EmailAddress': {'Address': 'yossi@hadco.example', 'Name': 'Yossi'},
          },
        ],
      });
    });

    test('a meeting gone meanwhile says so', () async {
      await expectLater(
        api((_) => json({'error': {'code': 'ErrorItemNotFound'}}, 404))
            .update('e1', const EventChange(title: 'x'), before: meeting()),
        throwsA(isA<EventGone>()),
      );
    });
  });

  group('on a Google calendar', () {
    late List<http.Request> sent;

    GoogleCalendarApi api(Map<String, Object?> event) {
      sent = [];
      return GoogleCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          if (request.method == 'GET') return json(event);
          return json({});
        }),
        sleep: (_) async {},
      );
    }

    final invited = {
      'id': 'g1',
      'status': 'confirmed',
      'attendees': [
        {'email': 'dana@example.com', 'organizer': true, 'responseStatus': 'accepted'},
        {'email': 'me@gmail.example', 'self': true, 'responseStatus': 'needsAction'},
        {'email': 'yossi@example.com', 'responseStatus': 'tentative'},
      ],
    };

    test("an answer changes the account's own entry and nobody else's",
        () async {
      await api(invited)
          .respond('g1', InviteResponse.accepted, note: 'Glad to');
      final patch = sent.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.queryParameters['sendUpdates'], 'all');
      expect(bodyOf(patch)['attendees'], [
        {'email': 'dana@example.com', 'organizer': true, 'responseStatus': 'accepted'},
        {
          'email': 'me@gmail.example',
          'self': true,
          'responseStatus': 'accepted',
          'comment': 'Glad to',
        },
        {'email': 'yossi@example.com', 'responseStatus': 'tentative'},
      ]);

      await api(invited).respond('g1', InviteResponse.declined, send: false);
      expect(sent.last.url.queryParameters['sendUpdates'], 'none');
    });

    test('a meeting that does not list the account has nothing to answer',
        () async {
      await expectLater(
        api({'id': 'g1', 'attendees': []}).respond('g1', InviteResponse.accepted),
        throwsA(isA<CalendarRefused>()),
      );
      expect(sent.where((r) => r.method == 'PATCH'), isEmpty);
    });

    test('new people are merged in, so those who stay keep their answers',
        () async {
      final own = {
        'id': 'g1',
        'attendees': [
          {'email': 'me@gmail.example', 'organizer': true, 'self': true, 'responseStatus': 'accepted'},
          {'email': 'yossi@example.com', 'responseStatus': 'accepted'},
          {'email': 'gone@example.com', 'responseStatus': 'declined'},
        ],
      };
      await api(own).update(
        'g1',
        const EventChange(attendees: [
          MailAddress(email: 'Yossi@example.com'),
          MailAddress(email: 'new@example.com', name: 'New One'),
        ]),
        before: meeting(),
      );
      expect(bodyOf(sent.last)['attendees'], [
        {'email': 'me@gmail.example', 'organizer': true, 'self': true, 'responseStatus': 'accepted'},
        {'email': 'yossi@example.com', 'responseStatus': 'accepted'},
        {'email': 'new@example.com', 'displayName': 'New One'},
      ]);
      expect(sent.last.url.queryParameters['sendUpdates'], 'all');
    });

    test('a move to whole days empties the time, on the calendar it is on',
        () async {
      await api(const {}).update(
        'g1',
        EventChange(start: DateTime(2026, 11, 2), end: DateTime(2026, 11, 3), allDay: true),
        before: meeting(calendarId: 'family#123@group.calendar.google.com'),
        calendarId: 'family#123@group.calendar.google.com',
      );
      final patch = sent.single;
      expect(patch.url.path,
          '/calendar/v3/calendars/family%23123%40group.calendar.google.com/events/g1');
      expect(bodyOf(patch), {
        'start': {'date': '2026-11-02', 'dateTime': null, 'timeZone': null},
        'end': {'date': '2026-11-03', 'dateTime': null, 'timeZone': null},
      });
    });

    test('cancelling tells everyone; an appointment goes quietly', () async {
      await api(const {}).cancel('g1');
      expect(sent.single.method, 'DELETE');
      expect(sent.single.url.queryParameters['sendUpdates'], 'all');
      await api(const {}).removeQuietly('g1');
      expect(sent.single.url.queryParameters['sendUpdates'], 'none');
    });
  });

  group('through the account', () {
    const microsoft = Account(
      id: 'a',
      displayName: 'Hadco',
      emailAddress: me,
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF0F6CBD,
    );
    const gmail = Account(
      id: 'g',
      displayName: 'Gmail',
      emailAddress: 'me@gmail.example',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF007258,
    );
    late List<http.Request> sent;

    AccountCalendar calendar(http.Response Function(http.Request) answer) {
      sent = [];
      return AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async =>
            'token',
        accounts: () => const [microsoft, gmail],
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer(request);
        }),
        sleep: (_) async {},
      );
    }

    test('every meeting of a series: the series moved on its own first day',
        () async {
      final c = calendar((r) => r.method == 'GET'
          ? json({
              'id': 'series-1',
              'start': {'dateTime': '2026-10-06T12:00:00.0000000', 'timeZone': 'UTC'},
              'end': {'dateTime': '2026-10-06T13:00:00.0000000', 'timeZone': 'UTC'},
              'isAllDay': false,
              'type': 'seriesMaster',
            })
          : json({}));
      final one = meeting(id: 'occurrence-4', seriesId: 'series-1');
      await c.updateEvent(
        microsoft,
        one,
        EventChange(
          start: one.start.add(const Duration(hours: 1)),
          end: one.end.add(const Duration(hours: 1)),
          allDay: false,
        ),
        wholeSeries: true,
      );
      final patch = sent.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.path, endsWith('/events/series-1'));
      final first = DateTime.utc(2026, 10, 6, 12).toLocal();
      final start = (bodyOf(patch)['start'] as Map)['dateTime'] as String;
      expect(start, startsWith('2026-10-'));
      expect(DateTime.parse('${start}Z').toLocal().day, first.day,
          reason: "the series' own first day");
    });

    test("someone else's meeting is declined, then taken off", () async {
      final c = calendar((_) => http.Response('', 202));
      await c.removeEvent(microsoft, meeting(own: false));
      expect([for (final r in sent) '${r.method} ${r.url.path.split('/').last}'],
          ['POST decline', 'DELETE e1']);
    });

    test("one's own meeting with people on it is cancelled, not deleted",
        () async {
      final c = calendar((_) => http.Response('', 202));
      await expectLater(c.removeEvent(microsoft, meeting()),
          throwsA(isA<ArgumentError>()));
      await expectLater(
          c.updateEvent(microsoft, meeting(own: false),
              const EventChange(title: 'Mine now')),
          throwsA(isA<ArgumentError>()));
      expect(sent, isEmpty);
      await c.cancelEvent(microsoft, meeting(), note: 'Sorry');
      expect(sent.single.url.path, endsWith('/cancel'));
    });

    test('Google has no forward, and takes no new time from a guest',
        () async {
      final c = calendar((_) => json({}));
      await expectLater(c.forwardEvent(gmail, meeting(own: false), const [yossi]),
          throwsA(isA<CalendarRefused>()));
      await expectLater(
        c.respondToEvent(gmail, meeting(own: false), InviteResponse.tentative,
            proposal: (start: DateTime(2026), end: DateTime(2026))),
        throwsA(isA<CalendarRefused>()),
      );
      expect(sent, isEmpty);
    });
  });
}
