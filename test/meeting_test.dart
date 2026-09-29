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
    List<MailAddress> attendees = const [
      MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
      MailAddress(email: 'sam@example.com'),
    ],
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    String location = 'Room 4',
    String notes = 'Bring the numbers.',
    String? timeZone = 'Asia/Jerusalem',
    OnlineMeetingKind? online,
    PreparedMeeting? prepared,
  }) =>
      MeetingDraft(
        accountId: accountId,
        title: title,
        attendees: attendees,
        start: start ?? DateTime(2026, 10, 1, 9),
        end: end ?? DateTime(2026, 10, 1, 10),
        allDay: allDay,
        location: location,
        notes: notes,
        timeZone: timeZone,
        online: online,
        prepared: prepared,
      );

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json'});

  /// The log, kept here rather than printed: what is said in it is what
  /// some tests prove, and noise in the rest.
  List<String> captureLog() {
    final logged = <String>[];
    final was = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        logged.add(message ?? '');
    addTearDown(() => debugPrint = was);
    return logged;
  }

  /// Graph's delete for good, past Deleted Items: a POST, not a DELETE.
  bool purge(http.Request request) =>
      request.url.path.endsWith('/permanentDelete');

  /// What a meeting made ahead hands back when its event could not be
  /// deleted again: enough to find and delete it later, for the ledger.
  Matcher leftBehind(
    String eventId, {
    required String accountId,
    required OnlineMeetingKind kind,
  }) =>
      isA<PreparedMeetingLeft>().having(
        (e) => e.leftover,
        'leftover',
        isA<PreparedMeeting>()
            .having((p) => p.eventId, 'eventId', eventId)
            .having((p) => p.accountId, 'accountId', accountId)
            .having((p) => p.kind, 'kind', kind)
            .having((p) => p.joinUrl, 'joinUrl', ''),
      );

  const teamsJoin = 'https://teams.microsoft.com/l/meetup-join/'
      '19%3ameeting_NzQ5ZTI4%40thread.v2/0?context=%7b%22Tid%22%3a%22t1%22%7d';

  const teamsBodyTag = '<body dir="ltr">';

  /// The body Exchange writes into an event it made a Teams meeting for,
  /// in the block's current style: fenced by rows of underscores, spaced
  /// with &nbsp; and a zero-width space, and with \r\n between the lines,
  /// as Graph hands it back.
  const teamsBody = '<html>\r\n'
      '<head>\r\n'
      '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">\r\n'
      '<style type="text/css" style="display:none">\r\n'
      '<!--\r\n'
      'p\r\n'
      '\t{margin-top:0;\r\n'
      '\tmargin-bottom:0}\r\n'
      '-->\r\n'
      '</style>\r\n'
      '</head>\r\n'
      '$teamsBodyTag\r\n'
      '<div style="max-width:1024px; color:#242424">\r\n'
      '<div aria-hidden="true" style="overflow:hidden; white-space:nowrap">'
      '________________________________________________________________________________'
      '</div>\r\n'
      '<div style="margin-bottom:12px"><span style="font-size:24px; '
      'font-weight:700">Microsoft Teams meeting</span></div>\r\n'
      '<div style="margin-bottom:6px"><a id="meet_invite_block.action.join_link" '
      'href="$teamsJoin" title="Meeting join link" style="font-size:20px; '
      'text-decoration:underline; color:#5B5FC7">Join the meeting now</a>'
      '</div>\r\n'
      '<div style="margin-bottom:6px"><span style="color:#616161">'
      'Meeting ID:&nbsp;</span><span>244 810 212 347</span></div>\r\n'
      '<div style="margin-bottom:24px"><span style="color:#616161">'
      'Passcode:&nbsp;</span><span>7aP9Rv</span></div>\r\n'
      '<div aria-hidden="true" style="overflow:hidden; white-space:nowrap">'
      '________________________________'
      '</div>\r\n'
      '<div style="font-size:14px"><a href="https://aka.ms/JoinTeamsMeeting'
      '?omkt=en-US">Need help?</a>&nbsp;|&nbsp;<a href="https://teams.microsoft'
      '.com/meetingOptions/?organizerId=o1&amp;tenantId=t1&amp;threadId='
      '19_meeting_NzQ5ZTI4@thread.v2&amp;messageId=0&amp;language=en-US">'
      'Meeting options</a>&#8203;</div>\r\n'
      '<div aria-hidden="true" style="overflow:hidden; white-space:nowrap">'
      '________________________________________________________________________________'
      '</div>\r\n'
      '</div>\r\n'
      '</body>\r\n'
      '</html>\r\n';

  /// An event as Graph answers for it once Exchange has made its Teams
  /// meeting: online, with the link, and the block in the body. Either can
  /// be missing, as it is a moment after the event is made on some
  /// tenants, or the meeting dropped altogether.
  Map<String, Object?> teamsEvent({
    String id = 'evt-1',
    bool online = true,
    String? joinUrl = teamsJoin,
    String body = teamsBody,
    List<Object?> attendees = const [],
  }) =>
      {
        'id': id,
        'isOnlineMeeting': online,
        'onlineMeetingProvider': 'teamsForBusiness',
        'onlineMeeting': joinUrl == null ? null : {'joinUrl': joinUrl},
        'body': {'contentType': 'html', 'content': body},
        'attendees': attendees,
      };

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

    group('a Teams meeting made ahead of Send', () {
      test('is an event with nobody on it, held on Teams where the calendar '
          'said', () async {
        // The switch can go on before a title or an end is written, and a
        // calendar refuses an event with neither.
        await api((_) async => json(teamsEvent(), 201)).createShell(
          meeting(
            title: '  ',
            start: DateTime(2026, 10, 1, 9),
            end: DateTime(2026, 10, 1, 9),
            online: OnlineMeetingKind.teams,
          ),
          onlineMeetingProvider: 'teamsForBusiness',
        );

        final request = sent.single;
        expect(request.method, 'POST');
        expect(request.url.toString(),
            'https://graph.microsoft.com/v1.0/me/events');
        expect(request.headers['Content-Type'], startsWith('application/json'));
        final body = jsonDecode(request.body) as Map;
        expect(body['attendees'], isEmpty, reason: 'nobody is told a thing');
        expect(body['isOnlineMeeting'], isTrue);
        expect(body['onlineMeetingProvider'], 'teamsForBusiness');
        expect(body['subject'], 'New meeting');
        expect(body['start'],
            {'dateTime': '2026-10-01T09:00:00', 'timeZone': 'Asia/Jerusalem'});
        expect(body['end'],
            {'dateTime': '2026-10-01T10:00:00', 'timeZone': 'Asia/Jerusalem'});
        expect((body['body'] as Map)['content'], isEmpty,
            reason: 'the notes go at Send, above the block');
        expect(slept, isEmpty, reason: 'it all came with the event');
      });

      test('is not a meeting yet: no reminder, shown as free, and known by a '
          'transaction id of its own', () async {
        await api((_) async => json(teamsEvent(), 201))
            .createShell(meeting(online: OnlineMeetingKind.teams));

        final body = jsonDecode(sent.single.body) as Map;
        expect(body['isReminderOn'], isFalse);
        expect(body['showAs'], 'free');
        expect(body['transactionId'], matches(RegExp(r'^[0-9a-f]{32}$')));
      });

      String transactionIdOf(http.Request request) =>
          (jsonDecode(request.body) as Map)['transactionId'] as String;

      test('throttled, it is sent again with the same transaction id, so '
          'Graph makes one event however often it is sent', () async {
        var posts = 0;
        final prepared = await api((_) async => ++posts == 1
            ? http.Response('', 429, headers: const {'retry-after': '2'})
            : json(teamsEvent(), 201)).createShell(
          meeting(online: OnlineMeetingKind.teams),
        );

        expect(sent.map((r) => r.method), ['POST', 'POST']);
        expect(slept, [const Duration(seconds: 2)]);
        expect(transactionIdOf(sent.last), transactionIdOf(sent.first));
        expect(prepared!.eventId, 'evt-1');
      });

      test('each one made has a transaction id of its own', () async {
        final client = api((_) async => json(teamsEvent(), 201));
        await client.createShell(meeting(online: OnlineMeetingKind.teams));
        await client.createShell(meeting(online: OnlineMeetingKind.teams));

        expect(transactionIdOf(sent.last), isNot(transactionIdOf(sent.first)));
      });

      test('comes back with the event, its link, and the body Exchange wrote',
          () async {
        final prepared = await api((_) async => json(teamsEvent(), 201))
            .createShell(meeting(online: OnlineMeetingKind.teams));

        expect(prepared, isNotNull);
        expect(prepared!.accountId, 'acct-ms');
        expect(prepared.kind, OnlineMeetingKind.teams);
        expect(prepared.eventId, 'evt-1');
        expect(prepared.joinUrl, teamsJoin);
        expect(prepared.bodyHtml, teamsBody,
            reason: 'kept to the character: a block rewritten loses the '
                'meeting');
      });

      test('its invite text is the Teams block as it reads, without the rows '
          'of underscores', () async {
        final prepared = await api((_) async => json(teamsEvent(), 201))
            .createShell(meeting(online: OnlineMeetingKind.teams));

        expect(
          prepared!.inviteText,
          'Microsoft Teams meeting\n'
          'Join the meeting now\n'
          'Meeting ID: 244 810 212 347\n'
          'Passcode: 7aP9Rv\n'
          'Need help? | Meeting options',
        );
        expect(GraphCalendarApi.inviteTextOf(teamsBody), prepared.inviteText);
      });

      test('a link written a moment after the event is waited for, once, and '
          'read back', () async {
        final prepared = await api((request) async => request.method == 'POST'
            ? json(teamsEvent(joinUrl: null, body: ''), 201)
            : json(teamsEvent())).createShell(
          meeting(online: OnlineMeetingKind.teams),
        );

        expect(sent.map((r) => r.method), ['POST', 'GET']);
        expect(slept, [const Duration(seconds: 1)]);
        final look = sent.last;
        expect(look.url.path, '/v1.0/me/events/evt-1');
        expect(look.url.queryParameters[r'$select'],
            allOf(contains('body'), contains('onlineMeeting')));
        expect(prepared!.joinUrl, teamsJoin);
        expect(prepared.bodyHtml, teamsBody);
      });

      test('a calendar that still has no link deletes the event again and '
          'makes none', () async {
        final prepared = await api((request) async => switch (request.method) {
              'POST' when purge(request) => http.Response('', 204),
              'POST' => json(teamsEvent(joinUrl: null, body: ''), 201),
              _ => json(teamsEvent(joinUrl: null, body: '')),
            }).createShell(meeting(online: OnlineMeetingKind.teams));

        expect(prepared, isNull);
        expect(slept, [const Duration(seconds: 1)], reason: 'waited once only');
        expect(sent.map((r) => r.method), ['POST', 'GET', 'GET', 'POST']);
        // Looked at before it goes: one with people on it was sent.
        expect(sent[2].url.queryParameters[r'$select'], contains('attendees'));
        expect(sent.last.url.path, '/v1.0/me/events/evt-1/permanentDelete');
      });

      test('a body with no Teams block in it is no Teams meeting to show '
          'either', () async {
        final prepared = await api((request) async => switch (request.method) {
              'POST' when purge(request) => http.Response('', 204),
              'POST' => json(
                  teamsEvent(body: '<html><body><p>Skype</p></body></html>'),
                  201),
              _ => json(teamsEvent(body: '<html><body></body></html>')),
            }).createShell(meeting(online: OnlineMeetingKind.teams));

        expect(prepared, isNull);
        expect(sent.map((r) => r.method), ['POST', 'GET', 'POST']);
        expect(sent.last.url.path, '/v1.0/me/events/evt-1/permanentDelete');
      });

      test('a failure while waiting for the link still deletes the event it '
          'made', () async {
        captureLog();
        var looks = 0;
        try {
          await api((request) async => switch (request.method) {
                'POST' when purge(request) => http.Response('', 204),
                'POST' => json(teamsEvent(joinUrl: null, body: ''), 201),
                _ => ++looks == 1
                    ? json({'error': {'code': 'ErrorInternalServerError'}}, 500)
                    : json(teamsEvent(joinUrl: null, body: '')),
              }).createShell(meeting(online: OnlineMeetingKind.teams));
        } on ConnectionFailed {
          // Said as a failure or not, the event must not be left behind:
          // nothing was handed back to put on the ledger.
        }

        expect(sent.where(purge), hasLength(1),
            reason: 'an event with nobody on it, on nobody\'s ledger, stays '
                'on the calendar for good');
      });

      test('a failure while waiting for the link, with the event not deleted '
          'either, hands the event back for the ledger', () async {
        final logged = captureLog();
        var looks = 0;
        final broken =
            json({'error': {'code': 'ErrorInternalServerError'}}, 500);
        await expectLater(
          api((request) async => switch (request.method) {
                'POST' when purge(request) => broken,
                'POST' => json(teamsEvent(joinUrl: null, body: ''), 201),
                'DELETE' => broken,
                _ => ++looks == 1
                    ? broken
                    : json(teamsEvent(joinUrl: null, body: '')),
              }).createShell(meeting(online: OnlineMeetingKind.teams)),
          throwsA(allOf(
            leftBehind('evt-1',
                accountId: 'acct-ms', kind: OnlineMeetingKind.teams),
            isA<PreparedMeetingLeft>().having(
                (e) => e.cause, 'cause', isA<ConnectionFailed>()),
          )),
        );

        expect(sent.map((r) => r.method),
            ['POST', 'GET', 'GET', 'POST', 'DELETE'],
            reason: 'for good, then into Deleted Items, and neither took');
        expect(logged.single, contains('could not delete'));
      });

      test('no link, with the event not deleted again either, hands the '
          'event back for the ledger rather than making none', () async {
        final logged = captureLog();
        final broken =
            json({'error': {'code': 'ErrorInternalServerError'}}, 500);
        await expectLater(
          api((request) async => switch (request.method) {
                'POST' when purge(request) => broken,
                'POST' => json(teamsEvent(joinUrl: null, body: ''), 201),
                'DELETE' => broken,
                _ => json(teamsEvent(joinUrl: null, body: '')),
              }).createShell(meeting(online: OnlineMeetingKind.teams)),
          throwsA(leftBehind('evt-1',
              accountId: 'acct-ms', kind: OnlineMeetingKind.teams)),
        );

        expect(sent.map((r) => r.method),
            ['POST', 'GET', 'GET', 'POST', 'DELETE']);
        expect(logged.single, contains('could not delete'));
      });

      test('its invite text reads Exchange\'s wrapped lines as the phrases '
          'they are', () {
        // Exchange wraps long lines of the body it writes, inside the text
        // as well, as Graph's documented Teams bodies show: a browser reads
        // each break as a space.
        const wrapped = '<html>\r\n'
            '<head>\r\n'
            '<meta http-equiv="Content-Type" content="text/html; '
            'charset=utf-8">\r\n'
            '</head>\r\n'
            '<body>\r\n'
            '<div><br>\r\n'
            '<div style="width:100%; height:20px"><span style="white-space:'
            'nowrap; color:gray; opacity:.36">'
            '________________________________________________________________________________'
            '</span></div>\r\n'
            '<div class="me-email-text" style="color:#252424">\r\n'
            '<div><a href="$teamsJoin" target="_blank" rel="noreferrer '
            'noopener"><span style="font-size:12pt; color:rgb(98,100,167)">'
            'Join\r\n'
            ' Microsoft Teams Meeting</span></a> </div>\r\n'
            '<div><a href="tel:+14255550100,,291633251#" target="_blank">'
            '<span>+1 425-555-0100</span></a>&nbsp;&nbsp; United States, '
            'Redmond (Toll)</div>\r\n'
            '<div><span style="font-size:10.5pt">Conference ID:\r\n'
            '</span><span>291 633 251#</span></div>\r\n'
            '<div><a href="https://dialin.teams.microsoft.com/8551f4c1?id='
            '291633251" target="_blank">Local\r\n'
            ' numbers</a> | <a href="https://mysettings.lync.com/'
            'pstnconferencing" target="_blank">Reset PIN</a> | <a href='
            '"https://aka.ms/crossorg" target="_blank">Learn more about '
            'Teams</a></div>\r\n'
            '<div style="width:100%; height:20px"><span style="white-space:'
            'nowrap; color:gray; opacity:.36">'
            '________________________________________________________________________________'
            '</span></div>\r\n'
            '</div>\r\n'
            '</div>\r\n'
            '</body>\r\n'
            '</html>\r\n';

        expect(
          GraphCalendarApi.inviteTextOf(wrapped),
          'Join Microsoft Teams Meeting\n'
          '+1 425-555-0100 United States, Redmond (Toll)\n'
          'Conference ID: 291 633 251#\n'
          'Local numbers | Reset PIN | Learn more about Teams',
        );
      });
    });

    group('sending a Teams meeting made ahead', () {
      PreparedMeeting made({String id = 'evt-1'}) => PreparedMeeting(
            accountId: 'acct-ms',
            kind: OnlineMeetingKind.teams,
            eventId: id,
            joinUrl: teamsJoin,
            inviteText: 'Microsoft Teams meeting',
            bodyHtml: teamsBody,
          );

      test('patches its details and notes in first, above the block as '
          'Exchange wrote it, and nobody on it yet', () async {
        final created = await api((_) async => json(teamsEvent())).sendShell(
          made(),
          meeting(
            online: OnlineMeetingKind.teams,
            notes: 'Bring the numbers & the <draft>.',
          ),
        );

        expect(sent.map((r) => r.method), ['PATCH', 'PATCH']);
        final first = sent.first;
        expect(first.url.toString(),
            'https://graph.microsoft.com/v1.0/me/events/evt-1');
        expect(first.headers['Content-Type'], startsWith('application/json'));
        final details = jsonDecode(first.body) as Map;
        expect(details['subject'], 'Q3 review');
        expect(details['body'], {
          'contentType': 'html',
          'content': teamsBody.replaceFirst(
            teamsBodyTag,
            '$teamsBodyTag\n'
            '<div>Bring the numbers &amp; the &lt;draft&gt;.</div>\n<br>\n',
          ),
        });
        expect(details['start'],
            {'dateTime': '2026-10-01T09:00:00', 'timeZone': 'Asia/Jerusalem'});
        expect(details['end'],
            {'dateTime': '2026-10-01T10:00:00', 'timeZone': 'Asia/Jerusalem'});
        expect(details['isAllDay'], isFalse);
        expect(details['location'], {'displayName': 'Room 4'});
        expect(details.containsKey('attendees'), isFalse,
            reason: 'nobody is asked before the link is known to have held');
        expect(created.id, 'evt-1');
        expect(created.joinUrl, teamsJoin);
      });

      test('is a meeting from the first step: reminded of, and shown as '
          'busy', () async {
        await api((_) async => json(teamsEvent()))
            .sendShell(made(), meeting(online: OnlineMeetingKind.teams));

        final details = jsonDecode(sent.first.body) as Map;
        expect(details['isReminderOn'], isTrue);
        expect(details['showAs'], 'busy');
      });

      test('then the attendees, alone: their arrival is what sends the '
          'invitations', () async {
        await api((_) async => json(teamsEvent()))
            .sendShell(made(), meeting(online: OnlineMeetingKind.teams));

        final second = sent.last;
        expect(second.method, 'PATCH');
        expect(second.url.path, '/v1.0/me/events/evt-1');
        expect(jsonDecode(second.body), {
          'attendees': [
            {
              'emailAddress': {
                'address': 'dana@example.com',
                'name': 'Dana Levi',
              },
              'type': 'required',
            },
            {
              'emailAddress': {'address': 'sam@example.com'},
              'type': 'required',
            },
          ],
        });
      });

      test('with nobody to invite there is no second step', () async {
        final created = await api((_) async => json(teamsEvent())).sendShell(
          made(),
          meeting(attendees: const [], online: OnlineMeetingKind.teams),
        );

        expect(sent.map((r) => r.method), ['PATCH']);
        expect(created.joinUrl, teamsJoin);
      });

      test('an answer that does not say whether it is still online is looked '
          'up', () async {
        await api((request) async => request.method == 'PATCH'
            ? json({'id': 'evt-1'})
            : json(teamsEvent())).sendShell(
          made(),
          meeting(online: OnlineMeetingKind.teams),
        );

        expect(sent.map((r) => r.method), ['PATCH', 'GET', 'PATCH']);
      });

      test('the Teams meeting dropped by the first step is lost, and nobody '
          'is invited to it', () async {
        await expectLater(
          api((_) async => json(teamsEvent(online: false, joinUrl: null)))
              .sendShell(made(), meeting(online: OnlineMeetingKind.teams)),
          throwsA(isA<PreparedMeetingLost>()),
        );
        expect(sent.map((r) => r.method), ['PATCH']);
      });

      test('an event deleted meanwhile is lost', () async {
        await expectLater(
          api((_) async => json({'error': {'code': 'ErrorItemNotFound'}}, 404))
              .sendShell(made(), meeting(online: OnlineMeetingKind.teams)),
          throwsA(isA<PreparedMeetingLost>()),
        );
        expect(sent.map((r) => r.method), ['PATCH']);
      });

      test('one with nothing made ahead to send is lost without a word to '
          'Graph', () async {
        await expectLater(
          api((_) async => json(teamsEvent())).sendShell(
            const PreparedMeeting(
              accountId: 'acct-ms',
              kind: OnlineMeetingKind.teams,
              eventId: 'evt-1',
              joinUrl: teamsJoin,
              inviteText: '',
            ),
            meeting(online: OnlineMeetingKind.teams),
          ),
          throwsA(isA<PreparedMeetingLost>()),
        );
        expect(sent, isEmpty);
      });

      test('a location taken away after the link was made is not on the '
          'invitation', () async {
        // The event made ahead is made with no location, so one typed then
        // and cleared before Send is on it nowhere; left out at Send too,
        // Exchange's own for a Teams meeting stands.
        await api((_) async => json(teamsEvent())).createShell(
          meeting(location: 'Room 4', online: OnlineMeetingKind.teams),
        );
        expect((jsonDecode(sent.single.body) as Map).containsKey('location'),
            isFalse);
        sent.clear();

        await api((_) async => json(teamsEvent())).sendShell(
          made(),
          meeting(location: '', online: OnlineMeetingKind.teams),
        );

        expect((jsonDecode(sent.first.body) as Map).containsKey('location'),
            isFalse);
      });
    });

    group('deleting a Teams meeting made ahead', () {
      test('one somebody is on is left alone: deleting it would cancel their '
          'meeting', () async {
        await api((_) async => json(teamsEvent(attendees: [
              {
                'emailAddress': {'address': 'dana@example.com'},
                'type': 'required',
              },
            ]))).deleteShell('evt-1');

        expect(sent.map((r) => r.method), ['GET']);
        expect(sent.single.url.queryParameters[r'$select'],
            contains('attendees'));
      });

      test('one with nobody on it is deleted for good, not into Deleted '
          'Items', () async {
        final done = await api((request) async => purge(request)
            ? http.Response('', 204)
            : json(teamsEvent())).deleteShell('evt-1');

        expect(done, isTrue);
        expect(sent.map((r) => r.method), ['GET', 'POST']);
        expect(sent.last.url.toString(),
            'https://graph.microsoft.com/v1.0/me/events/evt-1/permanentDelete');
      });

      test('a mailbox that refuses to delete for good has it go into Deleted '
          'Items instead', () async {
        for (final status in [400, 405]) {
          sent.clear();
          final done = await api((request) async => switch (request.method) {
                'GET' => json(teamsEvent()),
                'POST' => json({
                    'error': {
                      'code': 'ErrorInvalidRequest',
                      'message': 'The OData request is not supported.',
                    }
                  }, status),
                _ => http.Response('', 204),
              }).deleteShell('evt-1');

          expect(done, isTrue, reason: 'HTTP $status');
          expect(sent.map((r) => '${r.method} ${r.url.path}'), [
            'GET /v1.0/me/events/evt-1',
            'POST /v1.0/me/events/evt-1/permanentDelete',
            'DELETE /v1.0/me/events/evt-1',
          ], reason: 'HTTP $status');
        }
      });

      test('one gone by the time it is deleted is done with, whichever way '
          'it is deleted', () async {
        final notFound = json({'error': {'code': 'ErrorItemNotFound'}}, 404);

        // Gone before the delete for good.
        var done = await api((request) async =>
                request.method == 'GET' ? json(teamsEvent()) : notFound)
            .deleteShell('evt-1');
        expect(done, isTrue);
        expect(sent.map((r) => r.method), ['GET', 'POST'],
            reason: 'nothing left to put into Deleted Items');

        // Gone before the fallback.
        sent.clear();
        done = await api((request) async => switch (request.method) {
              'GET' => json(teamsEvent()),
              'POST' => json({'error': {'code': 'ErrorInvalidRequest'}}, 405),
              _ => notFound,
            }).deleteShell('evt-1');
        expect(done, isTrue);
        expect(sent.map((r) => r.method), ['GET', 'POST', 'DELETE']);
      });

      test('one already gone is left at that', () async {
        final done = await api(
                (_) async => json({'error': {'code': 'ErrorItemNotFound'}}, 404))
            .deleteShell('evt-1');

        expect(done, isTrue);
        expect(sent.map((r) => r.method), ['GET']);
      });

      test('a Graph id, with its slashes and pluses, goes encoded', () async {
        await api((request) async => switch (request.method) {
              'GET' => json(teamsEvent()),
              'POST' => json({'error': {'code': 'ErrorInvalidRequest'}}, 405),
              _ => http.Response('', 204),
            }).deleteShell('AAMkAGI2/Tg+x=');

        const encoded = '/v1.0/me/events/AAMkAGI2%2FTg%2Bx%3D';
        expect(sent.map((r) => '${r.method} ${r.url.path}'), [
          'GET $encoded',
          'POST $encoded/permanentDelete',
          'DELETE $encoded',
        ]);
      });

      test('a failure is said in the log and never thrown, and says it is '
          'still to do', () async {
        final logged = captureLog();

        final done = [
          await api((_) async =>
                  json({'error': {'code': 'ErrorInternalServerError'}}, 500))
              .deleteShell('evt-1'),
          await api((request) async => request.method == 'GET'
              ? json(teamsEvent())
              : json({'error': {'code': 'ErrorAccessDenied'}}, 403))
              .deleteShell('evt-1'),
          await api((_) async => throw http.ClientException('offline'))
              .deleteShell('evt-1'),
        ];

        expect(done, [false, false, false]);
        expect(logged, hasLength(3));
        expect(logged, everyElement(contains('could not delete')));
      });
    });

    group('the notes above a Teams block', () {
      test('go in escaped, right after the body tag', () {
        expect(
          GraphCalendarApi.bodyWithNotes(
            '<html><body class="x"><p>Teams</p></body></html>',
            'Q3 < Q2 & falling',
          ),
          '<html><body class="x">\n'
          '<div>Q3 &lt; Q2 &amp; falling</div>\n<br>\n'
          '<p>Teams</p></body></html>',
        );
      });

      test('Hebrew notes read right to left', () {
        expect(
          GraphCalendarApi.bodyWithNotes(
            '<html><body><p>Teams</p></body></html>',
            'להביא את המספרים',
          ),
          '<html><body>\n'
          '<div dir="rtl">להביא את המספרים</div>\n<br>\n'
          '<p>Teams</p></body></html>',
        );
      });

      test('each line of them is a line', () {
        expect(
          GraphCalendarApi.bodyWithNotes('<body>T</body>', 'One\r\nTwo\nThree'),
          '<body>\n<div>One<br>\nTwo<br>\nThree</div>\n<br>\nT</body>',
        );
      });

      test('a body with no body tag has them put before it', () {
        expect(
          GraphCalendarApi.bodyWithNotes('<div>Teams</div>', 'Bring the numbers.'),
          '<div>Bring the numbers.</div>\n<br>\n<div>Teams</div>',
        );
      });

      test('no notes leave the body as Exchange wrote it', () {
        expect(GraphCalendarApi.bodyWithNotes(teamsBody, ''), teamsBody);
        expect(GraphCalendarApi.bodyWithNotes(teamsBody, ' \n '), teamsBody);
      });
    });

    test('a Google Meet link on a Microsoft invitation reads as the line it '
        'goes out as', () {
      expect(GraphCalendarApi.meetLine('https://meet.google.com/abc-defg-hij'),
          'Join with Google Meet: https://meet.google.com/abc-defg-hij');
    });
  });

  group('GoogleCalendarApi', () {
    late List<http.Request> sent;
    late List<bool> asked;
    late List<Duration> slept;

    setUp(() {
      sent = [];
      asked = [];
      slept = [];
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
          sleep: (d) async => slept.add(d),
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

    const events =
        'https://www.googleapis.com/calendar/v3/calendars/primary/events';

    /// The conference of a Workspace account, which has dial-in beside the
    /// link, as the API gives it.
    const workspaceConference = {
      'conferenceId': 'abc-defg-hij',
      'conferenceSolution': {
        'key': {'type': 'hangoutsMeet'},
        'name': 'Google Meet',
      },
      'createRequest': {
        'requestId': 'r1',
        'conferenceSolutionKey': {'type': 'hangoutsMeet'},
        'status': {'statusCode': 'success'},
      },
      'entryPoints': [
        {
          'entryPointType': 'video',
          'uri': 'https://meet.google.com/abc-defg-hij',
          'label': 'meet.google.com/abc-defg-hij',
        },
        {
          'entryPointType': 'phone',
          'uri': 'tel:+1-413-555-0142',
          'label': '+1 413-555-0142',
          'pin': '518297402',
          'regionCode': 'US',
        },
        {
          'entryPointType': 'more',
          'uri': 'https://tel.meet/abc-defg-hij?pin=518297402',
          'pin': '518297402',
        },
      ],
    };

    /// An event as Google answers for it, its Meet link made or, while
    /// [status] is `pending`, still being made.
    Map<String, Object?> meetEvent({
      String status = 'success',
      List<Object?>? attendees,
    }) =>
        {
          'id': 'evt-g',
          'status': 'confirmed',
          'conferenceData': {
            'createRequest': {
              'requestId': 'r1',
              'conferenceSolutionKey': {'type': 'hangoutsMeet'},
              'status': {'statusCode': status},
            },
            if (status == 'success')
              'entryPoints': [
                {
                  'entryPointType': 'video',
                  'uri': 'https://meet.google.com/abc-defg-hij',
                  'label': 'meet.google.com/abc-defg-hij',
                },
              ],
          },
          'attendees': ?attendees,
        };

    group('a Meet meeting made ahead of Send', () {
      test('is an event with nobody on it and nobody told, asking for its '
          'link', () async {
        await api((_) async => json(meetEvent())).createShell(meeting(
          accountId: 'acct-g',
          title: '',
          online: OnlineMeetingKind.googleMeet,
        ));

        final request = sent.single;
        expect(request.method, 'POST');
        expect(request.url.toString(),
            '$events?sendUpdates=none&conferenceDataVersion=1');
        final body = jsonDecode(request.body) as Map;
        expect(body['attendees'], isEmpty);
        expect(body['summary'], 'New meeting');
        expect(body.containsKey('description'), isFalse,
            reason: 'the notes go at Send');
        final ask = (body['conferenceData'] as Map)['createRequest'] as Map;
        expect(ask['conferenceSolutionKey'], {'type': 'hangoutsMeet'});
        expect(slept, isEmpty, reason: 'the link came with the event');
      });

      test('is not a meeting yet: no reminder, and not shown as busy',
          () async {
        await api((_) async => json(meetEvent())).createShell(meeting(
          accountId: 'acct-g',
          online: OnlineMeetingKind.googleMeet,
        ));

        final body = jsonDecode(sent.single.body) as Map;
        expect(body['reminders'], {'useDefault': false});
        expect(body['transparency'], 'transparent');
      });

      test('comes back with the event, its link, and the text Google\'s '
          'invitation will carry', () async {
        final prepared = await api((_) async => json(meetEvent()))
            .createShell(meeting(
          accountId: 'acct-g',
          online: OnlineMeetingKind.googleMeet,
        ));

        expect(prepared!.accountId, 'acct-g');
        expect(prepared.kind, OnlineMeetingKind.googleMeet);
        expect(prepared.eventId, 'evt-g');
        expect(prepared.joinUrl, 'https://meet.google.com/abc-defg-hij');
        expect(prepared.inviteText,
            'Join with Google Meet\nhttps://meet.google.com/abc-defg-hij');
        expect(prepared.bodyHtml, isNull,
            reason: 'Google writes its block into each invitation itself');
      });

      test('a link Google is still making is waited for, without really '
          'waiting', () async {
        var looks = 0;
        final prepared = await api((request) async => request.method == 'POST'
            ? json(meetEvent(status: 'pending'))
            : json(meetEvent(status: ++looks < 2 ? 'pending' : 'success')))
            .createShell(meeting(
          accountId: 'acct-g',
          online: OnlineMeetingKind.googleMeet,
        ));

        expect(sent.map((r) => r.method), ['POST', 'GET', 'GET']);
        expect(slept, [const Duration(seconds: 1), const Duration(seconds: 1)]);
        expect(sent[1].url.toString(),
            '$events/evt-g?conferenceDataVersion=1');
        expect(prepared!.joinUrl, 'https://meet.google.com/abc-defg-hij');
      });

      test('no link after waiting deletes the event, telling nobody, and '
          'makes none', () async {
        final prepared = await api((request) async => request.method == 'DELETE'
            ? http.Response('', 204)
            : json(meetEvent(status: 'pending'))).createShell(meeting(
          accountId: 'acct-g',
          online: OnlineMeetingKind.googleMeet,
        ));

        expect(prepared, isNull);
        expect(slept, hasLength(GoogleCalendarApi.maxMeetWaits));
        expect(sent.where((r) => r.method == 'GET'),
            hasLength(GoogleCalendarApi.maxMeetWaits + 1),
            reason: 'each wait, then a look for anyone on it');
        expect(sent.last.method, 'DELETE');
        expect(sent.last.url.toString(), '$events/evt-g?sendUpdates=none');
      });

      test('a failure while waiting for the link still deletes the event it '
          'made', () async {
        captureLog();
        var looks = 0;
        try {
          await api((request) async => switch (request.method) {
                'POST' => json(meetEvent(status: 'pending')),
                'DELETE' => http.Response('', 204),
                _ => ++looks == 1
                    ? json({'error': {'code': 500, 'message': 'Backend Error'}},
                        500)
                    : json(meetEvent(status: 'pending')),
              }).createShell(meeting(
            accountId: 'acct-g',
            online: OnlineMeetingKind.googleMeet,
          ));
        } on ConnectionFailed {
          // Said as a failure or not, the event must not be left behind:
          // nothing was handed back to put on the ledger.
        }

        expect(sent.where((r) => r.method == 'DELETE'), hasLength(1),
            reason: 'an event with nobody on it, on nobody\'s ledger, stays '
                'on the calendar for good');
      });

      test('a failure while waiting for the link, with the event not deleted '
          'either, hands the event back for the ledger', () async {
        final logged = captureLog();
        var looks = 0;
        final broken =
            json({'error': {'code': 500, 'message': 'Backend Error'}}, 500);
        await expectLater(
          api((request) async => switch (request.method) {
                'POST' => json(meetEvent(status: 'pending')),
                'DELETE' => broken,
                _ => ++looks == 1 ? broken : json(meetEvent(status: 'pending')),
              }).createShell(meeting(
            accountId: 'acct-g',
            online: OnlineMeetingKind.googleMeet,
          )),
          throwsA(allOf(
            leftBehind('evt-g',
                accountId: 'acct-g', kind: OnlineMeetingKind.googleMeet),
            isA<PreparedMeetingLeft>().having(
                (e) => e.cause, 'cause', isA<ConnectionFailed>()),
          )),
        );

        expect(sent.map((r) => r.method), ['POST', 'GET', 'GET', 'DELETE']);
        expect(logged.single, contains('could not delete'));
      });

      test('no link after waiting, with the event not deleted again either, '
          'hands the event back for the ledger rather than making none',
          () async {
        final logged = captureLog();
        await expectLater(
          api((request) async => request.method == 'DELETE'
              ? json({'error': {'code': 500, 'message': 'Backend Error'}}, 500)
              : json(meetEvent(status: 'pending'))).createShell(meeting(
            accountId: 'acct-g',
            online: OnlineMeetingKind.googleMeet,
          )),
          throwsA(leftBehind('evt-g',
              accountId: 'acct-g', kind: OnlineMeetingKind.googleMeet)),
        );

        expect(slept, hasLength(GoogleCalendarApi.maxMeetWaits));
        expect(sent.last.method, 'DELETE');
        expect(logged.single, contains('could not delete'));
      });
    });

    group('the text of a Google invitation', () {
      test('a Workspace account\'s has the link, the first number with its '
          'PIN, and the page of the others, in the words Google\'s email '
          'uses', () {
        expect(
          GoogleCalendarApi.inviteTextOf(workspaceConference),
          'Join with Google Meet\n'
          'https://meet.google.com/abc-defg-hij\n'
          '\n'
          'Join by phone\n'
          '(US) +1 413-555-0142\n'
          'PIN: 518297402\n'
          '\n'
          'More phone numbers\n'
          'https://tel.meet/abc-defg-hij?pin=518297402',
        );
      });

      test('a personal account\'s has the link alone', () {
        expect(
          GoogleCalendarApi.inviteTextOf({
            'entryPoints': [
              {
                'entryPointType': 'video',
                'uri': 'https://meet.google.com/abc-defg-hij',
                'label': 'meet.google.com/abc-defg-hij',
              },
            ],
          }),
          'Join with Google Meet\nhttps://meet.google.com/abc-defg-hij',
        );
      });

      test('no conference has nothing to say', () {
        expect(GoogleCalendarApi.inviteTextOf(null), isEmpty);
        expect(GoogleCalendarApi.inviteTextOf({'entryPoints': []}), isEmpty);
      });
    });

    group('sending a Meet meeting made ahead', () {
      const made = PreparedMeeting(
        accountId: 'acct-g',
        kind: OnlineMeetingKind.googleMeet,
        eventId: 'evt-g',
        joinUrl: 'https://meet.google.com/abc-defg-hij',
        inviteText: 'Join with Google Meet',
      );

      test('patches in everything as it stands, the attendees with it, and '
          'Google told to invite them', () async {
        final created = await api((_) async => json(meetEvent())).sendShell(
          made,
          meeting(accountId: 'acct-g', online: OnlineMeetingKind.googleMeet),
        );

        expect(sent.map((r) => r.method), ['GET', 'PATCH'],
            reason: 'looked at first, to be sure it is still there');
        expect(sent.first.url.toString(),
            '$events/evt-g?conferenceDataVersion=1');
        final request = sent.last;
        expect(request.method, 'PATCH');
        expect(request.url.toString(),
            '$events/evt-g?sendUpdates=all&conferenceDataVersion=1');
        expect(request.headers['Content-Type'], startsWith('application/json'));
        final body = jsonDecode(request.body) as Map;
        expect(body['summary'], 'Q3 review');
        expect(body['description'], 'Bring the numbers.');
        expect(body['location'], 'Room 4');
        // The date emptied: a patch merges, and the event may have been
        // made as a whole day.
        expect(body['start'], {
          'dateTime': '2026-10-01T09:00:00',
          'timeZone': 'Asia/Jerusalem',
          'date': null,
        });
        expect(body['attendees'], [
          {'email': 'dana@example.com', 'displayName': 'Dana Levi'},
          {'email': 'sam@example.com'},
        ]);
        expect(body.containsKey('conferenceData'), isFalse,
            reason: 'the link made ahead is kept, not asked for again');
        expect(created.id, 'evt-g');
        expect(created.joinUrl, 'https://meet.google.com/abc-defg-hij');
      });

      test('is a meeting now: reminded of as the calendar reminds, and '
          'shown as busy', () async {
        await api((_) async => json(meetEvent())).sendShell(
          made,
          meeting(accountId: 'acct-g', online: OnlineMeetingKind.googleMeet),
        );

        final body = jsonDecode(sent.last.body) as Map;
        expect(body['reminders'], {'useDefault': true});
        expect(body['transparency'], 'opaque');
      });

      test('notes and a location left empty are emptied on the event, not '
          'left out', () async {
        await api((_) async => json(meetEvent())).sendShell(
          made,
          meeting(
            accountId: 'acct-g',
            location: '',
            notes: '',
            online: OnlineMeetingKind.googleMeet,
          ),
        );

        final body = jsonDecode(sent.last.body) as Map;
        expect(body['description'], '');
        expect(body['location'], '');
      });

      test('an event deleted meanwhile is lost, whichever way Google says '
          'so, and nothing is patched', () async {
        for (final status in [404, 410]) {
          await expectLater(
            api((_) async => json({'error': {'code': status}}, status))
                .sendShell(made, meeting(
              accountId: 'acct-g',
              online: OnlineMeetingKind.googleMeet,
            )),
            throwsA(isA<PreparedMeetingLost>()),
            reason: 'HTTP $status',
          );
        }
        expect(sent.map((r) => r.method), ['GET', 'GET']);
      });

      test('one Google keeps as cancelled is lost, and nothing is patched: a '
          'patch to it answers as though all were well', () async {
        await expectLater(
          api((_) async => json({...meetEvent(), 'status': 'cancelled'}))
              .sendShell(made, meeting(
            accountId: 'acct-g',
            online: OnlineMeetingKind.googleMeet,
          )),
          throwsA(isA<PreparedMeetingLost>()),
        );
        expect(sent.map((r) => r.method), ['GET']);
      });

      test('one whose Meet link is gone is lost, and nothing is patched: '
          'nobody is invited to a meeting with no way in', () async {
        for (final event in [
          {'id': 'evt-g', 'status': 'confirmed'},
          meetEvent(status: 'pending'),
        ]) {
          sent.clear();
          await expectLater(
            api((_) async => json(event)).sendShell(made, meeting(
              accountId: 'acct-g',
              online: OnlineMeetingKind.googleMeet,
            )),
            throwsA(isA<PreparedMeetingLost>()),
          );
          expect(sent.map((r) => r.method), ['GET']);
        }
      });

      test('one deleted between the look and the patch is lost as well',
          () async {
        for (final status in [404, 410]) {
          sent.clear();
          await expectLater(
            api((request) async => request.method == 'GET'
                ? json(meetEvent())
                : json({'error': {'code': status}}, status)).sendShell(
              made,
              meeting(accountId: 'acct-g', online: OnlineMeetingKind.googleMeet),
            ),
            throwsA(isA<PreparedMeetingLost>()),
            reason: 'HTTP $status',
          );
          expect(sent.map((r) => r.method), ['GET', 'PATCH']);
        }
      });

      test('a meeting made all day after its link was made loses the times '
          'the event had', () async {
        // Google merges a patched object into the one it has: a date given
        // beside the dateTime the event was made with is refused.
        await api((_) async => json(meetEvent())).sendShell(
          made,
          meeting(
            accountId: 'acct-g',
            allDay: true,
            start: DateTime(2026, 10, 1),
            end: DateTime(2026, 10, 1),
            online: OnlineMeetingKind.googleMeet,
          ),
        );

        final body = jsonDecode(sent.last.body) as Map;
        expect(body['start'],
            {'date': '2026-10-01', 'dateTime': null, 'timeZone': null});
        expect(body['end'],
            {'date': '2026-10-02', 'dateTime': null, 'timeZone': null});
      });
    });

    group('deleting a Meet meeting made ahead', () {
      test('one somebody is on is left alone', () async {
        await api((_) async => json(meetEvent(attendees: [
              {'email': 'dana@example.com', 'responseStatus': 'needsAction'},
            ]))).deleteShell('evt-g');

        expect(sent.map((r) => r.method), ['GET']);
      });

      test('one with nobody on it is deleted, telling nobody', () async {
        await api((request) async => request.method == 'DELETE'
            ? http.Response('', 204)
            : json(meetEvent())).deleteShell('evt-g');

        expect(sent.map((r) => r.method), ['GET', 'DELETE']);
        expect(sent.last.url.toString(), '$events/evt-g?sendUpdates=none');
      });

      test('a failure is said in the log and never thrown', () async {
        final logged = captureLog();

        await api((request) async => request.method == 'DELETE'
            ? json({'error': {'code': 500}}, 500)
            : json(meetEvent())).deleteShell('evt-g');
        await api((_) async => throw http.ClientException('offline'))
            .deleteShell('evt-g');

        expect(logged, hasLength(2));
        expect(logged, everyElement(contains('could not delete')));
      });
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

    group('the online meeting made ahead of Send', () {
      /// A Microsoft calendar that holds meetings on Teams, and makes one as
      /// Exchange does: in the event's body, beside its link.
      http.Response teamsShells(http.Request request) {
        if (request.url.path == '/v1.0/me/calendar') {
          return teamsCalendar(request);
        }
        return switch (request.method) {
          'POST' when purge(request) => http.Response('', 204),
          'POST' => json(teamsEvent(), 201),
          'DELETE' => http.Response('', 204),
          _ => json(teamsEvent()),
        };
      }

      const teamsMade = PreparedMeeting(
        accountId: 'acct-ms',
        kind: OnlineMeetingKind.teams,
        eventId: 'evt-1',
        joinUrl: teamsJoin,
        inviteText: 'Microsoft Teams meeting',
        bodyHtml: teamsBody,
      );

      test('Teams on a Microsoft account is an event on its calendar, held '
          'where the calendar said', () async {
        final prepared = await calendar(answer: teamsShells)
            .prepareOnlineMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.teams),
        );

        expect(sent.map((r) => '${r.method} ${r.url.path}'),
            ['GET /v1.0/me/calendar', 'POST /v1.0/me/events']);
        final body = jsonDecode(sent.last.body) as Map;
        expect(body['onlineMeetingProvider'], 'teamsForBusiness');
        expect(body['attendees'], isEmpty);
        expect(asked.map((a) => a.$2),
            everyElement(MicrosoftOAuth.calendarScopes));
        expect(prepared!.eventId, 'evt-1');
        expect(prepared.joinUrl, teamsJoin);
        expect(prepared.bodyHtml, teamsBody);
      });

      test('and Send patches that event rather than making another', () async {
        final created = await calendar(answer: teamsShells).createMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.teams, prepared: teamsMade),
        );

        expect(sent.map((r) => '${r.method} ${r.url.path}'), [
          'PATCH /v1.0/me/events/evt-1',
          'PATCH /v1.0/me/events/evt-1',
        ]);
        expect((jsonDecode(sent.last.body) as Map)['attendees'], hasLength(2));
        expect(created.id, 'evt-1');
        expect(created.joinUrl, teamsJoin);
      });

      test('a Teams meeting the calendar dropped meanwhile is deleted and '
          'made again, invitations and all', () async {
        captureLog();
        final created = await calendar(
          answer: (request) {
            if (request.url.path == '/v1.0/me/calendar') {
              return teamsCalendar(request);
            }
            return switch (request.method) {
              'PATCH' => json(teamsEvent(online: false, joinUrl: null)),
              'POST' when purge(request) => http.Response('', 204),
              'POST' => json(teamsEvent(id: 'evt-2'), 201),
              _ => json(teamsEvent()),
            };
          },
        ).createMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.teams, prepared: teamsMade),
        );

        expect(sent.map((r) => '${r.method} ${r.url.path}'), [
          'PATCH /v1.0/me/events/evt-1',
          'GET /v1.0/me/events/evt-1',
          'POST /v1.0/me/events/evt-1/permanentDelete',
          'GET /v1.0/me/calendar',
          'POST /v1.0/me/events',
        ]);
        final body = jsonDecode(sent.last.body) as Map;
        expect(body['attendees'], hasLength(2));
        expect(body['isOnlineMeeting'], isTrue);
        expect(body['onlineMeetingProvider'], 'teamsForBusiness');
        expect(created.id, 'evt-2');
        expect(created.joinUrl, teamsJoin);
      });

      test('Google Meet on a Microsoft account is a link alone, with no event '
          'made anywhere', () async {
        final prepared = await calendar(answer: meetAndTeams, accounts: everyone)
            .prepareOnlineMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.googleMeet),
        );

        expect(sent.map((r) => r.url.host), ['meet.googleapis.com']);
        expect(asked, [('acct-g', GoogleOAuth.meetScopes)]);
        expect(prepared!.eventId, isNull);
        expect(prepared.bodyHtml, isNull);
        expect(prepared.joinUrl, 'https://meet.google.com/abc-defg-hij');
        expect(prepared.inviteText,
            'Join with Google Meet: https://meet.google.com/abc-defg-hij');
      });

      test('and Send makes no second space, and the invitation carries the '
          'line shown, once', () async {
        final c = calendar(answer: meetAndTeams, accounts: everyone);
        final prepared = await c.prepareOnlineMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.googleMeet),
        );
        sent.clear();

        final created = await c.createMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.googleMeet, prepared: prepared),
        );

        expect(sent.map((r) => '${r.method} ${r.url.host}'),
            ['POST graph.microsoft.com']);
        final content =
            ((jsonDecode(sent.single.body) as Map)['body'] as Map)['content']
                as String;
        expect(
          RegExp(RegExp.escape(prepared!.inviteText)).allMatches(content),
          hasLength(1),
        );
        expect(created.joinUrl, 'https://meet.google.com/abc-defg-hij');
      });

      test('one made for another account, or of another kind, is left out of '
          'it', () async {
        final c = calendar(answer: meetAndTeams, accounts: everyone);

        // Another account's: that account's calendar is not this one's.
        await c.createMeeting(
          microsoft,
          meeting(
            online: OnlineMeetingKind.teams,
            prepared: const PreparedMeeting(
              accountId: 'acct-other',
              kind: OnlineMeetingKind.teams,
              eventId: 'evt-x',
              joinUrl: teamsJoin,
              inviteText: 'Microsoft Teams meeting',
              bodyHtml: teamsBody,
            ),
          ),
        );
        expect(sent.map((r) => r.method), ['GET', 'POST']);
        expect(sent.map((r) => r.url.path), isNot(contains(contains('evt-x'))));

        // A Teams meeting made ahead, with Google Meet chosen since: its link
        // is not a Meet link.
        sent.clear();
        final created = await c.createMeeting(
          microsoft,
          meeting(online: OnlineMeetingKind.googleMeet, prepared: teamsMade),
        );
        expect(sent.map((r) => '${r.method} ${r.url.host}'),
            ['POST meet.googleapis.com', 'POST graph.microsoft.com']);
        expect(created.joinUrl, 'https://meet.google.com/abc-defg-hij');

        // And the switch turned off: nothing made ahead is used.
        sent.clear();
        await c.createMeeting(microsoft, meeting(prepared: teamsMade));
        expect(sent.map((r) => r.method), ['POST']);
        expect((jsonDecode(sent.single.body) as Map)['isOnlineMeeting'],
            isFalse);
      });

      test('discarding a Meet link made for a Microsoft account asks nothing '
          'of anyone', () async {
        await calendar(answer: meetAndTeams, accounts: everyone)
            .discardPreparedMeeting(
          microsoft,
          const PreparedMeeting(
            accountId: 'acct-ms',
            kind: OnlineMeetingKind.googleMeet,
            joinUrl: 'https://meet.google.com/abc-defg-hij',
            inviteText: 'Join with Google Meet: '
                'https://meet.google.com/abc-defg-hij',
          ),
        );

        expect(sent, isEmpty);
        expect(asked, isEmpty);
      });

      test('discarding a Teams meeting made ahead deletes its event, on the '
          'calendar\'s token', () async {
        final done = await calendar(answer: teamsShells)
            .discardPreparedMeeting(microsoft, teamsMade);

        expect(done, isTrue);
        expect(sent.map((r) => '${r.method} ${r.url.path}'), [
          'GET /v1.0/me/events/evt-1',
          'POST /v1.0/me/events/evt-1/permanentDelete',
        ]);
        expect(asked.map((a) => a.$2),
            everyElement(MicrosoftOAuth.calendarScopes));
      });

      group('on a Gmail account', () {
        const meetMade = PreparedMeeting(
          accountId: 'acct-g',
          kind: OnlineMeetingKind.googleMeet,
          eventId: 'evt-g',
          joinUrl: 'https://meet.google.com/own-link',
          inviteText: 'Join with Google Meet',
        );

        http.Response meetEvent(String id) => json({
              'id': id,
              'conferenceData': {
                'entryPoints': [
                  {
                    'entryPointType': 'video',
                    'uri': 'https://meet.google.com/own-link',
                  },
                ],
              },
            });

        test('Meet is an event on its own calendar, nobody told', () async {
          final prepared = await calendar(
            answer: (_) => meetEvent('evt-g'),
            accounts: everyone,
          ).prepareOnlineMeeting(
            google,
            meeting(accountId: 'acct-g', online: OnlineMeetingKind.googleMeet),
          );

          final request = sent.single;
          expect(request.method, 'POST');
          expect(request.url.queryParameters['sendUpdates'], 'none');
          expect(asked, [('acct-g', null)]);
          expect(prepared!.eventId, 'evt-g');
          expect(prepared.joinUrl, 'https://meet.google.com/own-link');
        });

        test('Send patches the event made ahead', () async {
          final created = await calendar(
            answer: (_) => meetEvent('evt-g'),
            accounts: everyone,
          ).createMeeting(
            google,
            meeting(
              accountId: 'acct-g',
              online: OnlineMeetingKind.googleMeet,
              prepared: meetMade,
            ),
          );

          expect(sent.map((r) => r.method), ['GET', 'PATCH']);
          expect(sent.last.url.path,
              '/calendar/v3/calendars/primary/events/evt-g');
          expect(created.id, 'evt-g');
          expect(created.joinUrl, 'https://meet.google.com/own-link');
        });

        test('and one deleted meanwhile is made again, invitations and all',
            () async {
          captureLog();
          final created = await calendar(
            answer: (request) => request.method == 'GET'
                ? json({'error': {'code': 404, 'message': 'Not Found'}}, 404)
                : meetEvent('evt-new'),
            accounts: everyone,
          ).createMeeting(
            google,
            meeting(
              accountId: 'acct-g',
              online: OnlineMeetingKind.googleMeet,
              prepared: meetMade,
            ),
          );

          expect(sent.map((r) => r.method), ['GET', 'POST']);
          expect(sent.last.url.queryParameters,
              {'sendUpdates': 'all', 'conferenceDataVersion': '1'});
          expect((jsonDecode(sent.last.body) as Map)['attendees'],
              hasLength(2));
          expect(created.id, 'evt-new');
        });

        test('and one Google keeps as cancelled is made again, never '
            'patched', () async {
          captureLog();
          final created = await calendar(
            answer: (request) => request.method == 'GET'
                ? json({
                    'id': 'evt-g',
                    'status': 'cancelled',
                    'conferenceData': {
                      'entryPoints': [
                        {
                          'entryPointType': 'video',
                          'uri': 'https://meet.google.com/own-link',
                        },
                      ],
                    },
                  })
                : meetEvent('evt-new'),
            accounts: everyone,
          ).createMeeting(
            google,
            meeting(
              accountId: 'acct-g',
              online: OnlineMeetingKind.googleMeet,
              prepared: meetMade,
            ),
          );

          expect(sent.map((r) => r.method), ['GET', 'POST'],
              reason: 'invitations to a cancelled event must not go');
          expect(sent.last.url.path, '/calendar/v3/calendars/primary/events');
          expect(sent.last.url.queryParameters,
              {'sendUpdates': 'all', 'conferenceDataVersion': '1'});
          expect((jsonDecode(sent.last.body) as Map)['attendees'],
              hasLength(2));
          expect(created.id, 'evt-new');
        });
      });

      test('an app password has no calendar to make one on', () async {
        await expectLater(
          calendar().prepareOnlineMeeting(
            appPassword,
            meeting(accountId: 'acct-p', online: OnlineMeetingKind.googleMeet),
          ),
          throwsA(isA<CalendarUnavailable>()),
        );
        expect(sent, isEmpty);
      });

      test('a meeting held in the room alone has none to make', () async {
        await expectLater(
          calendar().prepareOnlineMeeting(microsoft, meeting()),
          throwsA(isA<ArgumentError>()),
        );
        expect(sent, isEmpty);
      });
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
