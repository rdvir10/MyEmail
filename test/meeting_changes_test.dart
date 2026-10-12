import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/calendar_meeting.dart';

import 'fakes/fake_imap_transport.dart';

/// Meeting mail that is not an invitation: a meeting cancelled or moved by
/// its organiser, a new time proposed to you as organiser, and an answer.
void main() {
  /// Exchange's definition of the zone it names, as every Outlook meeting
  /// message carries it.
  const eastern = 'BEGIN:VTIMEZONE\r\n'
      'TZID:Eastern Standard Time\r\n'
      'BEGIN:STANDARD\r\n'
      'DTSTART:16010101T020000\r\n'
      'TZOFFSETFROM:-0400\r\n'
      'TZOFFSETTO:-0500\r\n'
      'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11\r\n'
      'END:STANDARD\r\n'
      'BEGIN:DAYLIGHT\r\n'
      'DTSTART:16010101T020000\r\n'
      'TZOFFSETFROM:-0500\r\n'
      'TZOFFSETTO:-0400\r\n'
      'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3\r\n'
      'END:DAYLIGHT\r\n'
      'END:VTIMEZONE\r\n';

  /// What Outlook sends the organiser for Propose New Time: the time
  /// proposed as the event's own, the time it has now beside it.
  String counter({
    String partStat = 'DECLINED',
    String recurrence = '',
  }) =>
      'BEGIN:VCALENDAR\r\n'
      'METHOD:COUNTER\r\n'
      'PRODID:Microsoft Exchange Server 2010\r\n'
      'VERSION:2.0\r\n'
      '$eastern'
      'BEGIN:VEVENT\r\n'
      'ATTENDEE;PARTSTAT=$partStat;CN=Dana Levi:mailto:dana@example.com\r\n'
      'ORGANIZER;CN=Ron Dvir:mailto:ron@example.com\r\n'
      'SUMMARY;LANGUAGE=en-US:Ron and Dana\r\n'
      'DTSTART;TZID=Eastern Standard Time:20261016T160000\r\n'
      'DTEND;TZID=Eastern Standard Time:20261016T163000\r\n'
      '$recurrence'
      'UID:040000008200E00074C5B7101A82E00800000000AB12\r\n'
      'SEQUENCE:0\r\n'
      'DTSTAMP:20261011T202500Z\r\n'
      'X-MS-OLK-ORIGINALSTART;TZID=Eastern Standard Time:20261016T140000\r\n'
      'X-MS-OLK-ORIGINALEND;TZID=Eastern Standard Time:20261016T143000\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR\r\n';

  group('a new time proposed', () {
    test('is told apart from an invitation and an answer', () {
      final i = CalendarInvite.parse(counter())!;

      expect(i.isCounter, isTrue);
      expect(i.isRequest, isFalse);
      expect(i.isReply, isFalse);
      expect(i.summary, 'Ron and Dana');
    });

    test('the time proposed is the event\'s, the time it has now beside it',
        () {
      final i = CalendarInvite.parse(counter())!;

      // 16:00 in New York in October is 20:00 UTC.
      expect(i.start, DateTime.utc(2026, 10, 16, 20));
      expect(i.end, DateTime.utc(2026, 10, 16, 20, 30));
      expect(i.originalStart, DateTime.utc(2026, 10, 16, 18));
      expect(i.originalEnd, DateTime.utc(2026, 10, 16, 18, 30));
    });

    test('says who proposed it, and how they answered', () {
      final declined = CalendarInvite.parse(counter())!;
      expect(declined.responder!.email, 'dana@example.com');
      expect(declined.responder!.name, 'Dana Levi');
      expect(declined.responderAnswer, InviteResponse.declined);

      final tentative = CalendarInvite.parse(counter(partStat: 'TENTATIVE'))!;
      expect(tentative.responderAnswer, InviteResponse.tentative);

      final unsaid = CalendarInvite.parse(counter(partStat: 'NEEDS-ACTION'))!;
      expect(unsaid.responderAnswer, isNull);
    });

    test('keeps the time as written, in the zone it was written in', () {
      // What Graph is given back when the meeting is moved, so it keeps
      // its zone rather than becoming a meeting in UTC.
      final i = CalendarInvite.parse(counter())!;

      expect(i.timeZone, 'Eastern Standard Time');
      expect(i.localStart, DateTime(2026, 10, 16, 16));
      expect(i.localEnd, DateTime(2026, 10, 16, 16, 30));
    });

    test('for one meeting of a series, says which', () {
      final i = CalendarInvite.parse(counter(
        recurrence:
            'RECURRENCE-ID;TZID=Eastern Standard Time:20261016T140000\r\n',
      ))!;

      expect(i.recurrenceStart, DateTime.utc(2026, 10, 16, 18));
    });
  });

  group('an answer to your invitation', () {
    test('says who answered and how', () {
      final i = CalendarInvite.parse(
        'BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\n'
        'ATTENDEE;PARTSTAT=ACCEPTED;CN="Levi, Dana":mailto:dana@example.com\r\n'
        'ORGANIZER:mailto:ron@example.com\r\n'
        'UID:abc\r\nSUMMARY:Lunch\r\nDTSTART:20261016T160000Z\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
      )!;

      expect(i.isReply, isTrue);
      expect(i.responder!.display, 'Levi, Dana');
      expect(i.responderAnswer, InviteResponse.accepted);
    });

    test('an invitation has no one answering', () {
      final i = CalendarInvite.parse(
        'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n'
        'ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:ron@example.com\r\n'
        'ORGANIZER:mailto:dana@example.com\r\n'
        'UID:abc\r\nSUMMARY:Lunch\r\nDTSTART:20261016T160000Z\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
      )!;

      expect(i.responder, isNull);
      expect(i.responderAnswer, isNull);
      expect(i.originalStart, isNull);
    });
  });

  group('a meeting on the calendar against the mail about it', () {
    final proposal = CalendarInvite.parse(counter())!;

    CalendarMeeting at(DateTime start, DateTime end, {bool allDay = false}) =>
        CalendarMeeting(
          accountId: 'a',
          eventId: 'e',
          start: start,
          end: end,
          isAllDay: allDay,
        );

    test('is at its time to the minute', () {
      expect(
        at(DateTime.utc(2026, 10, 16, 20), DateTime.utc(2026, 10, 16, 20, 30))
            .isAtTimeOf(proposal),
        isTrue,
      );
      expect(
        at(DateTime.utc(2026, 10, 16, 18), DateTime.utc(2026, 10, 16, 18, 30))
            .isAtTimeOf(proposal),
        isFalse,
        reason: 'the time it has now, not the one proposed',
      );
      expect(
        at(DateTime.utc(2026, 10, 16, 20), DateTime.utc(2026, 10, 16, 21))
            .isAtTimeOf(proposal),
        isFalse,
        reason: 'a different end is a different time',
      );
    });

    test('a whole day is the same day', () {
      final day = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:x\nSUMMARY:Off\n'
        'DTSTART;VALUE=DATE:20261225\nDTEND;VALUE=DATE:20261226\n'
        'END:VEVENT\nEND:VCALENDAR',
      )!;

      expect(
        at(DateTime.utc(2026, 12, 25), DateTime.utc(2026, 12, 26),
                allDay: true)
            .isAtTimeOf(day),
        isTrue,
      );
      expect(
        at(DateTime.utc(2026, 12, 25, 9), DateTime.utc(2026, 12, 25, 10))
            .isAtTimeOf(day),
        isFalse,
        reason: 'a meeting at nine is not the whole day',
      );
    });

    test('cannot be compared with a time whose zone was not worked out', () {
      final far = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:z\n'
        'SUMMARY:Far away\nDTSTART;TZID=Somewhere:20260921T130000\n'
        'END:VEVENT\nEND:VCALENDAR',
      )!;

      expect(
        at(DateTime.utc(2026, 9, 21, 13), DateTime.utc(2026, 9, 21, 14))
            .isAtTimeOf(far),
        isNull,
      );
    });

    test('one meeting of a series is picked by when it was set for', () {
      final week = [
        for (var d = 14; d <= 18; d++) (DateTime.utc(2026, 10, d, 18), 'e-$d'),
      ];

      expect(occurrenceAt(week, DateTime.utc(2026, 10, 16, 18)), 'e-16');
      expect(occurrenceAt(week, DateTime.utc(2026, 10, 16, 19)), isNull,
          reason: 'an hour out is another meeting');
    });

    test('a whole day is the closest to that date, in whatever zone', () {
      // Midnight in New York, as a calendar may give a whole day, is four
      // in the morning UTC; the day before and after are a day away.
      final days = [
        for (var d = 24; d <= 26; d++) (DateTime.utc(2026, 12, d, 5), d),
      ];

      expect(occurrenceAt(days, DateTime(2026, 12, 25)), 25);
    });
  });

  // --- the calendars ---------------------------------------------------------

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json'});

  /// A meeting cancelled by its organiser.
  CalendarInvite cancellation({String recurrence = ''}) => CalendarInvite.parse(
        'BEGIN:VCALENDAR\r\nMETHOD:CANCEL\r\n$eastern'
        'BEGIN:VEVENT\r\n'
        'ORGANIZER;CN=Dana Levi:mailto:dana@example.com\r\n'
        'SUMMARY:Management meeting\r\n'
        'DTSTART;TZID=Eastern Standard Time:20261016T160000\r\n'
        'DTEND;TZID=Eastern Standard Time:20261016T170000\r\n'
        '$recurrence'
        'UID:040000008200E00074C5B7101A82E00800000000CC01\r\n'
        'SEQUENCE:3\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
      )!;

  group('a meeting on a Microsoft calendar', () {
    late List<http.Request> sent;

    GraphCalendarApi api(http.Response Function(http.Request) answer) {
      sent = [];
      return GraphCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer(request);
        }),
        sleep: (_) async {},
      );
    }

    /// An event as Graph gives one asked for in UTC.
    Map<String, Object?> event(
      String id, {
      String start = '2026-10-16T20:00:00.0000000',
      String end = '2026-10-16T21:00:00.0000000',
      bool cancelled = false,
      bool organiser = false,
      String type = 'singleInstance',
      String? originalStart,
    }) =>
        {
          'id': id,
          'start': {'dateTime': start, 'timeZone': 'UTC'},
          'end': {'dateTime': end, 'timeZone': 'UTC'},
          'isAllDay': false,
          'isCancelled': cancelled,
          'isOrganizer': organiser,
          'type': type,
          'originalStart': ?originalStart,
        };

    test('is the one the message links to, read in UTC', () async {
      final found = await api((r) => json(event('e-1', cancelled: true)))
          .meetingFor(cancellation(), accountId: 'a', linkedEventId: 'e-1');

      expect(found!.eventId, 'e-1');
      expect(found.accountId, 'a');
      expect(found.start, DateTime.utc(2026, 10, 16, 20));
      expect(found.end, DateTime.utc(2026, 10, 16, 21));
      expect(found.isCancelled, isTrue);
      expect(found.isOrganizer, isFalse);
      final asked = sent.single;
      expect(asked.url.path, '/v1.0/me/events/e-1');
      expect(asked.url.queryParameters[r'$select'],
          GraphCalendarApi.meetingFields);
      expect(asked.headers['Prefer'], 'outlook.timezone="UTC"',
          reason: 'otherwise Graph answers in the zone it was made in');
    });

    test('is found by the invitation\'s UID where the link is gone',
        () async {
      final found = await api((r) => r.url.path.endsWith('/me/events')
              ? json({
                  'value': [event('e-9')],
                })
              : json({}, 404))
          .meetingFor(cancellation(), accountId: 'a', linkedEventId: 'e-1');

      expect(found!.eventId, 'e-9');
      expect(sent.last.url.queryParameters[r'$filter'],
          "iCalUId eq '040000008200E00074C5B7101A82E00800000000CC01'");
    });

    test('is not on the calendar when neither finds it', () async {
      final found = await api((r) => r.url.path.endsWith('/me/events')
              ? json({'value': []})
              : json({}, 404))
          .meetingFor(cancellation(), accountId: 'a');

      expect(found, isNull);
    });

    test('for one meeting of a series is that meeting, never the series',
        () async {
      // Cancelling this Friday's meeting must not take every Friday's.
      final found = await api((r) {
        if (r.url.path.endsWith('/instances')) {
          return json({
            'value': [
              event('e-thu',
                  type: 'occurrence',
                  originalStart: '2026-10-15T20:00:00Z',
                  start: '2026-10-15T20:00:00.0000000'),
              event('e-fri',
                  type: 'exception',
                  cancelled: true,
                  originalStart: '2026-10-16T20:00:00Z'),
            ],
          });
        }
        return json(event('e-series', type: 'seriesMaster'));
      }).meetingFor(
        cancellation(
          recurrence:
              'RECURRENCE-ID;TZID=Eastern Standard Time:20261016T160000\r\n',
        ),
        accountId: 'a',
        linkedEventId: 'e-series',
      );

      expect(found!.eventId, 'e-fri');
      expect(found.isSeries, isFalse);
      final window = sent.last.url.queryParameters;
      expect(sent.last.url.path, '/v1.0/me/events/e-series/instances');
      expect(DateTime.parse(window['startDateTime']!),
          DateTime.utc(2026, 10, 14, 20));
      expect(DateTime.parse(window['endDateTime']!),
          DateTime.utc(2026, 10, 18, 20));
    });

    test('for one meeting of a series no longer there is nothing', () async {
      final found = await api((r) => r.url.path.endsWith('/instances')
              ? json({'value': []})
              : json(event('e-series', type: 'seriesMaster')))
          .meetingFor(
        cancellation(
          recurrence:
              'RECURRENCE-ID;TZID=Eastern Standard Time:20261016T160000\r\n',
        ),
        accountId: 'a',
        linkedEventId: 'e-series',
      );

      expect(found, isNull, reason: 'not the series in its place');
    });

    test('a whole series cancelled is the series', () async {
      final found = await api((r) => json(event('e-series',
              type: 'seriesMaster', cancelled: true)))
          .meetingFor(cancellation(), accountId: 'a', linkedEventId: 'e-series');

      expect(found!.isSeries, isTrue);
      expect(sent, hasLength(1), reason: 'no instances asked for');
    });

    test('is taken off with a DELETE, and one gone already is done',
        () async {
      await api((_) => http.Response('', 204)).deleteEvent('e-1');
      expect(sent.single.method, 'DELETE');
      expect(sent.single.url.path, '/v1.0/me/events/e-1');

      await api((_) => json({}, 404)).deleteEvent('e-1');

      await expectLater(
        api((_) => json({}, 500)).deleteEvent('e-1'),
        throwsA(isA<ConnectionFailed>()),
      );
    });

    group('moved to a time proposed', () {
      final proposal = CalendarInvite.parse(counter())!;
      final mine = CalendarMeeting(
        accountId: 'a',
        eventId: 'e-1',
        start: DateTime.utc(2026, 10, 16, 18),
        end: DateTime.utc(2026, 10, 16, 18, 30),
        isOrganizer: true,
      );

      test('keeps the zone it was proposed in', () async {
        await api((_) => json(event('e-1'))).moveEvent(mine, proposal);

        final request = sent.single;
        expect(request.method, 'PATCH');
        expect(request.url.path, '/v1.0/me/events/e-1');
        expect(jsonDecode(request.body), {
          'start': {
            'dateTime': '2026-10-16T16:00:00',
            'timeZone': 'Eastern Standard Time',
          },
          'end': {
            'dateTime': '2026-10-16T16:30:00',
            'timeZone': 'Eastern Standard Time',
          },
          'isAllDay': false,
        });
      });

      test('goes in UTC where Graph does not know the zone\'s name',
          () async {
        await api((r) => sent.length == 1
            ? json({
                'error': {'code': 'TimeZoneNotSupportedException'},
              }, 400)
            : json(event('e-1'))).moveEvent(mine, proposal);

        expect(sent, hasLength(2));
        expect(jsonDecode(sent.last.body), {
          'start': {'dateTime': '2026-10-16T20:00:00', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-10-16T20:30:00', 'timeZone': 'UTC'},
          'isAllDay': false,
        });
      });

      test('a refusal says so', () async {
        await expectLater(
          api((_) => json({}, 403)).moveEvent(mine, proposal),
          throwsA(isA<AuthenticationFailed>()),
        );
      });

      test('with no end proposed, keeps its length', () {
        final open = CalendarInvite.parse(
          'BEGIN:VCALENDAR\r\nMETHOD:COUNTER\r\nBEGIN:VEVENT\r\nUID:u\r\n'
          'SUMMARY:x\r\nDTSTART:20261016T200000Z\r\n'
          'END:VEVENT\r\nEND:VCALENDAR\r\n',
        )!;

        expect(GraphCalendarApi.movedTimes(mine, open)['end'],
            {'dateTime': '2026-10-16T20:30:00', 'timeZone': 'UTC'});
      });
    });
  });

  group('a meeting on a Google calendar', () {
    late List<http.Request> sent;

    GoogleCalendarApi api(http.Response Function(http.Request) answer) {
      sent = [];
      return GoogleCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer(request);
        }),
        sleep: (_) async {},
      );
    }

    Map<String, Object?> event(
      String id, {
      String start = '2026-10-16T16:00:00-04:00',
      String end = '2026-10-16T17:00:00-04:00',
      bool organiser = false,
      List<String>? recurrence,
      String? recurringEventId,
      String? originalStart,
      String status = 'confirmed',
    }) =>
        {
          'id': id,
          'status': status,
          'start': {'dateTime': start, 'timeZone': 'America/New_York'},
          'end': {'dateTime': end, 'timeZone': 'America/New_York'},
          'organizer': {'email': 'x@example.com', 'self': organiser},
          'recurrence': ?recurrence,
          'recurringEventId': ?recurringEventId,
          if (originalStart != null)
            'originalStartTime': {'dateTime': originalStart},
        };

    test('is found by its iCalendar UID', () async {
      final found = await api((_) => json({
            'items': [event('g-1', organiser: true)],
          })).meetingFor(cancellation(), accountId: 'g');

      expect(found!.eventId, 'g-1');
      expect(found.start, DateTime.utc(2026, 10, 16, 20));
      expect(found.isOrganizer, isTrue);
      expect(found.timeZone, 'America/New_York');
      expect(sent.single.url.queryParameters['iCalUID'],
          '040000008200E00074C5B7101A82E00800000000CC01');
    });

    test('one Google has as cancelled is not on it', () async {
      final found = await api((_) => json({
            'items': [event('g-1', status: 'cancelled')],
          })).meetingFor(cancellation(), accountId: 'g');

      expect(found, isNull);
    });

    test('one meeting of a series changed before is its own event',
        () async {
      final found = await api((_) => json({
            'items': [
              event('g-series', recurrence: ['RRULE:FREQ=WEEKLY']),
              event('g-series_20261016T200000Z',
                  recurringEventId: 'g-series',
                  originalStart: '2026-10-16T16:00:00-04:00'),
            ],
          })).meetingFor(
        cancellation(
          recurrence:
              'RECURRENCE-ID;TZID=Eastern Standard Time:20261016T160000\r\n',
        ),
        accountId: 'g',
      );

      expect(found!.eventId, 'g-series_20261016T200000Z');
      expect(sent, hasLength(1));
    });

    test('and any other is one of the series\' instances', () async {
      final found = await api((r) => r.url.path.endsWith('/instances')
          ? json({
              'items': [
                event('g-series_20261016T200000Z',
                    recurringEventId: 'g-series',
                    originalStart: '2026-10-16T20:00:00Z'),
              ],
            })
          : json({
              'items': [
                event('g-series', recurrence: ['RRULE:FREQ=WEEKLY']),
              ],
            })).meetingFor(
        cancellation(
          recurrence:
              'RECURRENCE-ID;TZID=Eastern Standard Time:20261016T160000\r\n',
        ),
        accountId: 'g',
      );

      expect(found!.eventId, 'g-series_20261016T200000Z');
      expect(found.isSeries, isFalse);
      expect(sent.last.url.path,
          '/calendar/v3/calendars/primary/events/g-series/instances');
    });

    test('is taken off telling nobody', () async {
      await api((_) => http.Response('', 204)).deleteEvent('g-1');

      expect(sent.single.method, 'DELETE');
      expect(sent.single.url.queryParameters['sendUpdates'], 'none');
      await api((_) => json({}, 410)).deleteEvent('g-1');
    });

    test('is moved with everyone told, in the zone it keeps', () async {
      final mine = CalendarMeeting(
        accountId: 'g',
        eventId: 'g-1',
        start: DateTime.utc(2026, 10, 16, 18),
        end: DateTime.utc(2026, 10, 16, 18, 30),
        isOrganizer: true,
        timeZone: 'America/New_York',
      );

      await api((_) => json(event('g-1')))
          .moveEvent(mine, CalendarInvite.parse(counter())!);

      final request = sent.single;
      expect(request.method, 'PATCH');
      expect(request.url.queryParameters['sendUpdates'], 'all');
      expect(jsonDecode(request.body), {
        'start': {
          'dateTime': '2026-10-16T20:00:00Z',
          'timeZone': 'America/New_York',
          'date': null,
        },
        'end': {
          'dateTime': '2026-10-16T20:30:00Z',
          'timeZone': 'America/New_York',
          'date': null,
        },
      });
    });
  });

  group('an account\'s calendar', () {
    const microsoft = Account(
      id: 'acct-ms',
      displayName: 'Work',
      emailAddress: 'ron@contoso.com',
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF0F6CBD,
    );
    const appPassword = Account(
      id: 'acct-p',
      displayName: 'Old',
      emailAddress: 'old@gmail.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFFB4009E,
    );

    late List<http.Request> sent;
    late List<List<String>?> askedFor;

    AccountCalendar calendar() {
      sent = [];
      askedFor = [];
      return AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async {
          askedFor.add(scopes);
          return 'token';
        },
        accounts: () => const [microsoft, appPassword],
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return http.Response('', 204);
        }),
        sleep: (_) async {},
      );
    }

    CalendarMeeting meeting({bool organiser = false, bool series = false}) =>
        CalendarMeeting(
          accountId: 'acct-ms',
          eventId: 'e-1',
          start: DateTime.utc(2026, 10, 16, 18),
          isOrganizer: organiser,
          isSeries: series,
        );

    test('is asked with the calendar\'s own consent', () async {
      await calendar().removeMeeting(microsoft, meeting());

      expect(sent.single.method, 'DELETE');
      expect(askedFor.single, MicrosoftOAuth.calendarScopes);
    });

    test('an app password has none to look in or change', () async {
      final c = calendar();
      await expectLater(c.meetingFor(appPassword, cancellation()),
          throwsA(isA<CalendarUnavailable>()));
      await expectLater(c.removeMeeting(appPassword, meeting()),
          throwsA(isA<CalendarUnavailable>()));
      await expectLater(
          c.moveMeeting(appPassword, meeting(organiser: true),
              CalendarInvite.parse(counter())!),
          throwsA(isA<CalendarUnavailable>()));
      expect(sent, isEmpty);
    });

    test('never takes off a meeting you organised', () async {
      // On the organiser's calendar a delete is a cancellation, sent to
      // everyone on it.
      await expectLater(
        calendar().removeMeeting(microsoft, meeting(organiser: true)),
        throwsA(isA<ArgumentError>()),
      );
      expect(sent, isEmpty);
    });

    test('moves only a meeting you organised, and not a whole series',
        () async {
      final proposal = CalendarInvite.parse(counter())!;
      final c = calendar();

      await expectLater(c.moveMeeting(microsoft, meeting(), proposal),
          throwsA(isA<ArgumentError>()));
      await expectLater(
          c.moveMeeting(
              microsoft, meeting(organiser: true, series: true), proposal),
          throwsA(isA<ArgumentError>()));
      expect(sent, isEmpty);
    });
  });

  group('the engine', () {
    test('asks an app password account\'s server nothing', () async {
      final server = FakeImapTransport();
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      final added = await engine.addAccount(
        displayName: 'Old',
        emailAddress: 'old@gmail.com',
        provider: MailProvider.gmail,
        secret: 'app-password',
      );
      server.calls.clear();

      await expectLater(
        engine.meetingOnCalendar('${added.id}:INBOX#1', cancellation()),
        throwsA(isA<CalendarUnavailable>()),
      );
      expect(server.calls, isNot(contains(startsWith('LINKED EVENT'))));
    });
  });

  group('Graph\'s meeting mail', () {
    test('is meeting mail whichever of the three types it is', () {
      for (final type in const [
        '#microsoft.graph.eventMessage',
        '#microsoft.graph.eventMessageRequest',
        '#microsoft.graph.eventMessageResponse',
      ]) {
        expect(GraphMailApi.isMeetingMessage({'@odata.type': type}), isTrue,
            reason: type);
      }
      expect(GraphMailApi.isMeetingMessage({'@odata.type': '#microsoft.graph.message'}),
          isFalse);
      expect(GraphMailApi.isMeetingMessage({'meetingMessageType': 'meetingCancelled'}),
          isTrue);
    });

    test('an invitation\'s and an answer\'s list rows have the calendar mark',
        () {
      // The mark came from the type, which only a cancellation matched.
      for (final type in const [
        '#microsoft.graph.eventMessageRequest',
        '#microsoft.graph.eventMessageResponse',
      ]) {
        final row = GraphMessage.fromJson({
          '@odata.type': type,
          'id': 'm1',
          'subject': 'Q3 review',
          'receivedDateTime': '2026-10-11T20:25:00Z',
        });
        expect(row!.isMeeting, isTrue, reason: type);
      }
    });
  });
}
