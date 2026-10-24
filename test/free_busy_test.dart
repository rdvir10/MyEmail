import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/free_busy.dart';
import 'package:myemail/domain/mail_tip.dart';
import 'package:myemail/ui/compose/free_times.dart' show workingDays;

/// Batch 5's sums and questions: free and busy times worked out from the
/// calendars' answers, the questions put to Graph and Google for them,
/// MailTips, and an answer to an invitation with more than a tap to it.
void main() {
  // Sunday 25 October 2026, on the phone's own clock, and the days after.
  DateTime at(int day, int hour, [int minute = 0]) =>
      DateTime(2026, 10, day, hour, minute);
  TimeSpan span(DateTime start, DateTime end) => (start: start, end: end);

  group('busy times', () {
    test('overlapping and touching are one; empty ones go', () {
      expect(
        mergeBusy([
          span(at(25, 14), at(25, 15)),
          span(at(25, 9), at(25, 10)),
          span(at(25, 9, 30), at(25, 11)),
          span(at(25, 11), at(25, 12)),
          span(at(25, 16), at(25, 16)),
        ]),
        [span(at(25, 9), at(25, 12)), span(at(25, 14), at(25, 15))],
      );
    });

    test('free between the hours asked, around what is busy, as long as '
        'asked', () {
      final busy = [
        span(at(25, 10), at(25, 11)),
        span(at(25, 12, 15), at(25, 12, 30)),
      ];

      expect(freeOn(at(25, 0), busy), [
        span(at(25, 9), at(25, 10)),
        span(at(25, 11), at(25, 12, 15)),
        span(at(25, 12, 30), at(25, 17)),
      ]);
      expect(
        freeOn(at(25, 0), busy, shortest: const Duration(minutes: 70)),
        [span(at(25, 11), at(25, 12, 15)), span(at(25, 12, 30), at(25, 17))],
      );
      expect(freeOn(at(25, 0), busy, from: 8, to: 10),
          [span(at(25, 8), at(25, 10))]);
    });

    test('nothing already gone: from the next half hour', () {
      expect(freeOn(at(25, 0), const [], notBefore: at(25, 10, 17)).first.start,
          at(25, 10, 30));
      expect(freeOn(at(25, 0), const [], notBefore: at(25, 10)).first.start,
          at(25, 10));
      expect(freeOn(at(25, 0), const [], notBefore: at(25, 10, 45)).first.start,
          at(25, 11));
      expect(freeOn(at(25, 0), const [], notBefore: at(25, 7)).first.start,
          at(25, 9), reason: 'the morning not begun is all there');
    });

    test('a meeting from the night before takes the morning', () {
      expect(
        freeOn(at(25, 0), [span(at(24, 22), at(25, 9, 30))]),
        [span(at(25, 9, 30), at(25, 17))],
      );
    });
  });

  group('next free time', () {
    test('the first time free on every calendar', () {
      final calendars = [
        [span(at(26, 8), at(26, 12))],
        [span(at(26, 13), at(26, 18))],
      ];

      expect(
        nextFree(calendars,
            after: at(26, 8), length: const Duration(hours: 1)),
        span(at(26, 12), at(26, 13)),
      );
      expect(
        nextFree(calendars,
            after: at(26, 8), length: const Duration(hours: 2)),
        span(at(27, 8), at(27, 10)),
        reason: 'no two hours on Monday: Tuesday morning',
      );
    });

    test('passes over the days not worked', () {
      // Thursday 29 October at half past five: half an hour left of it.
      expect(
        nextFree(const [], after: at(29, 17, 30), length: const Duration(hours: 1)),
        span(at(30, 8), at(30, 9)),
      );
      expect(
        nextFree(const [], after: at(30, 17, 30), length: const Duration(hours: 1)),
        span(DateTime(2026, 11, 2, 8), DateTime(2026, 11, 2, 9)),
        reason: 'Saturday and Sunday are not worked',
      );
      expect(
        nextFree(
          const [],
          after: at(29, 17, 30),
          length: const Duration(hours: 1),
          workWeek: const {
            DateTime.sunday,
            DateTime.monday,
            DateTime.tuesday,
            DateTime.wednesday,
            DateTime.thursday,
          },
        ),
        span(DateTime(2026, 11, 1, 8), DateTime(2026, 11, 1, 9)),
        reason: 'a week worked from Sunday',
      );
    });

    test('none in the days looked at', () {
      expect(
        nextFree(
          [
            [span(at(25, 0), DateTime(2026, 11, 30))],
          ],
          after: at(25, 8),
          length: const Duration(minutes: 30),
        ),
        isNull,
      );
    });

    test('working days from a date, the days not worked passed over', () {
      expect(workingDays(at(29, 0), 3), [
        DateTime(2026, 10, 29),
        DateTime(2026, 10, 30),
        DateTime(2026, 11, 2),
      ]);
      expect(workingDays(at(29, 0), 2, workWeek: const {DateTime.sunday}), [
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 8),
      ]);
      expect(workingDays(at(29, 0), 2, workWeek: const {}), isEmpty);
    });
  });

  test('free times written into a message, a day a line', () {
    final byDay = {
      DateTime(2026, 10, 26): <TimeSpan>[],
      DateTime(2026, 10, 25): [
        span(at(25, 9), at(25, 10)),
        span(at(25, 13, 30), at(25, 17)),
      ],
    };

    expect(
      freeTimesHtml(byDay, use24h: true, zone: 'EDT'),
      '<div>Times I am free (EDT):</div><ul>'
      '<li>Sunday 25 October: 09:00–10:00, 13:30–17:00</li>'
      '<li>Monday 26 October: no free time</li></ul>',
    );
    expect(
      freeTimesHtml(byDay, use24h: false, zone: 'EDT'),
      contains('9:00 AM–10:00 AM, 1:30 PM–5:00 PM'),
    );
  });

  group('MailTips', () {
    test('say what there is to say, and nothing for a small list', () {
      const away = MailTip(
        email: 'dana@hadco.com',
        autoReply: 'Away until Sunday.',
        external: true,
      );
      expect(away.isEmpty, isFalse);
      expect(away.linesFor('Dana'), [
        'Dana has an automatic reply on: "Away until Sunday."',
        'Dana is outside your organisation.',
      ]);
      expect(const MailTip(email: 'team@hadco.com', memberCount: 10).isEmpty,
          isTrue);
      expect(
        const MailTip(email: 'all@hadco.com', memberCount: 40)
            .linesFor('All staff'),
        ['All staff is a list of 40 people.'],
      );
      expect(
        const MailTip(email: 'x@hadco.com', mailboxFull: true, restricted: true)
            .linesFor('X'),
        ["X doesn't take mail from you.", "X's mailbox is full."],
      );
    });

    test("read from Graph's answer", () {
      final tip = GraphMailApi.mailTipFrom({
        'emailAddress': {'address': 'dana@hadco.com'},
        'automaticReplies': {
          'message': '<html><body><p>I am away until <b>Sunday</b>.</p>'
              '<p>Call the office.</p></body></html>',
        },
        'recipientScope': 'external, externalPartner',
        'totalMemberCount': 1,
        'mailboxFull': true,
        'deliveryRestricted': false,
      })!;

      expect(tip.email, 'dana@hadco.com');
      expect(tip.autoReply, 'I am away until Sunday. Call the office.');
      expect(tip.external, isTrue);
      expect(tip.memberCount, isNull, reason: 'one person is not a list');
      expect(tip.mailboxFull, isTrue);
      expect(tip.restricted, isFalse);

      final long = GraphMailApi.mailTipFrom({
        'emailAddress': {'address': 'a@hadco.com'},
        'automaticReplies': {'message': 'word ' * 60},
        'recipientScope': 'internal',
        'totalMemberCount': 30,
      })!;
      expect(long.autoReply!.length, 140);
      expect(long.autoReply, endsWith('…'));
      expect(long.external, isFalse);
      expect(long.memberCount, 30);

      expect(GraphMailApi.mailTipFrom({'emailAddress': <String, Object?>{}}),
          isNull);
    });
  });

  group('Graph', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) answer;

    setUp(() => sent = []);

    http.Response json(Object body, {int status = 200}) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );

    final client = http_testing.MockClient((request) async {
      sent.add(request);
      return answer(request);
    });
    GraphMailApi mail() => GraphMailApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: client,
          sleep: (_) async {},
        );
    GraphCalendarApi calendar() => GraphCalendarApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: client,
          sleep: (_) async {},
        );
    Map<String, Object?> bodyOf(http.Request r) =>
        (jsonDecode(r.body) as Map).cast<String, Object?>();

    test('MailTips are asked for, all the kinds the line shows', () async {
      answer = (_) => json({
            'value': [
              {
                'emailAddress': {'address': 'dana@hadco.com'},
                'automaticReplies': {'message': 'Away.'},
              },
              {'emailAddress': <String, Object?>{}},
            ],
          });

      final tips = await mail().mailTips(['dana@hadco.com', 'x@hadco.com']);

      expect(tips.single.autoReply, 'Away.');
      final request = sent.single;
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/me/getMailTips'));
      final body = bodyOf(request);
      expect(body['EmailAddresses'], ['dana@hadco.com', 'x@hadco.com']);
      for (final kind in [
        'automaticReplies',
        'mailboxFullStatus',
        'totalMemberCount',
        'deliveryRestriction',
        'recipientScope',
      ]) {
        expect('${body['MailTipsOptions']}', contains(kind));
      }

      sent.clear();
      expect(await mail().mailTips(const []), isEmpty);
      expect(sent, isEmpty, reason: 'nobody to ask about');
    });

    group('an invitation answered', () {
      setUp(() {
        answer = (request) => request.method == 'GET'
            ? json({'id': 'e-1'})
            : http.Response('', 202);
      });

      test('with a note, which goes to the organiser', () async {
        await mail().respondToInvite('m-1', InviteResponse.accepted,
            note: '  Running late.  ');

        final post = sent.last;
        expect(post.url.path, endsWith('/me/events/e-1/accept'));
        expect(bodyOf(post),
            {'sendResponse': true, 'comment': 'Running late.'});
      });

      test('without a word to the organiser', () async {
        await mail().respondToInvite('m-1', InviteResponse.declined,
            send: false);

        final post = sent.last;
        expect(post.url.path, endsWith('/me/events/e-1/decline'));
        expect(bodyOf(post), {'sendResponse': false});
      });

      test('with a new time, in UTC, always sent', () async {
        await mail().respondToInvite(
          'm-1',
          InviteResponse.tentative,
          send: false,
          proposal: (
            start: DateTime.utc(2026, 10, 26, 13),
            end: DateTime.utc(2026, 10, 26, 14),
          ),
        );

        final post = sent.last;
        expect(post.url.path, endsWith('/me/events/e-1/tentativelyAccept'));
        expect(bodyOf(post), {
          'sendResponse': true,
          'proposedNewTime': {
            'start': {'dateTime': '2026-10-26T13:00:00.000', 'timeZone': 'UTC'},
            'end': {'dateTime': '2026-10-26T14:00:00.000', 'timeZone': 'UTC'},
          },
        });
      });
    });

    test('your busy times: all but free, working elsewhere, cancelled and '
        'turned down, every page', () async {
      Map<String, Object?> event(String showAs, int hour,
              {bool cancelled = false, String response = 'accepted'}) =>
          {
            'showAs': showAs,
            'isCancelled': cancelled,
            'responseStatus': {'response': response},
            'start': {'dateTime': '2026-10-26T$hour:00:00.0000000'},
            'end': {'dateTime': '2026-10-26T$hour:30:00.0000000'},
          };
      answer = (request) => request.url.queryParameters.containsKey('page')
          ? json({
              'value': [event('oof', 16)],
            })
          : json({
              'value': [
                event('busy', 10),
                event('tentative', 11),
                event('free', 12),
                event('workingElsewhere', 13),
                event('busy', 14, cancelled: true),
                event('busy', 15, response: 'declined'),
              ],
              '@odata.nextLink':
                  'https://graph.microsoft.com/v1.0/me/calendarView?page=2',
            });

      final busy = await calendar()
          .busy(DateTime.utc(2026, 10, 26), DateTime.utc(2026, 10, 27));

      expect([for (final b in busy) b.start.hour], [10, 11, 16]);
      expect(busy.first.start, DateTime.utc(2026, 10, 26, 10));
      final first = sent.first;
      expect(first.url.path, endsWith('/me/calendarView'));
      expect(first.url.queryParameters['startDateTime'],
          '2026-10-26T00:00:00.000Z');
      expect(first.url.queryParameters['endDateTime'],
          '2026-10-27T00:00:00.000Z');
      expect(first.headers['Prefer'], 'outlook.timezone="UTC"');
      expect(sent, hasLength(2));
    });

    test("everyone's busy times, as the organisation lets them be seen",
        () async {
      answer = (_) => json({
            'value': [
              {
                'scheduleId': 'Dana@Hadco.com',
                'scheduleItems': [
                  {
                    'status': 'busy',
                    'start': {'dateTime': '2026-10-26T13:00:00.0000000'},
                    'end': {'dateTime': '2026-10-26T14:00:00.0000000'},
                  },
                  {
                    'status': 'free',
                    'start': {'dateTime': '2026-10-26T15:00:00.0000000'},
                    'end': {'dateTime': '2026-10-26T16:00:00.0000000'},
                  },
                ],
              },
              {
                'scheduleId': 'someone@example.org',
                'error': {
                  'message': 'Not found',
                  'responseCode': 'ErrorMailRecipientNotFound',
                },
              },
            ],
          });

      final schedules = await calendar().schedules(
        ['Dana@Hadco.com', 'someone@example.org'],
        DateTime.utc(2026, 10, 26),
        DateTime.utc(2026, 10, 27),
      );

      expect(schedules, {
        'dana@hadco.com': [
          (
            start: DateTime.utc(2026, 10, 26, 13),
            end: DateTime.utc(2026, 10, 26, 14),
          ),
        ],
        'someone@example.org': null,
      });
      final request = sent.single;
      expect(request.url.path, endsWith('/me/calendar/getSchedule'));
      expect(bodyOf(request), {
        'schedules': ['Dana@Hadco.com', 'someone@example.org'],
        'startTime': {'dateTime': '2026-10-26T00:00:00.000', 'timeZone': 'UTC'},
        'endTime': {'dateTime': '2026-10-27T00:00:00.000', 'timeZone': 'UTC'},
        'availabilityViewInterval': 30,
      });

      sent.clear();
      expect(
        await calendar().schedules(
            const [], DateTime.utc(2026, 10, 26), DateTime.utc(2026, 10, 27)),
        isEmpty,
      );
      expect(sent, isEmpty);
    });
  });

  test('from a Gmail account, who is free is its own calendar alone',
      () async {
    const google = Account(
      id: 'acct-g',
      displayName: 'Personal',
      emailAddress: 'Ron@gmail.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF107C41,
    );
    final sent = <http.Request>[];
    final calendars = AccountCalendar(
      accessToken: (accountId, {bool force = false, List<String>? scopes}) async =>
          'token',
      accounts: () => const [google],
      httpClient: http_testing.MockClient((request) async {
        sent.add(request);
        return http.Response(
          jsonEncode({
            'items': [
              {
                'start': {'dateTime': '2026-10-26T10:00:00Z'},
                'end': {'dateTime': '2026-10-26T11:00:00Z'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      sleep: (_) async {},
    );
    final day = DateTime.utc(2026, 10, 26);

    final seen = await calendars.schedules(google,
        ['ron@gmail.com', 'Dana@Example.com'], day, day.add(const Duration(days: 1)));

    expect(seen, {
      'ron@gmail.com': [
        (start: DateTime.utc(2026, 10, 26, 10), end: DateTime.utc(2026, 10, 26, 11)),
      ],
      'dana@example.com': null,
    });
    expect(sent, hasLength(1));

    sent.clear();
    expect(
      await calendars.schedules(
          google, ['dana@example.com'], day, day.add(const Duration(days: 1))),
      {'dana@example.com': null},
    );
    expect(sent, isEmpty, reason: 'nothing of its own asked about');
  });

  test('Google: your busy times, all but free, turned down and cancelled; a '
      'whole day from your own midnight', () async {
    final sent = <http.Request>[];
    final api = GoogleCalendarApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: http_testing.MockClient((request) async {
        sent.add(request);
        return http.Response(
          jsonEncode({
            'items': [
              {
                'start': {'dateTime': '2026-10-26T10:00:00-04:00'},
                'end': {'dateTime': '2026-10-26T11:00:00-04:00'},
              },
              {
                'transparency': 'transparent',
                'start': {'dateTime': '2026-10-26T12:00:00-04:00'},
                'end': {'dateTime': '2026-10-26T13:00:00-04:00'},
              },
              {
                'attendees': [
                  {'email': 'dana@example.com', 'responseStatus': 'accepted'},
                  {'self': true, 'responseStatus': 'declined'},
                ],
                'start': {'dateTime': '2026-10-26T14:00:00-04:00'},
                'end': {'dateTime': '2026-10-26T15:00:00-04:00'},
              },
              {
                'status': 'cancelled',
                'start': {'dateTime': '2026-10-26T16:00:00-04:00'},
                'end': {'dateTime': '2026-10-26T17:00:00-04:00'},
              },
              {
                'start': {'date': '2026-10-27'},
                'end': {'date': '2026-10-28'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      sleep: (_) async {},
    );

    final busy = await api.busy(
        DateTime.utc(2026, 10, 26), DateTime.utc(2026, 10, 28, 4));

    expect(busy, [
      (
        start: DateTime.utc(2026, 10, 26, 14),
        end: DateTime.utc(2026, 10, 26, 15),
      ),
      (start: DateTime(2026, 10, 27), end: DateTime(2026, 10, 28)),
    ]);
    final query = sent.single.url.queryParameters;
    expect(sent.single.url.path, endsWith('/calendars/primary/events'));
    expect(query['singleEvents'], 'true');
    expect(query['timeMin'], '2026-10-26T00:00:00.000Z');
    expect(query['timeMax'], '2026-10-28T04:00:00.000Z');
  });
}
