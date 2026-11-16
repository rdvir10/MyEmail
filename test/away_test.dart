import 'dart:async';
import 'dart:convert';
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/away_run.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/away.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart' show InviteResponse;
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart'
    show calendarRefreshProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/away_screen.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/settings/auto_replies_screen.dart';

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// I am away (calendar idea #53): the days blocked as out of office, and
/// the meetings in them declined, or cancelled where they are Ron's own,
/// as he ticks them. The most dangerous screen in the app: nothing goes
/// out that Ron did not see listed and leave ticked, never a whole series,
/// never twice, for a Microsoft account and a Google one alike.
void main() {
  setUpAll(() async {
    FakeWebViewPlatform.install();
    await loadRoboto();
  });

  // Tuesday morning; away Wednesday to Friday.
  final now = DateTime(2026, 11, 17, 10, 17);
  final wed = DateTime(2026, 11, 18), fri = DateTime(2026, 11, 20);
  DateTime at(int day, int h, [int m = 0]) => DateTime(2026, 11, day, h, m);

  const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');
  const ronG = MailAddress(email: 'ron@gmail.example', name: 'Ron');
  const dana = MailAddress(email: 'dana.levi@hadco.example', name: 'Dana Levi');
  const yossi = MailAddress(email: 'yossi@hadco.example', name: 'Yossi');
  const tom = MailAddress(email: 'tom@gmail.example', name: 'Tom Becker');
  const steel =
      MailAddress(email: 'events@steel.example', name: 'Steel Weekly');

  /// Someone else's meeting Ron was invited to.
  CalendarEvent invited(
    String accountId,
    String id,
    DateTime start, {
    MailAddress organizer = dana,
    MailAddress me = ron,
    String? seriesId,
    EventResponse response = EventResponse.notResponded,
    String title = 'Design review',
    String calendarId = CalendarEvent.mainCalendar,
    bool readOnly = false,
    bool cancelled = false,
    Duration length = const Duration(hours: 1),
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        calendarId: calendarId,
        title: title,
        start: start,
        end: start.add(length),
        organizer: organizer,
        attendees: [
          EventAttendee(organizer, response: EventResponse.organizer),
          EventAttendee(me, response: response),
        ],
        response: response,
        seriesId: seriesId,
        readOnly: readOnly,
        cancelled: cancelled,
      );

  /// One of Ron's own, with others on it.
  CalendarEvent own(
    String accountId,
    String id,
    DateTime start, {
    MailAddress me = ron,
    List<MailAddress> others = const [dana, yossi],
    String? seriesId,
    String title = 'Q4 planning',
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        title: title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        organizer: me,
        isOrganizer: true,
        attendees: [
          EventAttendee(me, response: EventResponse.organizer),
          for (final o in others)
            EventAttendee(o, response: EventResponse.accepted),
        ],
        response: EventResponse.organizer,
        seriesId: seriesId,
      );

  /// Hadco's (Microsoft) week: a stand-up series, a review, Ron's own
  /// planning and his own weekly series, and what Away leaves out.
  List<CalendarEvent> hadcoWeek(String h) => [
        for (final d in [17, 18, 19, 20, 23])
          invited(h, 'standup-$d', at(d, 9),
              seriesId: 'standup',
              title: 'Daily stand-up',
              response: EventResponse.accepted),
        invited(h, 'design', at(18, 11)),
        own(h, 'q4', at(18, 15)),
        own(h, 'own-sync-19', at(19, 16),
            seriesId: 'own-sync', title: 'Team sync'),
        invited(h, 'declined', at(19, 12),
            response: EventResponse.declined, title: 'Lunch & learn'),
        invited(h, 'called-off', at(19, 10),
            cancelled: true, title: 'Vendor demo'),
        CalendarEvent(
          id: 'dentist',
          accountId: h,
          title: 'Dentist',
          start: at(20, 8),
          end: at(20, 9),
        ),
        invited(h, 'boss', at(18, 14),
            calendarId: 'boss-calendar', title: "Boss's board meeting"),
        invited(h, 'holiday', at(19, 0),
            readOnly: true, title: 'Holiday', length: const Duration(days: 1)),
        invited(h, 'from-gmail', at(18, 13),
            organizer: ronG, title: 'Dinner plans'),
        invited(h, 'tuesday', at(17, 14), title: 'Before'),
        invited(h, 'monday', at(23, 14), title: 'After'),
      ];

  /// Gmail's (Google): a webinar, dinner, and Ron's own gym series.
  List<CalendarEvent> gmailWeek(String g) => [
        invited(g, 'webinar', at(19, 13),
            organizer: steel, me: ronG, title: 'Steel prices outlook'),
        invited(g, 'dinner', at(20, 19),
            organizer: tom,
            me: ronG,
            response: EventResponse.accepted,
            title: 'Dinner with the Beckers'),
        own(g, 'spin-19', at(19, 7),
            me: ronG, others: [tom], seriesId: 'spin', title: 'Spin class'),
      ];

  // --- what is listed, what starts ticked, and what the button says ---------

  group('the list', () {
    final emails = {'h': ron.email, 'g': ronG.email};
    final all = [...hadcoWeek('h'), ...gmailWeek('g')];

    test('what Ron was invited to and his own, apart; each meeting of a '
        'series in the days on its own', () {
      final listed = awayMeetings(all,
          first: wed, last: fri, now: now, ownEmails: emails);
      expect([for (final e in listed.invited) e.id], [
        'standup-18',
        'design',
        'from-gmail',
        'standup-19',
        'webinar',
        'standup-20',
        'dinner',
      ]);
      expect([for (final e in listed.own) e.id],
          ['q4', 'spin-19', 'own-sync-19']);
    });

    test('left out: before and after the days, over, declined, cancelled '
        'by its organiser, an appointment, a calendar only read, and a '
        'calendar beside the main one', () {
      final listed = awayMeetings(all,
          first: wed, last: fri, now: now, ownEmails: emails);
      final ids = {
        for (final e in [...listed.invited, ...listed.own]) e.id,
      };
      for (final out in [
        'standup-17',
        'standup-23',
        'tuesday',
        'monday',
        'declined',
        'called-off',
        'dentist',
        'holiday',
        'boss',
      ]) {
        expect(ids, isNot(contains(out)), reason: out);
      }
      // Over by now, on the first day.
      final early = awayMeetings(all,
          first: wed, last: fri, now: at(18, 12), ownEmails: emails);
      expect([for (final e in early.invited) e.id],
          isNot(contains('standup-18')));
      expect([for (final e in early.invited) e.id], contains('from-gmail'));
    });

    test('a series itself is never listed, only its meetings', () {
      final master = invited('h', 'standup', at(18, 9), seriesId: 'standup');
      final listed = awayMeetings([master],
          first: wed, last: fri, now: now, ownEmails: emails);
      expect(listed.invited, isEmpty);
    });

    test('what starts ticked: invitations, but one Ron organised from '
        'another of his addresses; his own never', () {
      final listed = awayMeetings(all,
          first: wed, last: fri, now: now, ownEmails: emails);
      final ticked = {
        for (final e in [...listed.invited, ...listed.own])
          if (awayStartsTicked(e, emails.values)) e.id,
      };
      expect(ticked, {
        'standup-18',
        'design',
        'standup-19',
        'webinar',
        'standup-20',
        'dinner',
      });
    });

    test('a calendar already out of office for every one of the days', () {
      final block = CalendarEvent(
        id: 'oof',
        accountId: 'h',
        title: 'Vacation',
        start: wed,
        end: DateTime(2026, 11, 21),
        allDay: true,
        showAs: EventShowAs.outOfOffice,
      );
      expect(awayBlockOn([block], 'h', first: wed, last: fri), block);
      expect(awayBlockOn([block], 'g', first: wed, last: fri), isNull);
      expect(
          awayBlockOn([block], 'h', first: wed, last: DateTime(2026, 11, 23)),
          isNull,
          reason: 'not every day');
      expect(
          awayBlockOn([block.copyWith(), _busy(block)], 'h',
              first: wed, last: fri),
          block);
      expect(awayBlockOn([_busy(block)], 'h', first: wed, last: fri), isNull);
    });

    test('the block: the days, all day, out of office, nobody on it, no '
        'reminder, the one key however often it goes', () {
      final draft = awayBlock(
        accountId: 'h',
        first: at(18, 0),
        last: at(20, 0),
        transactionId: 'k1',
        timeZone: 'Asia/Jerusalem',
      );
      expect(draft.title, 'Out of office');
      expect(draft.allDay, isTrue);
      expect(draft.start, wed);
      expect(draft.end, fri, reason: 'a whole day ends on its last day');
      expect(draft.showAs, EventShowAs.outOfOffice);
      expect(draft.attendees, isEmpty);
      expect(draft.reminder, const Reminder.none());
      expect(draft.transactionId, 'k1');
      expect(draft.calendarId, CalendarEvent.mainCalendar);
      expect(draft.online, isNull);
      expect(draft.problem, isNull);
    });

    test('the button says in numbers what it will do', () {
      expect(awayButtonWords(blocks: 1, declines: 5, cancels: 2),
          'Block the days, decline 5, cancel 2');
      expect(awayButtonWords(blocks: 2, declines: 5, cancels: 0),
          'Block on 2 calendars, decline 5');
      expect(awayButtonWords(blocks: 0, declines: 1, cancels: 0), 'Decline 1');
      expect(awayButtonWords(blocks: 0, declines: 0, cancels: 3), 'Cancel 3');
      expect(awayButtonWords(blocks: 0, declines: 0, cancels: 0), isNull);
      expect(
          awayButtonWords(blocks: 0, declines: 2, cancels: 1, again: true),
          'Try again: decline 2, cancel 1');
    });
  });

  // --- doing it: each once, one meeting, never twice -----------------------

  group('doing it', () {
    late _Engine engine;
    late List<CalendarEvent> hadco;

    setUp(() {
      engine = _Engine();
      hadco = hadcoWeek('h');
      engine.events['h'] = hadco;
    });

    CalendarEvent byId(String id) => hadco.firstWhere((e) => e.id == id);

    test('each ticked one once, in order: the block, the declines, the '
        'cancellations; one meeting of a series, never the series', () async {
      final items = [
        AwayItem.block(awayBlock(
            accountId: 'h', first: wed, last: fri, transactionId: 'k')),
        AwayItem.decline(byId('standup-19')),
        AwayItem.decline(byId('design')),
        AwayItem.cancel(byId('own-sync-19')),
      ];
      await AwayRun(engine).go(items,
          first: wed, last: fri, note: ' Away until Monday. ', tell: true);
      expect(engine.meetings.single.title, 'Out of office');
      expect(engine.calendarActions, [
        'respond standup-19 declined note=Away until Monday.',
        'respond design declined note=Away until Monday.',
        'cancel own-sync-19 note=Away until Monday.',
      ]);
      expect(engine.calendarActions, everyElement(isNot(contains('series'))));
      expect([for (final i in items) i.state], everyElement(AwayState.done));
    });

    test('the organisers not told: declined without a word or a note; a '
        'cancellation still tells everyone', () async {
      await AwayRun(engine).go([
        AwayItem.decline(byId('design')),
        AwayItem.cancel(byId('q4')),
      ], first: wed, last: fri, note: 'Away', tell: false);
      expect(engine.calendarActions,
          ['respond design declined quietly', 'cancel q4 note=Away']);
    });

    test('a series itself is refused, should one ever reach it', () async {
      final master = invited('h', 'standup', at(18, 9), seriesId: 'standup');
      final item = AwayItem.decline(master);
      await AwayRun(engine).go([item], first: wed, last: fri);
      expect(engine.calendarActions, isEmpty);
      expect(item.state, AwayState.failed);
    });

    test('done and gone ones are never done again; a press goes through '
        'each once', () async {
      final done = AwayItem.decline(byId('design'))..state = AwayState.done;
      final gone = AwayItem.decline(byId('standup-18'))
        ..state = AwayState.gone;
      final fresh = AwayItem.decline(byId('standup-19'));
      await AwayRun(engine).go([done, gone, fresh, fresh],
          first: wed, last: fri);
      expect(engine.calendarActions, ['respond standup-19 declined']);
    });

    test('one of twelve fails half way: the rest still go, and a press '
        'again does only it, once it is found still there as it was',
        () async {
      final twelve = [
        for (var i = 0; i < 12; i++)
          invited('h', 'm$i', at(18, 8).add(Duration(minutes: 30 * i)),
              title: 'Meeting $i'),
      ];
      engine.events['h'] = twelve;
      engine.refuse.add('m5');
      final items = [for (final e in twelve) AwayItem.decline(e)];
      final run = AwayRun(engine);
      final through = <int>[];
      await run.go(items, first: wed, last: fri, changed: through.add);
      expect(engine.calendarActions,
          [for (var i = 0; i < 12; i++) if (i != 5) 'respond m$i declined']);
      expect(items[5].state, AwayState.failed);
      expect(items[5].problem, 'Exchange said no.');
      expect([for (final i in items) i.state].where((s) => s == AwayState.done),
          hasLength(11));
      expect(through.last, 12);

      engine.refuse.clear();
      engine.calendarActions.clear();
      await run.go(items, first: wed, last: fri);
      expect(engine.calendarActions, ['respond m5 declined']);
      expect(engine.reads, 1, reason: 'its calendar read again first');
      expect([for (final i in items) i.state], everyElement(AwayState.done));
    });

    test("one whose answer was lost: Google kept it declined, so it is not "
        'answered again', () async {
      engine.loseAnswer.add('design');
      final item = AwayItem.decline(byId('design'));
      final run = AwayRun(engine);
      await run.go([item], first: wed, last: fri);
      expect(item.state, AwayState.failed);
      expect(engine.calendarActions, ['respond design declined']);
      engine.loseAnswer.clear();
      await run.go([item], first: wed, last: fri);
      expect(engine.calendarActions, ['respond design declined'],
          reason: 'not twice');
      expect(item.state, AwayState.done);
    });

    test('one whose answer was lost: Exchange took it off the calendar, so '
        'nothing more is sent', () async {
      engine
        ..loseAnswer.add('design')
        ..takesDeclinedOff = true;
      final item = AwayItem.decline(byId('design'));
      final run = AwayRun(engine);
      await run.go([item], first: wed, last: fri);
      engine.loseAnswer.clear();
      await run.go([item], first: wed, last: fri);
      expect(engine.calendarActions, ['respond design declined']);
      expect(item.state, AwayState.gone);
    });

    test('a cancellation whose answer was lost is not sent again',
        () async {
      engine.loseAnswer.add('q4');
      final item = AwayItem.cancel(byId('q4'));
      final run = AwayRun(engine);
      await run.go([item], first: wed, last: fri);
      engine.loseAnswer.clear();
      await run.go([item], first: wed, last: fri);
      expect(engine.calendarActions, ['cancel q4']);
      expect(item.state, AwayState.gone);
    });

    test('where its calendar cannot be read again, it is not tried again',
        () async {
      engine.refuse.add('design');
      final item = AwayItem.decline(byId('design'));
      final run = AwayRun(engine);
      await run.go([item], first: wed, last: fri);
      engine
        ..refuse.clear()
        ..calendarRefusals['h'] = const ConnectionFailed('No connection.');
      await run.go([item], first: wed, last: fri);
      expect(engine.calendarActions, isEmpty);
      expect(item.state, AwayState.failed);
      expect(item.problem, contains('Not tried again'));
      expect(item.problem, contains('No connection.'));
    });

    test('one gone meanwhile is said gone, and not tried again', () async {
      engine.gone.add('design');
      final item = AwayItem.decline(byId('design'));
      final run = AwayRun(engine);
      await run.go([item], first: wed, last: fri);
      expect(item.state, AwayState.gone);
      engine.gone.clear();
      await run.go([item], first: wed, last: fri);
      expect(engine.calendarActions, isEmpty);
    });

    test('a block whose answer was lost goes again with the same key, which '
        'the calendar answers with the one event', () async {
      engine.loseBlock = true;
      final item = AwayItem.block(awayBlock(
          accountId: 'h', first: wed, last: fri, transactionId: 'same'));
      final run = AwayRun(engine);
      await run.go([item], first: wed, last: fri);
      expect(item.state, AwayState.failed);
      engine.loseBlock = false;
      await run.go([item], first: wed, last: fri);
      expect(item.state, AwayState.done);
      expect([for (final m in engine.meetings) m.transactionId],
          ['same', 'same']);
    });
  });

  // --- on the wire: one meeting, for each kind of account ------------------

  group('on the wire, only the meeting in the days', () {
    late List<http.Request> sent;
    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status,
            headers: {'content-type': 'application/json'});

    const microsoft = Account(
      id: 'h',
      displayName: 'Hadco',
      emailAddress: 'ron@hadco.example',
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF0F6CBD,
    );
    const google = Account(
      id: 'g',
      displayName: 'Gmail',
      emailAddress: 'ron@gmail.example',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFFC239B3,
    );

    _WireEngine wire() {
      sent = [];
      final calendar = AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async =>
            'token',
        accounts: () => const [microsoft, google],
        httpClient: http_testing.MockClient((r) async {
          sent.add(r);
          if (r.url.host == 'www.googleapis.com' && r.method == 'GET') {
            return json({
              'id': r.url.pathSegments.last,
              'status': 'confirmed',
              'attendees': [
                {'email': tom.email, 'organizer': true},
                {
                  'email': ronG.email,
                  'self': true,
                  'responseStatus': 'needsAction',
                },
              ],
            });
          }
          if (r.method == 'DELETE') return http.Response('', 204);
          if (r.url.path.endsWith('/decline') ||
              r.url.path.endsWith('/cancel')) {
            return http.Response('', 202);
          }
          return json({'id': 'made'}, r.method == 'POST' ? 201 : 200);
        }),
        sleep: (_) async {},
      );
      return _WireEngine(calendar, const [microsoft, google]);
    }

    test('Microsoft: a meeting of a series declined and one cancelled, each '
        'by its own id; the series never', () async {
      final engine = wire();
      final standup = invited('h', 'AAMk-standup-19', at(19, 9),
          seriesId: 'AAMk-standup-series');
      final sync = own('h', 'AAMk-sync-19', at(19, 16),
          seriesId: 'AAMk-sync-series');
      await AwayRun(engine).go([
        AwayItem.block(awayBlock(
            accountId: 'h', first: wed, last: fri, transactionId: 'k-h')),
        AwayItem.decline(standup),
        AwayItem.cancel(sync),
      ], first: wed, last: fri, note: 'Away', tell: true);

      expect([for (final r in sent) '${r.method} ${r.url.path}'], [
        'POST /v1.0/me/events',
        'POST /v1.0/me/events/AAMk-standup-19/decline',
        'POST /v1.0/me/events/AAMk-sync-19/cancel',
      ]);
      for (final r in sent) {
        expect(r.url.toString(), isNot(contains('series')));
      }
      final block = jsonDecode(sent[0].body) as Map;
      expect(block['subject'], 'Out of office');
      expect(block['isAllDay'], isTrue);
      expect(block['showAs'], 'oof');
      expect(block['attendees'], isEmpty);
      expect(block['isReminderOn'], isFalse);
      expect(block['transactionId'], 'k-h');
      expect(block['start']['dateTime'], startsWith('2026-11-18T00:00:00'));
      expect(block['end']['dateTime'], startsWith('2026-11-21T00:00:00'));
      expect(jsonDecode(sent[1].body),
          {'sendResponse': true, 'comment': 'Away'});
      expect(jsonDecode(sent[2].body), {'Comment': 'Away'});
    });

    test('Microsoft: not told, the decline is sent without a response',
        () async {
      final engine = wire();
      await AwayRun(engine).go([
        AwayItem.decline(invited('h', 'AAMk-1', at(19, 9))),
      ], first: wed, last: fri, note: 'Away', tell: false);
      expect(jsonDecode(sent.single.body), {'sendResponse': false});
    });

    test('Google: a meeting of a series declined and one cancelled, each by '
        'its own id; the series never', () async {
      final engine = wire();
      final webinar = invited('g', 'webinar123_20261119T130000Z', at(19, 13),
          organizer: tom, me: ronG, seriesId: 'webinar123');
      final spin = own('g', 'spin456_20261119T070000Z', at(19, 7),
          me: ronG, others: [tom], seriesId: 'spin456');
      await AwayRun(engine).go([
        AwayItem.block(awayBlock(
            accountId: 'g', first: wed, last: fri, transactionId: 'kg')),
        AwayItem.decline(webinar),
        AwayItem.cancel(spin),
      ], first: wed, last: fri, note: 'Away', tell: true);

      expect([for (final r in sent) '${r.method} ${r.url.path}'], [
        'POST /calendar/v3/calendars/primary/events',
        'GET /calendar/v3/calendars/primary/events/webinar123_20261119T130000Z',
        'PATCH /calendar/v3/calendars/primary/events/'
            'webinar123_20261119T130000Z',
        'DELETE /calendar/v3/calendars/primary/events/'
            'spin456_20261119T070000Z',
      ]);
      for (final r in sent) {
        expect(r.url.pathSegments.last, isNot(anyOf('webinar123', 'spin456')));
      }
      final block = jsonDecode(sent[0].body) as Map;
      expect(block['summary'], 'Out of office');
      expect(block['start'], {'date': '2026-11-18'});
      expect(block['end'], {'date': '2026-11-21'});
      expect(block['attendees'] ?? const [], isEmpty);
      expect(block['id'], 'kg');
      final answer = jsonDecode(sent[2].body) as Map;
      final mine = (answer['attendees'] as List)
          .cast<Map>()
          .firstWhere((a) => a['self'] == true);
      expect(mine['responseStatus'], 'declined');
      expect(mine['comment'], 'Away');
      expect(sent[2].url.queryParameters['sendUpdates'], 'all');
      expect(sent[3].url.queryParameters['sendUpdates'], 'all');
    });

    test('Google: not told, the decline goes with no update sent', () async {
      final engine = wire();
      await AwayRun(engine).go([
        AwayItem.decline(invited('g', 'w_20261119T130000Z', at(19, 13),
            organizer: tom, me: ronG, seriesId: 'w')),
      ], first: wed, last: fri, note: 'Away', tell: false);
      expect(sent.last.method, 'PATCH');
      expect(sent.last.url.queryParameters['sendUpdates'], 'none');
      final mine = ((jsonDecode(sent.last.body) as Map)['attendees'] as List)
          .cast<Map>()
          .firstWhere((a) => a['self'] == true);
      expect(mine.containsKey('comment'), isFalse);
    });
  });

  // --- the screen ----------------------------------------------------------

  group('the screen', () {
    late MemoryUiStateStore ui;
    setUp(() => ui = MemoryUiStateStore());

    Future<(ProviderContainer, _Engine)> pump(
      WidgetTester tester, {
      _Engine? with_,
      Size size = const Size(412, 915),
      double scale = 1.0,
      double bottomBar = 0,
      bool use24h = true,
      Widget? home,
      bool withCalendar = true,
      void Function(_Engine engine, String hadco, String gmail)? prepare,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = FakeViewPadding(bottom: bottomBar);
      tester.view.viewPadding = FakeViewPadding(bottom: bottomBar);
      addTearDown(tester.view.reset);
      final engine = with_ ?? _Engine();
      if (withCalendar) {
        final token = OAuthToken(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.utc(2030),
        );
        final h = (await tester.runAsync(() => engine.addOAuthAccount(
              displayName: 'Hadco',
              emailAddress: ron.email,
              provider: MailProvider.outlook,
              token: token,
            )))!;
        final g = (await tester.runAsync(() => engine.addOAuthAccount(
              displayName: 'Gmail',
              emailAddress: ronG.email,
              provider: MailProvider.gmail,
              token: token,
            )))!;
        engine
          ..events[h.id] = hadcoWeek(h.id)
          ..events[g.id] = gmailWeek(g.id);
        prepare?.call(engine, h.id, g.id);
      }
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider
            .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
        meetingClockProvider.overrideWithValue(() => now),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: home ?? _Opens(AwayScreen(first: wed, last: fri)),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              alwaysUse24HourFormat: use24h,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (c, engine);
    }

    String idOf(_Engine engine, String name) =>
        engine.events.values.expand((l) => l).firstWhere((e) => e.id == name)
            .accountId;
    Finder rowOf(_Engine engine, String id) =>
        find.byKey(ValueKey('away:${idOf(engine, id)}:$id'));
    bool ticked(WidgetTester tester, Finder row) => tester
        .widget<Checkbox>(
            find.descendant(of: row, matching: find.byType(Checkbox)))
        .value!;
    String button(WidgetTester tester) => tester
        .widget<Text>(find.descendant(
            of: find.byKey(const ValueKey('away-go')),
            matching: find.byType(Text)))
        .data!;

    /// [f] brought on screen, looked for from the top of the list down.
    Future<void> scrollTo(WidgetTester tester, Finder f) async {
      final list = find
          .descendant(
              of: find.byKey(const ValueKey('away-list')),
              matching: find.byType(Scrollable))
          .first;
      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(f, 200, scrollable: list);
      await tester.pumpAndSettle();
    }

    Future<void> press(WidgetTester tester, {bool sure = true}) async {
      await tester.tap(find.byKey(const ValueKey('away-go')));
      await tester.pumpAndSettle();
      if (find.byKey(const ValueKey('away-go-sure')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(
            ValueKey(sure ? 'away-go-sure' : 'away-go-back')));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('Calendar → ⋮ → I am away asks for the days, then lists '
        'them; nothing is sent', (tester) async {
      final (_, engine) = await pump(tester, home: const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-away')));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      expect(find.text('The days you are away'), findsOneWidget);
      await tester.tap(find.text('18').first);
      await tester.pump();
      await tester.tap(find.text('20').first);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(AwayScreen), findsOneWidget);
      final screen = tester.widget<AwayScreen>(find.byType(AwayScreen));
      expect(screen.first, wed);
      expect(screen.last, fri);
      expect(find.text('Wed 18 Nov – Fri 20 Nov'), findsOneWidget);
      expect(find.text('3 days'), findsOneWidget);
      expect(rowOf(engine, 'design'), findsOneWidget);
      expect(engine.calendarActions, isEmpty);
      expect(engine.meetings, isEmpty);
    });

    testWidgets('backing out of the days opens nothing', (tester) async {
      await pump(tester, home: const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-away')));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsNothing);
      expect(find.byType(AwayScreen), findsNothing);
      expect(find.byType(CalendarScreen), findsOneWidget);
    });

    testWidgets('the list as it starts: both calendars to block, invitations '
        'ticked, his own not, and the button says so in numbers',
        (tester) async {
      final (_, engine) = await pump(tester);
      for (final b in engine.events.keys) {
        final row = find.byKey(ValueKey('away-block:$b'));
        expect(ticked(tester, row), isTrue);
      }
      for (final id in ['design', 'standup-18', 'standup-19', 'standup-20']) {
        await scrollTo(tester, rowOf(engine, id));
        expect(ticked(tester, rowOf(engine, id)), isTrue, reason: id);
      }
      await scrollTo(tester, rowOf(engine, 'from-gmail'));
      expect(ticked(tester, rowOf(engine, 'from-gmail')), isFalse);
      expect(
          find.descendant(
              of: rowOf(engine, 'from-gmail'),
              matching: find.text('You organised it, from ron@gmail.example')),
          findsOneWidget);
      await scrollTo(tester, rowOf(engine, 'standup-19'));
      expect(
          find.descendant(
              of: rowOf(engine, 'standup-19'),
              matching:
                  find.text('One of a series: only this one is declined')),
          findsOneWidget);
      for (final id in ['q4', 'own-sync-19', 'spin-19']) {
        await scrollTo(tester, rowOf(engine, id));
        expect(ticked(tester, rowOf(engine, id)), isFalse, reason: id);
      }
      for (final out in ['declined', 'called-off', 'dentist', 'boss']) {
        expect(find.byKey(ValueKey('away:${idOf(engine, out)}:$out')),
            findsNothing,
            reason: out);
      }
      expect(button(tester), 'Block on 2 calendars, decline 6');
      expect(engine.calendarActions, isEmpty);
    });

    testWidgets('the button follows the ticks', (tester) async {
      final (_, engine) = await pump(tester);
      final hadcoId = idOf(engine, 'design');
      final gmailId = idOf(engine, 'webinar');
      await tester.tap(find.byKey(ValueKey('away-block:$gmailId')));
      await tester.pump();
      expect(button(tester), 'Block the days, decline 6');
      await tester.tap(find.byKey(ValueKey('away-block:$hadcoId')));
      await scrollTo(tester, rowOf(engine, 'q4'));
      await tester.tap(rowOf(engine, 'q4'));
      await tester.pump();
      expect(button(tester), 'Decline 6, cancel 1');
      await scrollTo(tester, rowOf(engine, 'design'));
      await tester.tap(rowOf(engine, 'design'));
      await tester.pump();
      expect(button(tester), 'Decline 5, cancel 1');
      expect(engine.calendarActions, isEmpty);
      expect(engine.meetings, isEmpty);
    });

    testWidgets('pressed, it asks once more in words; Go back sends nothing',
        (tester) async {
      final (_, engine) = await pump(tester);
      await scrollTo(tester, rowOf(engine, 'q4'));
      await tester.tap(rowOf(engine, 'q4'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('away-go')));
      await tester.pumpAndSettle();
      expect(find.text('Go ahead?'), findsOneWidget);
      expect(find.text('Wed 18 Nov – Fri 20 Nov blocked as out of office on '
          'Hadco and Gmail.'), findsOneWidget);
      expect(find.text('6 meetings declined. Their organisers are told.'),
          findsOneWidget);
      expect(find.text('1 meeting of your own cancelled. Everyone on it is '
          'told.'), findsOneWidget);
      expect(find.text('An answer or a cancellation cannot be taken back.'),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('away-go-back')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, isEmpty);
      expect(engine.meetings, isEmpty);
    });

    testWidgets('pressed, exactly what is ticked goes, once each, one '
        'meeting of a series and never the series, on each account',
        (tester) async {
      final (c, engine) = await pump(tester);
      final refreshed = c.read(calendarRefreshProvider);
      await scrollTo(tester, rowOf(engine, 'spin-19'));
      await tester.tap(rowOf(engine, 'spin-19'));
      await scrollTo(tester, rowOf(engine, 'dinner'));
      await tester.tap(rowOf(engine, 'dinner'));
      await scrollTo(tester, find.byKey(const ValueKey('away-note')));
      await tester.enterText(
          find.byKey(const ValueKey('away-note')), 'Back on Monday.');
      await tester.pump();
      expect(button(tester), 'Block on 2 calendars, decline 5, cancel 1');
      await press(tester);

      expect(engine.calendarActions, [
        'respond standup-18 declined note=Back on Monday.',
        'respond design declined note=Back on Monday.',
        'respond standup-19 declined note=Back on Monday.',
        'respond webinar declined note=Back on Monday.',
        'respond standup-20 declined note=Back on Monday.',
        'cancel spin-19 note=Back on Monday.',
      ]);
      expect(engine.meetings, hasLength(2));
      for (final m in engine.meetings) {
        expect(m.title, 'Out of office');
        expect(m.allDay, isTrue);
        expect(m.start, wed);
        expect(m.end, fri);
        expect(m.showAs, EventShowAs.outOfOffice);
        expect(m.attendees, isEmpty);
        expect(m.timeZone, 'Asia/Jerusalem');
      }
      expect({for (final m in engine.meetings) m.accountId},
          {idOf(engine, 'design'), idOf(engine, 'webinar')});
      expect(c.read(calendarRefreshProvider).isAfter(refreshed), isTrue,
          reason: 'the views and reminders read again');
      expect(find.byKey(const ValueKey('away-summary')), findsOneWidget);
      expect(find.text('Done: 8 went.'), findsOneWidget);
      expect(button(tester), 'Close');

      // Nothing more goes, however often it is pressed.
      engine.calendarActions.clear();
      await tester.tap(find.byKey(const ValueKey('away-go')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, isEmpty);
      expect(engine.meetings, hasLength(2));
      expect(find.byType(AwayScreen), findsNothing);
    });

    testWidgets('the organisers not told: declined without a word',
        (tester) async {
      final (_, engine) = await pump(tester);
      await scrollTo(tester, find.byKey(const ValueKey('away-tell')));
      await tester.tap(find.byKey(const ValueKey('away-tell')));
      await tester.pump();
      expect(find.text('Declined without a word to them'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('away-note')), 'Away');
      await tester.tap(find.byKey(const ValueKey('away-go')));
      await tester.pumpAndSettle();
      expect(find.text('6 meetings declined, without a word to their '
          'organisers.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('away-go-sure')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions,
          everyElement(allOf(endsWith('declined quietly'),
              isNot(contains('note=')))));
      expect(engine.calendarActions, hasLength(6));
    });

    testWidgets('one fails half way: the screen says which went and which '
        'did not, and pressing again answers only it, once', (tester) async {
      final engine = _Engine()..refuse.add('webinar');
      await pump(tester, with_: engine);
      await press(tester);
      expect(engine.calendarActions, hasLength(5));
      expect(engine.calendarActions,
          isNot(contains(startsWith('respond webinar'))));
      expect(find.text('7 went, 1 did not (marked in red). Those that went '
          'are not sent again. Pressing again does only the 1, each once it '
          'is found still on its calendar as it was.'), findsOneWidget);
      expect(button(tester), 'Try again: decline 1');
      await scrollTo(tester, rowOf(engine, 'webinar'));
      expect(
          find.descendant(
              of: rowOf(engine, 'webinar'),
              matching: find.text('Did not go: Exchange said no.')),
          findsOneWidget);
      expect(ticked(tester, rowOf(engine, 'webinar')), isTrue);
      await scrollTo(tester, rowOf(engine, 'design'));
      expect(
          find.descendant(
              of: rowOf(engine, 'design'), matching: find.text('Declined')),
          findsOneWidget);
      expect(
          find.descendant(
              of: rowOf(engine, 'design'), matching: find.byType(Checkbox)),
          findsNothing,
          reason: 'done: nothing to tick again');

      engine
        ..refuse.clear()
        ..calendarActions.clear();
      final made = engine.meetings.length;
      await press(tester);
      expect(engine.calendarActions, ['respond webinar declined']);
      expect(engine.meetings, hasLength(made), reason: 'no second block');
      expect(find.text('Done: 8 went.'), findsOneWidget);
    });

    testWidgets('pressed twice at once, it goes once', (tester) async {
      final (_, engine) = await pump(tester);
      await scrollTo(tester, find.byKey(const ValueKey('away-go')));
      await tester.tap(find.byKey(const ValueKey('away-go')));
      await tester.tap(find.byKey(const ValueKey('away-go')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('away-go-sure')));
      await tester.tap(find.byKey(const ValueKey('away-go')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(engine.calendarActions, hasLength(6));
      expect(engine.meetings, hasLength(2));
    });

    testWidgets('while it sends, Back waits for it', (tester) async {
      final engine = _Engine()..hold = Completer<void>();
      await pump(tester, with_: engine);
      await tester.tap(find.byKey(const ValueKey('away-go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('away-go-sure')));
      // Spinning while it waits: pumped, not settled.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AwayScreen), findsOneWidget);
      expect(find.text('Wait until it is done: each one is being sent.'),
          findsOneWidget);
      expect(button(tester), startsWith('Sending: '));
      engine.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Done: 8 went.'), findsOneWidget);
    });

    testWidgets('a screen reader hears each row as one: its tick, what it is, '
        'and how it went', (tester) async {
      final semantics = tester.ensureSemantics();
      final (_, engine) = await pump(tester);
      await scrollTo(tester, rowOf(engine, 'design'));
      final row = tester
          .getSemantics(find.descendant(
              of: rowOf(engine, 'design'), matching: find.byType(Checkbox)))
          .getSemanticsData();
      expect(row.label, contains('Design review'));
      expect(row.label, contains('Dana Levi'));
      expect(row.flagsCollection.isChecked, CheckedState.isTrue);
      expect(row.hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    });

    testWidgets('Automatic replies is a tap away, on its own screen',
        (tester) async {
      final (_, engine) = await pump(tester);
      await scrollTo(tester, find.byKey(const ValueKey('away-auto-replies')));
      await tester.tap(find.byKey(const ValueKey('away-auto-replies')));
      await tester.pumpAndSettle();
      expect(find.byType(AutoRepliesScreen), findsOneWidget);
      expect(engine.calendarActions, isEmpty);
    });

    testWidgets('a calendar already out of office for the days starts '
        'unticked and says so', (tester) async {
      final (_, engine) = await pump(tester,
          prepare: (engine, hadco, _) => engine.events[hadco]!.add(
                CalendarEvent(
                  id: 'vacation',
                  accountId: hadco,
                  title: 'Vacation',
                  start: wed,
                  end: DateTime(2026, 11, 21),
                  allDay: true,
                  showAs: EventShowAs.outOfOffice,
                ),
              ));
      final hadcoId = idOf(engine, 'design');
      final row = find.byKey(ValueKey('away-block:$hadcoId'));
      expect(ticked(tester, row), isFalse);
      expect(
          find.descendant(
              of: row, matching: find.text('Out of office already: Vacation')),
          findsOneWidget);
    });

    testWidgets("a calendar that cannot be read says so, and its meetings "
        'are not listed', (tester) async {
      final (_, engine) = await pump(tester,
          prepare: (engine, _, gmail) => engine.calendarRefusals[gmail] =
              const ConnectionFailed('No connection.'));
      final gmailId = idOf(engine, 'webinar');
      expect(rowOf(engine, 'webinar'), findsNothing);
      expect(find.byKey(ValueKey('away-unread:$gmailId')), findsOneWidget);
      expect(ticked(tester, find.byKey(ValueKey('away-block:$gmailId'))),
          isFalse);
      expect(button(tester), 'Block the days, decline 4',
          reason: "Hadco's four: Gmail's two are not listed");
    });

    testWidgets('no calendar, no I am away in the menu', (tester) async {
      await pump(tester, home: const CalendarScreen(), withCalendar: false);
      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-away')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-refresh')), findsOneWidget);
    });

    for (final (size, scale, use24h) in [
      (const Size(360, 780), 1.3, false),
      (const Size(412, 915), 1.0, true),
      (const Size(1493, 934), 0.9, true),
    ]) {
      testWidgets('${size.width.round()} wide, text at $scale, '
          '${use24h ? 24 : 12}-hour clock, a 48 high system bar: the button '
          'whole and above the bar, a Hebrew title from the right',
          (tester) async {
        final (_, engine) = await pump(tester,
            prepare: (engine, _, gmail) => engine.events[gmail]!.add(invited(
                gmail, 'hebrew', at(19, 9, 30),
                organizer: tom, me: ronG, title: 'פגישה עם רואה החשבון')),
            size: size,
            scale: scale,
            use24h: use24h,
            bottomBar: 48);
        expect(tester.takeException(), isNull);
        final go = tester.getRect(find.byKey(const ValueKey('away-go')));
        expect(go.bottom, lessThanOrEqualTo(size.height - 48));
        final words = tester.renderObject<RenderParagraph>(find.descendant(
            of: find.byKey(const ValueKey('away-go')),
            matching: find.byType(RichText)));
        expect(words.didExceedMaxLines, isFalse);
        await scrollTo(tester, rowOf(engine, 'hebrew'));
        final hebrew = tester.widget<Text>(find.text('פגישה עם רואה החשבון'));
        expect(hebrew.textDirection, TextDirection.rtl);
        await scrollTo(tester, rowOf(engine, 'design'));
        expect(
            find.descendant(
                of: rowOf(engine, 'design'),
                matching: find.text(use24h
                    ? 'Wed 18 Nov, 11:00–12:00 · Dana Levi'
                    : 'Wed 18 Nov, 11:00 AM–12:00 PM · Dana Levi')),
            findsOneWidget);
        // Scrolled to its end, the last of it comes above the button.
        final list = tester
            .state<ScrollableState>(find
                .descendant(
                    of: find.byKey(const ValueKey('away-list')),
                    matching: find.byType(Scrollable))
                .first)
            .position;
        for (var i = 0; i < 5; i++) {
          list.jumpTo(list.maxScrollExtent);
          await tester.pumpAndSettle();
        }
        final last = tester.getRect(
            find.byKey(const ValueKey('away-auto-replies')));
        expect(last.bottom, lessThanOrEqualTo(go.top));
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// [screen], opened over a first one as the calendar opens it, so that
/// leaving it has somewhere to go.
class _Opens extends StatefulWidget {
  const _Opens(this.screen);

  final Widget screen;

  @override
  State<_Opens> createState() => _OpensState();
}

class _OpensState extends State<_Opens> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => widget.screen));
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

CalendarEvent _busy(CalendarEvent e) => CalendarEvent(
      id: '${e.id}-busy',
      accountId: e.accountId,
      title: e.title,
      start: e.start,
      end: e.end,
      allDay: e.allDay,
    );

/// The sample engine, with meetings that will not be answered ([refuse]),
/// are gone ([gone]), or are answered with the answer lost on the way back
/// ([loseAnswer]), and a decline Exchange takes off the calendar
/// ([takesDeclinedOff]); and how often a calendar is read.
class _Engine extends SampleMailEngine {
  final Set<String> refuse = {};
  final Set<String> gone = {};
  final Set<String> loseAnswer = {};
  bool takesDeclinedOff = false;
  bool loseBlock = false;
  int reads = 0;

  /// Each answer waits for this, where a test holds them.
  Completer<void>? hold;

  @override
  Future<List<CalendarEvent>> calendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  ) {
    reads++;
    return super.calendarEvents(accountId, start, end);
  }

  @override
  Future<void> respondToEvent(
    CalendarEvent event,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
    bool wholeSeries = false,
  }) async {
    await hold?.future;
    if (refuse.contains(event.id)) {
      throw const CalendarRefused('Exchange said no.');
    }
    if (gone.contains(event.id)) throw const EventGone();
    await super.respondToEvent(event, response,
        note: note, send: send, proposal: proposal, wholeSeries: wholeSeries);
    if (takesDeclinedOff) {
      events[event.accountId]!.removeWhere((e) => e.id == event.id);
    }
    if (loseAnswer.contains(event.id)) {
      throw const ConnectionFailed('The answer did not come back.');
    }
  }

  @override
  Future<void> cancelEvent(
    CalendarEvent event, {
    String note = '',
    bool wholeSeries = false,
  }) async {
    await hold?.future;
    if (refuse.contains(event.id)) {
      throw const CalendarRefused('Exchange said no.');
    }
    await super.cancelEvent(event, note: note, wholeSeries: wholeSeries);
    if (loseAnswer.contains(event.id)) {
      throw const ConnectionFailed('The answer did not come back.');
    }
  }

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    final made = await super.createMeeting(meeting);
    if (loseBlock) {
      throw const ConnectionFailed('The answer did not come back.');
    }
    return made;
  }
}

/// An engine whose calendar calls go to [AccountCalendar] on the wire, as
/// the app's own engine sends them.
class _WireEngine extends SampleMailEngine {
  _WireEngine(this._calendar, this._accounts);

  final AccountCalendar _calendar;
  final List<Account> _accounts;

  Account _of(String id) => _accounts.firstWhere((a) => a.id == id);

  @override
  Future<void> respondToEvent(
    CalendarEvent event,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
    bool wholeSeries = false,
  }) =>
      _calendar.respondToEvent(_of(event.accountId), event, response,
          note: note, send: send, proposal: proposal, wholeSeries: wholeSeries);

  @override
  Future<void> cancelEvent(
    CalendarEvent event, {
    String note = '',
    bool wholeSeries = false,
  }) =>
      _calendar.cancelEvent(_of(event.accountId), event,
          note: note, wholeSeries: wholeSeries);

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) =>
      _calendar.createMeeting(_of(meeting.accountId), meeting);
}
