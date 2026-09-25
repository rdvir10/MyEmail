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
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting.dart';

import 'fakes/fake_imap_transport.dart';

/// A meeting on its way to a calendar: what one is, how each kind of
/// account creates it, and what each refusal means.
void main() {
  const microsoft = Account(
    id: 'acct-ms',
    displayName: 'Work',
    emailAddress: 'ron@contoso.com',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );
  const google = Account(
    id: 'acct-g',
    displayName: 'Personal',
    emailAddress: 'ron@gmail.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF107C41,
  );
  const appPassword = Account(
    id: 'acct-p',
    displayName: 'Old',
    emailAddress: 'old@gmail.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0xFFB4009E,
  );

  MeetingDraft meeting({
    String accountId = 'acct-ms',
    String title = 'Q3 review',
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    String? timeZone = 'Asia/Jerusalem',
  }) =>
      MeetingDraft(
        accountId: accountId,
        title: title,
        attendees: const [
          MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
          MailAddress(email: 'sam@example.com'),
        ],
        start: start ?? DateTime(2026, 10, 1, 9),
        end: end ?? DateTime(2026, 10, 1, 10),
        allDay: allDay,
        location: 'Room 4',
        notes: 'Bring the numbers.',
        timeZone: timeZone,
      );

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json'});

  group('MeetingDraft', () {
    test('needs a title', () {
      expect(meeting(title: '  ').problem, 'Give the meeting a title.');
      expect(meeting().problem, isNull);
      expect(meeting().isValid, isTrue);
    });

    test('needs an end after the start', () {
      final at = DateTime(2026, 10, 1, 9);
      expect(meeting(start: at, end: at).problem,
          'The meeting has to end after it starts.');
      expect(
        meeting(start: at, end: at.subtract(const Duration(hours: 1))).problem,
        'The meeting has to end after it starts.',
      );
    });

    test('a whole day may start and end on the same day', () {
      final day = DateTime(2026, 10, 1);
      expect(meeting(allDay: true, start: day, end: day).problem, isNull);
      expect(
        meeting(allDay: true, start: day, end: DateTime(2026, 9, 30)).problem,
        'The last day cannot be before the first.',
      );
    });

    test('the times are sent on the device\'s clock when it named its zone',
        () {
      final sent = meeting().asSent;
      expect(sent.timeZone, 'Asia/Jerusalem');
      expect(sent.start, DateTime(2026, 10, 1, 9));
      expect(sent.start.isUtc, isFalse);
    });

    test('and as UTC when it did not', () {
      final sent = meeting(timeZone: null).asSent;
      expect(sent.timeZone, 'UTC');
      expect(sent.start.isUtc, isTrue);
      expect(sent.start, DateTime(2026, 10, 1, 9).toUtc());
      expect(sent.end, DateTime(2026, 10, 1, 10).toUtc());
    });

    test('a whole day keeps its dates whatever the zone', () {
      // Moved to UTC, 1 October at midnight in Israel is 30 September.
      final day = DateTime(2026, 10, 1);
      final sent = meeting(allDay: true, start: day, end: day, timeZone: null)
          .asSent;
      expect(sent.start, day);
      expect(sent.start.isUtc, isFalse);
    });

    test('the day after is built from the date, not by adding a day', () {
      expect(dayAfter(DateTime(2026, 10, 31)), DateTime(2026, 11, 1));
      expect(dayAfter(DateTime(2026, 12, 31)), DateTime(2027, 1, 1));
      expect(dayAfter(DateTime.utc(2026, 2, 28)), DateTime.utc(2026, 3, 1));
      expect(dayAfter(DateTime.utc(2026, 2, 28)).isUtc, isTrue);
    });
  });

  group('GraphCalendarApi', () {
    late List<http.Request> sent;
    late List<bool> asked;
    late List<Duration> slept;

    setUp(() {
      sent = [];
      asked = [];
      slept = [];
    });

    GraphCalendarApi api(
      Future<http.Response> Function(http.Request request) handler, {
      Future<String> Function({bool force})? token,
    }) =>
        GraphCalendarApi(
          accessToken: token ??
              ({bool force = false}) async {
                asked.add(force);
                return force ? 'fresh' : 'stale';
              },
          httpClient: http_testing.MockClient((request) async {
            sent.add(request);
            return handler(request);
          }),
          sleep: (d) async => slept.add(d),
        );

    test('posts the event to /me/events in Graph\'s shape', () async {
      final id = await api((_) async => json({'id': 'evt-1'}, 201))
          .createEvent(meeting());

      expect(id, 'evt-1');
      final request = sent.single;
      expect(request.method, 'POST');
      expect(request.url.toString(),
          'https://graph.microsoft.com/v1.0/me/events');
      expect(request.headers['Authorization'], 'Bearer stale');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      final body = jsonDecode(request.body) as Map;
      expect(body['subject'], 'Q3 review');
      expect(body['body'], {'contentType': 'text', 'content': 'Bring the numbers.'});
      expect(body['start'],
          {'dateTime': '2026-10-01T09:00:00', 'timeZone': 'Asia/Jerusalem'});
      expect(body['end'],
          {'dateTime': '2026-10-01T10:00:00', 'timeZone': 'Asia/Jerusalem'});
      expect(body['isAllDay'], isFalse);
      expect(body['location'], {'displayName': 'Room 4'});
      expect(body['attendees'], [
        {
          'emailAddress': {'address': 'dana@example.com', 'name': 'Dana Levi'},
          'type': 'required',
        },
        {
          'emailAddress': {'address': 'sam@example.com'},
          'type': 'required',
        },
      ]);
      expect(body['isOnlineMeeting'], isFalse);
    });

    test('a whole day ends at the next day\'s midnight', () async {
      await api((_) async => json({'id': 'evt-1'}, 201)).createEvent(
        meeting(
          allDay: true,
          start: DateTime(2026, 10, 1),
          end: DateTime(2026, 10, 2),
        ),
      );

      final body = jsonDecode(sent.single.body) as Map;
      expect(body['isAllDay'], isTrue);
      expect(body['start'],
          {'dateTime': '2026-10-01T00:00:00', 'timeZone': 'Asia/Jerusalem'});
      expect(body['end'],
          {'dateTime': '2026-10-03T00:00:00', 'timeZone': 'Asia/Jerusalem'});
    });

    test('with no zone from the device the times go as UTC', () async {
      await api((_) async => json({'id': 'evt-1'}, 201))
          .createEvent(meeting(timeZone: null));

      final body = jsonDecode(sent.single.body) as Map;
      final utc = DateTime(2026, 10, 1, 9).toUtc();
      expect(body['start'], {
        'dateTime': '${utc.year}-${_two(utc.month)}-${_two(utc.day)}T'
            '${_two(utc.hour)}:${_two(utc.minute)}:00',
        'timeZone': 'UTC',
      });
    });

    test('a refused token is refreshed once and the request sent again',
        () async {
      await api((request) async =>
          request.headers['Authorization'] == 'Bearer fresh'
              ? json({'id': 'evt-1'}, 201)
              : json({'error': {'code': 'InvalidAuthenticationToken'}}, 401))
          .createEvent(meeting());

      expect(asked, [false, true]);
      expect(sent, hasLength(2));
      expect(sent.last.headers['Authorization'], 'Bearer fresh');
    });

    test('a second refusal is the sign-in being dead', () async {
      await expectLater(
        api((_) async => json({'error': {'code': 'InvalidAuthenticationToken'}}, 401))
            .createEvent(meeting()),
        throwsA(isA<AuthenticationFailed>()),
      );
      expect(sent, hasLength(2), reason: 'once fresh, then no more');
    });

    test('throttled, it waits as long as Graph asks and tries again',
        () async {
      var calls = 0;
      await api((_) async => ++calls == 1
          ? http.Response('', 429, headers: const {'retry-after': '3'})
          : json({'id': 'evt-1'}, 201)).createEvent(meeting());

      expect(sent, hasLength(2));
      expect(slept, [const Duration(seconds: 3)]);
    });

    test('a forbidden calendar names the administrator', () async {
      await expectLater(
        api((_) async => json({'error': {'code': 'ErrorAccessDenied'}}, 403))
            .createEvent(meeting()),
        throwsA(isA<AuthenticationFailed>().having(
            (e) => e.message, 'message', contains('administrator'))),
      );
    });

    test('Graph\'s own sentence is kept on a refusal', () async {
      await expectLater(
        api((_) async => json({
              'error': {
                'code': 'ErrorPropertyValidationFailure',
                'message': 'End date must be after the start.',
              }
            }, 400))
            .createEvent(meeting()),
        throwsA(isA<ConnectionFailed>().having(
          (e) => e.message,
          'message',
          allOf(contains('ErrorPropertyValidationFailure'),
              contains('End date must be after the start.')),
        )),
      );
    });

    test('a refresh refused for want of consent is the screen\'s to answer',
        () async {
      await expectLater(
        api(
          (_) async => json({'id': 'evt-1'}, 201),
          token: ({bool force = false}) async =>
              throw const SignInNeedsConsent('Not allowed the calendar.'),
        ).createEvent(meeting()),
        throwsA(isA<SignInNeedsConsent>()),
      );
      expect(sent, isEmpty);
    });

    test('a refresh that could not reach Microsoft is no connection',
        () async {
      await expectLater(
        api(
          (_) async => json({'id': 'evt-1'}, 201),
          token: ({bool force = false}) async =>
              throw const SignInUnreachable('No route to Microsoft.'),
        ).createEvent(meeting()),
        throwsA(isA<ConnectionFailed>()),
      );
    });
  });

  group('GoogleCalendarApi', () {
    late List<http.Request> sent;
    late List<bool> asked;

    setUp(() {
      sent = [];
      asked = [];
    });

    GoogleCalendarApi api(
      Future<http.Response> Function(http.Request request) handler,
    ) =>
        GoogleCalendarApi(
          accessToken: ({bool force = false}) async {
            asked.add(force);
            return force ? 'fresh' : 'stale';
          },
          httpClient: http_testing.MockClient((request) async {
            sent.add(request);
            return handler(request);
          }),
        );

    test('posts the event to the primary calendar, invitations sent',
        () async {
      final id = await api((_) async => json({'id': 'evt-g'}))
          .createEvent(meeting(accountId: 'acct-g'));

      expect(id, 'evt-g');
      final request = sent.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://www.googleapis.com/calendar/v3/calendars/primary/events'
        '?sendUpdates=all',
      );
      expect(request.headers['Authorization'], 'Bearer stale');
      final body = jsonDecode(request.body) as Map;
      expect(body['summary'], 'Q3 review');
      expect(body['description'], 'Bring the numbers.');
      expect(body['location'], 'Room 4');
      expect(body['start'],
          {'dateTime': '2026-10-01T09:00:00', 'timeZone': 'Asia/Jerusalem'});
      expect(body['end'],
          {'dateTime': '2026-10-01T10:00:00', 'timeZone': 'Asia/Jerusalem'});
      expect(body['attendees'], [
        {'email': 'dana@example.com', 'displayName': 'Dana Levi'},
        {'email': 'sam@example.com'},
      ]);
    });

    test('a whole day is dates, ending the day after the last', () async {
      await api((_) async => json({'id': 'evt-g'})).createEvent(meeting(
        allDay: true,
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 1),
      ));

      final body = jsonDecode(sent.single.body) as Map;
      expect(body['start'], {'date': '2026-10-01'});
      expect(body['end'], {'date': '2026-10-02'});
    });

    test('a refused token is refreshed once and the request sent again',
        () async {
      await api((request) async =>
          request.headers['Authorization'] == 'Bearer fresh'
              ? json({'id': 'evt-g'})
              : json({'error': {'code': 401, 'message': 'Invalid Credentials'}}, 401))
          .createEvent(meeting());

      expect(asked, [false, true]);
      expect(sent, hasLength(2));
    });

    test('a quota run out is worth waiting for; a refused calendar is not',
        () async {
      http.Response forbidden(String reason) => json({
            'error': {
              'code': 403,
              'message': 'Forbidden',
              'errors': [
                {'domain': 'usageLimits', 'reason': reason},
              ],
            }
          }, 403);

      await expectLater(
        api((_) async => forbidden('rateLimitExceeded')).createEvent(meeting()),
        throwsA(isA<ConnectionFailed>()),
      );
      await expectLater(
        api((_) async => forbidden('insufficientPermissions'))
            .createEvent(meeting()),
        throwsA(isA<AuthenticationFailed>()),
      );
    });

    test('Google\'s own sentence is kept on a refusal', () async {
      await expectLater(
        api((_) async => json({
              'error': {'code': 400, 'message': 'The specified time range is empty.'}
            }, 400))
            .createEvent(meeting()),
        throwsA(isA<ConnectionFailed>().having((e) => e.message, 'message',
            contains('The specified time range is empty.'))),
      );
    });
  });

  group('AccountCalendar', () {
    late List<http.Request> sent;
    late List<(String, List<String>?)> asked;

    setUp(() {
      sent = [];
      asked = [];
    });

    AccountCalendar calendar() => AccountCalendar(
          accessToken: (accountId, {bool force = false, List<String>? scopes}) async {
            asked.add((accountId, scopes));
            return 'token';
          },
          httpClient: http_testing.MockClient((request) async {
            sent.add(request);
            return json({'id': 'evt'}, 201);
          }),
          sleep: (_) async {},
        );

    test('a Microsoft account goes to Graph, on the calendar\'s own token',
        () async {
      await calendar().createMeeting(microsoft, meeting());

      expect(sent.single.url.host, 'graph.microsoft.com');
      expect(asked, [('acct-ms', MicrosoftOAuth.calendarScopes)]);
    });

    test('a Google account goes to Google Calendar on its mail token',
        () async {
      await calendar().createMeeting(google, meeting(accountId: 'acct-g'));

      expect(sent.single.url.host, 'www.googleapis.com');
      expect(asked, [('acct-g', null)]);
    });

    test('a Gmail account with an app password has no calendar to reach',
        () async {
      await expectLater(
        calendar().createMeeting(appPassword, meeting(accountId: 'acct-p')),
        throwsA(isA<CalendarUnavailable>()),
      );
      expect(sent, isEmpty);
      expect(asked, isEmpty);
    });

    test('a meeting the screen should have refused is a bug, not a request',
        () async {
      await expectLater(
        calendar().createMeeting(microsoft, meeting(title: '')),
        throwsA(isA<ArgumentError>()),
      );
      expect(sent, isEmpty);
    });
  });

  group('CachedImapEngine.createMeeting', () {
    test('finds the account and hands the meeting to its calendar', () async {
      final accounts = MemoryAccountStore();
      final engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => FakeImapTransport(),
      );
      final added = await engine.addAccount(
        displayName: 'Old',
        emailAddress: 'old@gmail.com',
        provider: MailProvider.gmail,
        secret: 'app-password',
      );

      // An app password reaches the mail and nothing else: the one answer
      // the engine can give without a server, and the screen's cue to hand
      // the meeting to the phone's calendar app.
      await expectLater(
        engine.createMeeting(meeting(accountId: added.id)),
        throwsA(isA<CalendarUnavailable>()),
      );
      await expectLater(
        engine.createMeeting(meeting(accountId: 'acct-nobody')),
        throwsA(isA<StateError>()),
      );
    });
  });
}

String _two(int n) => n.toString().padLeft(2, '0');
