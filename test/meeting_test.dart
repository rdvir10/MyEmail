import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/google_oauth.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/calendar/google_meet_api.dart';
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
    OnlineMeetingKind? online,
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
        online: online,
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

    test('is held online only when asked', () {
      final bare = MeetingDraft(
        accountId: 'acct-ms',
        title: 'Q3 review',
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 1, 10),
      );
      expect(bare.online, isNull);
      expect(bare.isOnline, isFalse);
      final teams = meeting(online: OnlineMeetingKind.teams);
      expect(teams.online, OnlineMeetingKind.teams);
      expect(teams.isOnline, isTrue);
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
      final created = await api((_) async => json({'id': 'evt-1'}, 201))
          .createEvent(meeting());

      expect(created.id, 'evt-1');
      expect(created.joinUrl, isNull);
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

    test('held online, it is held where the calendar said, and the link '
        'comes back', () async {
      final created = await api((_) async => json({
            'id': 'evt-1',
            'onlineMeeting': {
              'joinUrl': 'https://teams.microsoft.com/l/meetup-join/abc',
            },
          }, 201)).createEvent(
        meeting(online: OnlineMeetingKind.teams),
        onlineMeetingProvider: 'teamsForBusiness',
      );

      final body = jsonDecode(sent.single.body) as Map;
      expect(body['isOnlineMeeting'], isTrue);
      expect(body['onlineMeetingProvider'], 'teamsForBusiness');
      expect(created.joinUrl, 'https://teams.microsoft.com/l/meetup-join/abc');
    });

    test('not held online, no provider is named whatever was found',
        () async {
      final created = await api((_) async => json({'id': 'evt-1'}, 201))
          .createEvent(meeting(), onlineMeetingProvider: 'teamsForBusiness');

      final body = jsonDecode(sent.single.body) as Map;
      expect(body['isOnlineMeeting'], isFalse);
      expect(body.containsKey('onlineMeetingProvider'), isFalse);
      expect(created.joinUrl, isNull);
    });

    test('held on Google Meet, the link made elsewhere is the body\'s last '
        'line and the location, and no Teams link is asked for', () async {
      final created = await api((_) async => json({'id': 'evt-1'}, 201))
          .createEvent(
        MeetingDraft(
          accountId: 'acct-ms',
          title: 'Q3 review',
          start: DateTime(2026, 10, 1, 9),
          end: DateTime(2026, 10, 1, 10),
          notes: 'Bring the numbers.',
          online: OnlineMeetingKind.googleMeet,
        ),
        onlineMeetingProvider: 'teamsForBusiness',
        joinUrl: 'https://meet.google.com/abc-defg-hij',
      );

      final body = jsonDecode(sent.single.body) as Map;
      expect(body['isOnlineMeeting'], isFalse);
      expect(body.containsKey('onlineMeetingProvider'), isFalse);
      expect(body['body'], {
        'contentType': 'text',
        'content': 'Bring the numbers.\n\nJoin with Google Meet: https://meet.google.com/abc-defg-hij',
      });
      expect(body['location'], {'displayName': 'https://meet.google.com/abc-defg-hij'});
      expect(created.joinUrl, 'https://meet.google.com/abc-defg-hij');
    });

    test('a location given keeps its place, and the link is the whole body '
        'where there were no notes', () async {
      await api((_) async => json({'id': 'evt-1'}, 201)).createEvent(
        meeting(online: OnlineMeetingKind.googleMeet),
        joinUrl: 'https://meet.google.com/abc-defg-hij',
      );
      var body = jsonDecode(sent.single.body) as Map;
      expect(body['location'], {'displayName': 'Room 4'});
      expect((body['body'] as Map)['content'],
          'Bring the numbers.\n\nJoin with Google Meet: https://meet.google.com/abc-defg-hij');

      sent.clear();
      await api((_) async => json({'id': 'evt-1'}, 201)).createEvent(
        MeetingDraft(
          accountId: 'acct-ms',
          title: 'Q3 review',
          start: DateTime(2026, 10, 1, 9),
          end: DateTime(2026, 10, 1, 10),
          online: OnlineMeetingKind.googleMeet,
        ),
        joinUrl: 'https://meet.google.com/abc-defg-hij',
      );
      body = jsonDecode(sent.single.body) as Map;
      expect((body['body'] as Map)['content'],
          'Join with Google Meet: https://meet.google.com/abc-defg-hij');
    });

    group('asking where the calendar holds meetings online', () {
      Future<GraphOnlineMeetings?> ask(Map<String, Object?> calendar) =>
          api((_) async => json(calendar)).onlineMeetings();

      test('reads the calendar, the two properties and nothing else',
          () async {
        await ask({'allowedOnlineMeetingProviders': ['teamsForBusiness']});

        final request = sent.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/v1.0/me/calendar');
        expect(request.url.queryParameters[r'$select'],
            'allowedOnlineMeetingProviders,defaultOnlineMeetingProvider');
        expect(request.headers['Authorization'], 'Bearer stale');
      });

      test('Teams wherever it is allowed, whatever the default', () async {
        final found = await ask({
          'allowedOnlineMeetingProviders': ['skypeForBusiness', 'teamsForBusiness'],
          'defaultOnlineMeetingProvider': 'skypeForBusiness',
        });

        expect(found!.kind, OnlineMeetingKind.teams);
        expect(found.provider, 'teamsForBusiness');
      });

      test('otherwise the default: Skype on a personal mailbox', () async {
        final found = await ask({
          'allowedOnlineMeetingProviders': ['skypeForConsumer'],
          'defaultOnlineMeetingProvider': 'skypeForConsumer',
        });

        expect(found!.kind, OnlineMeetingKind.skype);
        expect(found.provider, 'skypeForConsumer');
      });

      test('a default the app has no name for is still somewhere', () async {
        final found = await ask({
          'allowedOnlineMeetingProviders': ['skypeForBusiness'],
          'defaultOnlineMeetingProvider': 'skypeForBusiness',
        });

        expect(found!.kind, OnlineMeetingKind.other);
        expect(found.provider, 'skypeForBusiness');
      });

      test('nothing allowed and no default is nowhere', () async {
        expect(
          await ask({
            'allowedOnlineMeetingProviders': <String>[],
            'defaultOnlineMeetingProvider': 'unknown',
          }),
          isNull,
        );
        expect(await ask({}), isNull);
      });

      test('a refusal is thrown, for the caller to read as nowhere',
          () async {
        await expectLater(
          api((_) async => json({'error': {'code': 'ErrorAccessDenied'}}, 403))
              .onlineMeetings(),
          throwsA(isA<AuthenticationFailed>()),
        );
      });
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
      final created = await api((_) async => json({'id': 'evt-g'}))
          .createEvent(meeting(accountId: 'acct-g'));

      expect(created.id, 'evt-g');
      expect(created.joinUrl, isNull);
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

    test('held online, it asks for a Meet link and reads it back', () async {
      final created = await api((_) async => json({
            'id': 'evt-g',
            'conferenceData': {
              'entryPoints': [
                {'entryPointType': 'phone', 'uri': 'tel:+1-555-0100'},
                {
                  'entryPointType': 'video',
                  'uri': 'https://meet.google.com/abc-defg-hij',
                },
              ],
            },
          })).createEvent(meeting(online: OnlineMeetingKind.googleMeet));

      final request = sent.single;
      // Without this the ask in the event is dropped without a word.
      expect(request.url.queryParameters['conferenceDataVersion'], '1');
      expect(request.url.queryParameters['sendUpdates'], 'all');
      final body = jsonDecode(request.body) as Map;
      final ask = (body['conferenceData'] as Map)['createRequest'] as Map;
      expect(ask['conferenceSolutionKey'], {'type': 'hangoutsMeet'});
      expect(ask['requestId'], isA<String>().having((s) => s.length, 'length',
          greaterThanOrEqualTo(16)));
      expect(created.joinUrl, 'https://meet.google.com/abc-defg-hij');
    });

    test('each ask for a link has a request id of its own', () async {
      final client = api((_) async => json({'id': 'evt-g'}));
      await client.createEvent(meeting(online: OnlineMeetingKind.googleMeet));
      await client.createEvent(meeting(online: OnlineMeetingKind.googleMeet));

      String idOf(http.Request r) =>
          (((jsonDecode(r.body) as Map)['conferenceData'] as Map)['createRequest']
              as Map)['requestId'] as String;
      expect(idOf(sent.first), isNot(idOf(sent.last)));
    });

    test('not held online, nothing is asked for and there is no link',
        () async {
      final created =
          await api((_) async => json({'id': 'evt-g'})).createEvent(meeting());

      expect(sent.single.url.queryParameters.containsKey('conferenceDataVersion'),
          isFalse);
      expect((jsonDecode(sent.single.body) as Map).containsKey('conferenceData'),
          isFalse);
      expect(created.joinUrl, isNull);
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

  group('GoogleMeetApi', () {
    late List<http.Request> sent;
    late List<bool> asked;

    setUp(() {
      sent = [];
      asked = [];
    });

    GoogleMeetApi api(
      Future<http.Response> Function(http.Request request) handler,
    ) =>
        GoogleMeetApi(
          accessToken: ({bool force = false}) async {
            asked.add(force);
            return force ? 'fresh' : 'stale';
          },
          httpClient: http_testing.MockClient((request) async {
            sent.add(request);
            return handler(request);
          }),
        );

    http.Response space() => json({
          'name': 'spaces/abc',
          'meetingUri': 'https://meet.google.com/abc-defg-hij',
          'meetingCode': 'abc-defg-hij',
        });

    /// A refusal in the Meet API's envelope, which puts the reason under
    /// `details` rather than the calendar's `errors`.
    http.Response forbidden(String reason, {String message = 'Forbidden'}) =>
        json({
          'error': {
            'code': 403,
            'message': message,
            'status': 'PERMISSION_DENIED',
            'details': [
              {
                '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
                'reason': reason,
              },
            ],
          }
        }, 403);

    test('makes a space and answers with the link to join it', () async {
      final link = await api((_) async => space()).createSpace();

      expect(link, 'https://meet.google.com/abc-defg-hij');
      final request = sent.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://meet.googleapis.com/v2/spaces');
      expect(request.headers['Authorization'], 'Bearer stale');
      expect(jsonDecode(request.body), <String, Object?>{});
    });

    test('a refused token is refreshed once and the request sent again',
        () async {
      final link = await api((request) async =>
          request.headers['Authorization'] == 'Bearer fresh'
              ? space()
              : json({'error': {'code': 401, 'status': 'UNAUTHENTICATED'}}, 401))
          .createSpace();

      expect(link, 'https://meet.google.com/abc-defg-hij');
      expect(asked, [false, true]);
      expect(sent, hasLength(2));
    });

    test('a second refusal is the sign-in being dead', () async {
      await expectLater(
        api((_) async => json({'error': {'code': 401}}, 401)).createSpace(),
        throwsA(isA<AuthenticationFailed>()),
      );
      expect(sent, hasLength(2), reason: 'once fresh, then no more');
    });

    test('the API switched off in the project names the switch', () async {
      await expectLater(
        api((_) async => forbidden(
              'SERVICE_DISABLED',
              message: 'Google Meet API has not been used in project 1 '
                  'before or it is disabled.',
            )).createSpace(),
        throwsA(isA<ConnectionFailed>().having(
            (e) => e.message, 'message', contains('Google Meet API'))),
      );
    });

    test('a token that does not cover Meet is a sign-in again, for the '
        'screen to offer', () async {
      await expectLater(
        api((_) async => forbidden('ACCESS_TOKEN_SCOPE_INSUFFICIENT'))
            .createSpace(),
        throwsA(isA<SignInNeedsConsent>()),
      );
    });

    test('a quota run out is worth waiting for', () async {
      await expectLater(
        api((_) async =>
                json({'error': {'code': 429, 'status': 'RESOURCE_EXHAUSTED'}}, 429))
            .createSpace(),
        throwsA(isA<ConnectionFailed>().having(
            (e) => e.message, 'message', contains('rate limiting'))),
      );
    });

    test('a space with no link in it is no space', () async {
      await expectLater(
        api((_) async => json({'name': 'spaces/abc'})).createSpace(),
        throwsA(isA<ConnectionFailed>()),
      );
    });

    test('Google\'s own sentence is kept on a refusal', () async {
      await expectLater(
        api((_) async => json({
              'error': {'code': 400, 'message': 'Request contains an invalid argument.'}
            }, 400)).createSpace(),
        throwsA(isA<ConnectionFailed>().having(
            (e) => e.message, 'message', contains('invalid argument'))),
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

    /// A calendar whose server answers with [answer], an event created
    /// otherwise, among [accounts], and whose token is refused for want of
    /// consent when [consent] is false, or for Meet alone when
    /// [meetConsent] is.
    AccountCalendar calendar({
      http.Response Function(http.Request request)? answer,
      bool consent = true,
      bool meetConsent = true,
      List<Account> accounts = const [microsoft, appPassword],
    }) =>
        AccountCalendar(
          accessToken: (accountId, {bool force = false, List<String>? scopes}) async {
            asked.add((accountId, scopes));
            if (!consent) {
              throw const SignInNeedsConsent('Not allowed the calendar.');
            }
            if (!meetConsent &&
                (scopes?.contains(GoogleOAuth.meetScopes.single) ?? false)) {
              throw const SignInNeedsConsent('Not allowed Meet.');
            }
            return 'token';
          },
          accounts: () => accounts,
          httpClient: http_testing.MockClient((request) async {
            sent.add(request);
            return answer?.call(request) ?? json({'id': 'evt'}, 201);
          }),
          sleep: (_) async {},
        );

    /// A Microsoft calendar that holds meetings on Teams.
    http.Response teamsCalendar(http.Request request) => request.method == 'GET'
        ? json({
            'allowedOnlineMeetingProviders': ['teamsForBusiness'],
            'defaultOnlineMeetingProvider': 'teamsForBusiness',
          })
        : json({'id': 'evt'}, 201);

    /// The same, with a Google beside it that makes Meet spaces.
    http.Response meetAndTeams(http.Request request) =>
        request.url.host == 'meet.googleapis.com'
            ? json({'meetingUri': 'https://meet.google.com/abc-defg-hij'})
            : teamsCalendar(request);

    const everyone = [microsoft, google, appPassword];

    group('where meetings are held online', () {
      test('a Microsoft account is asked once, on the calendar\'s token, and '
          'remembered', () async {
        final c = calendar(answer: teamsCalendar);

        expect(await c.onlineMeetingsFor(microsoft), [OnlineMeetingKind.teams]);
        expect(await c.onlineMeetingsFor(microsoft), [OnlineMeetingKind.teams]);

        expect(sent.where((r) => r.method == 'GET'), hasLength(1));
        expect(asked.single, ('acct-ms', MicrosoftOAuth.calendarScopes));
      });

      test('and a meeting held online is held where the calendar said',
          () async {
        final c = calendar(answer: teamsCalendar);

        await c.createMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.teams),
        );

        final post = sent.singleWhere((r) => r.method == 'POST');
        final body = jsonDecode(post.body) as Map;
        expect(body['isOnlineMeeting'], isTrue);
        expect(body['onlineMeetingProvider'], 'teamsForBusiness');
        expect(sent.where((r) => r.method == 'GET'), hasLength(1),
            reason: 'asked on the way, and kept');
      });

      test('a calendar that could not be asked holds none, says so in the '
          'log, and is asked again next time', () async {
        final logged = <String>[];
        final was = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) =>
            logged.add(message ?? '');
        addTearDown(() => debugPrint = was);
        var refused = true;
        final c = calendar(answer: (request) => refused
            ? json({'error': {'code': 'ErrorAccessDenied'}}, 403)
            : teamsCalendar(request));

        expect(await c.onlineMeetingsFor(microsoft), isEmpty);
        expect(logged.single, contains('online meetings'));

        refused = false;
        expect(await c.onlineMeetingsFor(microsoft), [OnlineMeetingKind.teams]);
        expect(sent.where((r) => r.method == 'GET'), hasLength(2));
      });

      test('no consent yet holds none rather than failing', () async {
        final was = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {};
        addTearDown(() => debugPrint = was);

        expect(
          await calendar(consent: false).onlineMeetingsFor(microsoft),
          isEmpty,
        );
        expect(sent, isEmpty);
      });

      test('a Google account has Meet, and is not asked', () async {
        expect(
          await calendar().onlineMeetingsFor(google),
          [OnlineMeetingKind.googleMeet],
        );
        expect(sent, isEmpty);
        expect(asked, isEmpty);
      });

      test('an app password has none', () async {
        expect(await calendar().onlineMeetingsFor(appPassword), isEmpty);
        expect(sent, isEmpty);
      });

      test('with a Gmail account signed in with Google in the app, a '
          'Microsoft account can hold one on Google Meet as well, after its '
          'own', () async {
        final c = calendar(answer: teamsCalendar, accounts: everyone);

        expect(
          await c.onlineMeetingsFor(microsoft),
          [OnlineMeetingKind.teams, OnlineMeetingKind.googleMeet],
        );
        expect(asked.map((a) => a.$1), ['acct-ms'],
            reason: 'the Gmail account is asked nothing to be offered');
      });

      test('and a Microsoft calendar that holds none has Google Meet alone',
          () async {
        final c = calendar(
          answer: (request) => request.method == 'GET'
              ? json({
                  'allowedOnlineMeetingProviders': <String>[],
                  'defaultOnlineMeetingProvider': 'unknown',
                })
              : json({'id': 'evt'}, 201),
          accounts: const [microsoft, google],
        );

        expect(
          await c.onlineMeetingsFor(microsoft),
          [OnlineMeetingKind.googleMeet],
        );
      });

      test('an app password still has none: its meeting goes to the phone',
          () async {
        expect(
          await calendar(accounts: everyone).onlineMeetingsFor(appPassword),
          isEmpty,
        );
      });
    });

    group('held on Google Meet from a Microsoft account', () {
      test('the Gmail account makes the link on its Meet token, first, and '
          'the Outlook event carries it', () async {
        final created = await calendar(answer: meetAndTeams, accounts: everyone)
            .createMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.googleMeet),
        );

        expect(created.joinUrl, 'https://meet.google.com/abc-defg-hij');
        expect(sent.map((r) => r.url.host),
            ['meet.googleapis.com', 'graph.microsoft.com']);
        expect(asked, [
          ('acct-g', GoogleOAuth.meetScopes),
          ('acct-ms', MicrosoftOAuth.calendarScopes),
        ]);
        final body = jsonDecode(sent.last.body) as Map;
        expect(body['isOnlineMeeting'], isFalse,
            reason: 'no Teams link beside it');
        expect((body['body'] as Map)['content'], contains('https://meet.google.com/abc-defg-hij'));
        expect(sent.where((r) => r.method == 'GET'), isEmpty,
            reason: 'where the calendar holds its own is beside the point');
      });

      test('the Gmail account not yet allowed Meet is named, for the screen '
          'to offer its sign-in', () async {
        await expectLater(
          calendar(answer: meetAndTeams, accounts: everyone, meetConsent: false)
              .createMeeting(
            microsoft,
            meeting(online: OnlineMeetingKind.googleMeet),
          ),
          throwsA(isA<MeetLinkNeedsConsent>()
              .having((e) => e.accountId, 'accountId', 'acct-g')
              .having((e) => e.emailAddress, 'emailAddress', 'ron@gmail.com')
              .having((e) => e.message, 'message', 'Not allowed Meet.')),
        );
        expect(sent, isEmpty, reason: 'no event without the link');
      });

      test('Meet itself refusing the token reads the same', () async {
        await expectLater(
          calendar(
            answer: (request) => request.url.host == 'meet.googleapis.com'
                ? json({
                    'error': {
                      'code': 403,
                      'status': 'PERMISSION_DENIED',
                      'details': [
                        {'reason': 'ACCESS_TOKEN_SCOPE_INSUFFICIENT'},
                      ],
                    }
                  }, 403)
                : teamsCalendar(request),
            accounts: everyone,
          ).createMeeting(
            microsoft,
            meeting(online: OnlineMeetingKind.googleMeet),
          ),
          throwsA(isA<MeetLinkNeedsConsent>()
              .having((e) => e.accountId, 'accountId', 'acct-g')),
        );
        expect(sent.map((r) => r.url.host), ['meet.googleapis.com']);
      });

      test('a Gmail sign-in that died is said in its name, not the '
          'meeting\'s account\'s', () async {
        final c = AccountCalendar(
          accessToken: (accountId, {bool force = false, List<String>? scopes}) async {
            if (accountId == 'acct-g') {
              throw const SignInExpired('Google no longer accepts this sign-in.');
            }
            return 'token';
          },
          accounts: () => everyone,
          httpClient: http_testing.MockClient((_) async => json({'id': 'evt'}, 201)),
        );

        await expectLater(
          c.createMeeting(microsoft, meeting(online: OnlineMeetingKind.googleMeet)),
          throwsA(isA<AuthenticationFailed>().having(
              (e) => e.message, 'message', contains('ron@gmail.com'))),
        );
      });

      test('with no Gmail account, Google Meet was never offered and asking '
          'for it is a bug', () async {
        await expectLater(
          calendar(answer: teamsCalendar).createMeeting(
            microsoft,
            meeting(online: OnlineMeetingKind.googleMeet),
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(sent, isEmpty);
      });

      test('a Google account\'s own meeting on Meet is still its '
          'calendar\'s', () async {
        final created = await calendar(
          answer: (_) => json({
            'id': 'evt-g',
            'conferenceData': {
              'entryPoints': [
                {'entryPointType': 'video', 'uri': 'https://meet.google.com/own-link'},
              ],
            },
          }),
          accounts: everyone,
        ).createMeeting(
          google,
          meeting(accountId: 'acct-g', online: OnlineMeetingKind.googleMeet),
        );

        expect(sent.single.url.host, 'www.googleapis.com');
        expect(created.joinUrl, 'https://meet.google.com/own-link');
      });
    });

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

    test('says where an account holds meetings online, or that it does not',
        () async {
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
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

      expect(await engine.onlineMeetingsFor(added.id), isEmpty);
      expect(await engine.onlineMeetingsFor('acct-nobody'), isEmpty);
    });
  });
}

String _two(int n) => n.toString().padLeft(2, '0');
