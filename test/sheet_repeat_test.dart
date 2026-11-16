import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart' show ConnectionFailed;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting_repeat.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show showEventDetails;
import 'package:myemail/ui/calendar/meeting_facts.dart';

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// The sheet says how a meeting repeats, and the rest of what its calendar
/// keeps of it: its reminder, how it shows, private, its categories
/// (calendar idea #44). Quietly, under the time; nothing for what it has
/// none of, and nothing rather than something wrong.
void main() {
  group('how a series repeats, as Microsoft keeps it', () {
    MeetingRepeat? graph(Map<String, Object?> pattern,
            [Map<String, Object?> range = const {'type': 'noEnd'}]) =>
        MeetingRepeat.fromGraph({'pattern': pattern, 'range': range});
    String? said(Map<String, Object?> pattern,
            [Map<String, Object?> range = const {'type': 'noEnd'}]) =>
        graph(pattern, range)?.describe();

    test('a week, its days, and until when', () {
      expect(
        said(
          {
            'type': 'weekly',
            'interval': 1,
            'daysOfWeek': ['tuesday'],
            'firstDayOfWeek': 'sunday',
          },
          {
            'type': 'endDate',
            'startDate': '2026-10-06',
            'endDate': '2027-06-30',
          },
        ),
        'Every week on Tuesday, until 30 June 2027',
      );
      expect(
        said({
          'type': 'weekly',
          'interval': 2,
          'daysOfWeek': ['wednesday', 'sunday'],
        }),
        'Every 2 weeks on Sunday and Wednesday',
        reason: "in the order of Ron's week, which starts on Sunday",
      );
      expect(
        said({
          'type': 'weekly',
          'interval': 1,
          'daysOfWeek': [
            'monday', 'tuesday', 'wednesday', 'thursday', 'friday',
          ],
        }),
        'Every week, Monday to Friday',
      );
      expect(
        said({
          'type': 'weekly',
          'interval': 1,
          'daysOfWeek': ['sunday', 'monday', 'tuesday', 'wednesday',
            'thursday'],
        }, {'type': 'numbered', 'numberOfOccurrences': 20}),
        'Every week, Sunday to Thursday, 20 times',
      );
    });

    test('a day, a month, a year', () {
      expect(said({'type': 'daily', 'interval': 1}), 'Every day');
      expect(
          said({'type': 'daily', 'interval': 2},
              {'type': 'numbered', 'numberOfOccurrences': 10}),
          'Every 2 days, 10 times');
      expect(said({'type': 'absoluteMonthly', 'interval': 1, 'dayOfMonth': 15}),
          'Every month on day 15');
      expect(
          said({
            'type': 'relativeMonthly',
            'interval': 1,
            'daysOfWeek': ['friday'],
            'index': 'last',
          }),
          'Every month on the last Friday');
      expect(
          said({
            'type': 'relativeMonthly',
            'interval': 3,
            'daysOfWeek': ['monday'],
            'index': 'second',
          }),
          'Every 3 months on the second Monday');
      expect(
          said({
            'type': 'absoluteYearly',
            'interval': 1,
            'dayOfMonth': 3,
            'month': 3,
          }),
          'Every year on 3 March');
      expect(
          said({
            'type': 'relativeYearly',
            'interval': 1,
            'daysOfWeek': ['monday'],
            'index': 'first',
            'month': 9,
          }),
          'Every year on the first Monday of September');
    });

    test('what it cannot say exactly, it does not say at all', () {
      expect(
          graph({
            'type': 'relativeMonthly',
            'interval': 1,
            'daysOfWeek': ['monday', 'tuesday'],
            'index': 'first',
          }),
          isNull,
          reason: 'the first of either day: not one this can name');
      expect(graph({'type': 'weekly', 'interval': 1, 'daysOfWeek': []}),
          isNull);
      expect(
          graph({'type': 'weekly', 'interval': 1, 'daysOfWeek': ['funday']}),
          isNull);
      expect(graph({'type': 'hourly', 'interval': 1}), isNull);
      expect(graph({'type': 'absoluteMonthly', 'interval': 1}), isNull);
      expect(MeetingRepeat.fromGraph(null), isNull);
      expect(MeetingRepeat.fromGraph('weekly'), isNull);
      expect(MeetingRepeat.fromGraph({'pattern': 'weekly'}), isNull);
      expect(
          graph({'type': 'daily', 'interval': 1},
              {'type': 'endDate', 'endDate': 'soon'}),
          isNull,
          reason: 'an end it cannot read is not left out as though none');
    });
  });

  group('how a series repeats, as Google keeps it', () {
    String? said(List<Object?> lines, {DateTime? start}) =>
        MeetingRepeat.fromRule(lines, start: start)?.describe();

    test('its rule, read', () {
      // Noon in UTC is 30 June wherever the tests run.
      expect(said(['RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20270630T120000Z']),
          'Every week on Tuesday, until 30 June 2027');
      expect(said(['RRULE:FREQ=WEEKLY;UNTIL=20270630;BYDAY=TU']),
          'Every week on Tuesday, until 30 June 2027');
      expect(said(['RRULE:FREQ=DAILY;COUNT=5']), 'Every day, 5 times');
      expect(said(['RRULE:FREQ=DAILY;INTERVAL=3']), 'Every 3 days');
      expect(said(['RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR']),
          'Every week, Monday to Friday');
      expect(said(['RRULE:FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=TH,TU']),
          'Every 2 weeks on Tuesday and Thursday');
      expect(said(['RRULE:FREQ=MONTHLY;BYDAY=-1FR']),
          'Every month on the last Friday');
      expect(said(['RRULE:FREQ=MONTHLY;BYDAY=+2TU']),
          'Every month on the second Tuesday');
      expect(said(['RRULE:FREQ=MONTHLY;BYMONTHDAY=15']),
          'Every month on day 15');
      expect(said(['RRULE:FREQ=YEARLY;BYMONTH=9;BYDAY=1MO']),
          'Every year on the first Monday of September');
      expect(said(['rrule:freq=weekly;byday=tu']), 'Every week on Tuesday',
          reason: 'in any case of letters');
    });

    test("what the rule leaves to the series' first day is taken from it",
        () {
      final tuesday = DateTime(2026, 10, 6);
      expect(said(['RRULE:FREQ=WEEKLY'], start: tuesday),
          'Every week on Tuesday');
      expect(said(['RRULE:FREQ=MONTHLY'], start: tuesday),
          'Every month on day 6');
      expect(said(['RRULE:FREQ=YEARLY'], start: DateTime(2026, 3, 3)),
          'Every year on 3 March');
      expect(said(['RRULE:FREQ=WEEKLY']), isNull,
          reason: 'with no first day, there is no day to say');
    });

    test('days left out of a series do not change how it repeats', () {
      expect(
          said([
            'EXDATE;TZID=Asia/Jerusalem:20261020T140000',
            'RRULE:FREQ=WEEKLY;BYDAY=TU',
          ]),
          'Every week on Tuesday');
    });

    test('what it cannot say exactly, it does not say at all', () {
      for (final rule in [
        'RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
        'RRULE:FREQ=HOURLY',
        'RRULE:FREQ=MONTHLY;BYDAY=MO',
        'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1',
        'RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15',
        'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=0',
        'RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=soon',
        'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=3;UNTIL=20270630',
        'RRULE:FREQ=DAILY;BYDAY=MO',
        'RRULE:BYDAY=TU',
        'RRULE:',
        'nonsense',
      ]) {
        expect(said([rule]), isNull, reason: rule);
      }
      expect(
          said(['RRULE:FREQ=WEEKLY;BYDAY=TU', 'RRULE:FREQ=WEEKLY;BYDAY=TH']),
          isNull,
          reason: 'two rules at once');
      expect(said(['RRULE:FREQ=WEEKLY;BYDAY=TU', 'RDATE:20261111']), isNull,
          reason: 'with days added, the rule is not the whole of it');
      expect(said(const []), isNull);
    });

    test("from the series as Google gives it: its rule, and its first day "
        'in its own zone', () {
      final repeat = MeetingRepeat.fromGoogle({
        'id': 's1',
        'recurrence': ['RRULE:FREQ=WEEKLY'],
        // Late on a Tuesday in Jerusalem, which is Wednesday in UTC.
        'start': {
          'dateTime': '2026-10-06T23:30:00+03:00',
          'timeZone': 'Asia/Jerusalem',
        },
      });
      expect(repeat?.describe(), 'Every week on Tuesday');
      expect(
          MeetingRepeat.fromGoogle({
            'recurrence': ['RRULE:FREQ=YEARLY'],
            'start': {'date': '2026-03-03'},
          })?.describe(),
          'Every year on 3 March');
      expect(MeetingRepeat.fromGoogle({'id': 'x'}), isNull);
    });
  });

  group("the rest of what a meeting's calendar keeps of it", () {
    test('its reminder, in plain words', () {
      expect(reminderSaid(0), 'Reminder at the start');
      expect(reminderSaid(1), 'Reminder 1 minute before');
      expect(reminderSaid(15), 'Reminder 15 minutes before');
      expect(reminderSaid(60), 'Reminder 1 hour before');
      expect(reminderSaid(90), 'Reminder 90 minutes before');
      expect(reminderSaid(120), 'Reminder 2 hours before');
      expect(reminderSaid(1080), 'Reminder 18 hours before');
      expect(reminderSaid(1440), 'Reminder 1 day before');
      expect(reminderSaid(2880), 'Reminder 2 days before');
      expect(reminderSaid(10080), 'Reminder 1 week before');
    });

    CalendarEvent meeting({
      int? reminder = 15,
      EventShowAs showAs = EventShowAs.busy,
      bool private = false,
      List<String> categories = const [],
      EventResponse response = EventResponse.accepted,
      bool cancelled = false,
    }) =>
        CalendarEvent(
          id: 'm',
          accountId: 'a',
          title: 'Weekly sync',
          start: DateTime(2026, 11, 17, 10),
          end: DateTime(2026, 11, 17, 11),
          reminderMinutes: reminder,
          showAs: showAs,
          isPrivate: private,
          categories: categories,
          response: response,
          cancelled: cancelled,
        );

    test('in one line: the reminder, how it shows, private, its categories',
        () {
      expect(
        meetingFacts(
            meeting(private: true, categories: ['Sales', 'קבוצה'])),
        'Reminder 15 minutes before · Busy · Private · Sales · קבוצה',
      );
      expect(meetingFacts(meeting(reminder: null)), 'Busy',
          reason: 'no reminder, nothing said of one');
      expect(meetingFacts(meeting(showAs: EventShowAs.outOfOffice)),
          'Reminder 15 minutes before · Out of office');
      expect(meetingFacts(meeting(showAs: EventShowAs.free, reminder: 0)),
          'Reminder at the start · Free');
    });

    test('Google keeps only free or busy: a meeting answered maybe is busy '
        'there', () {
      expect(
          meetingFacts(meeting(showAs: EventShowAs.tentative),
              freeOrBusy: true),
          'Reminder 15 minutes before · Busy');
      expect(meetingFacts(meeting(showAs: EventShowAs.free), freeOrBusy: true),
          'Reminder 15 minutes before · Free');
      expect(meetingFacts(meeting(showAs: EventShowAs.tentative)),
          'Reminder 15 minutes before · Tentative',
          reason: "Outlook's own tentative is said");
    });

    test('a meeting declined or cancelled takes no time: how it would show '
        'is not said', () {
      expect(meetingFacts(meeting(response: EventResponse.declined)),
          'Reminder 15 minutes before');
      expect(meetingFacts(meeting(cancelled: true, reminder: null)), '');
    });
  });

  group('on the wire', () {
    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status,
            headers: {'content-type': 'application/json'});
    late List<http.Request> sent;
    http_testing.MockClient client(http.Response Function(http.Request) a) {
      sent = [];
      return http_testing.MockClient((r) async {
        sent.add(r);
        return a(r);
      });
    }

    test("Microsoft: the series' own recurrence, and nothing else of it",
        () async {
      final api = GraphCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: client((_) => json({
              'id': 's/1',
              'recurrence': {
                'pattern': {
                  'type': 'weekly',
                  'interval': 1,
                  'daysOfWeek': ['tuesday'],
                },
                'range': {'type': 'noEnd', 'startDate': '2026-10-06'},
              },
            })),
        sleep: (_) async {},
      );
      final repeat = await api.seriesRepeat('s/1');
      expect(repeat?.describe(), 'Every week on Tuesday');
      expect(sent.single.method, 'GET');
      expect(sent.single.url.path, '/v1.0/me/events/s%2F1');
      expect(sent.single.url.queryParameters[r'$select'], 'recurrence');
    });

    test('Microsoft: a series gone is nothing to say', () async {
      final api = GraphCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: client(
            (_) => json({'error': {'code': 'ErrorItemNotFound'}}, 404)),
        sleep: (_) async {},
      );
      expect(await api.seriesRepeat('s1'), isNull);
    });

    test('Google: the series on the calendar the meeting is on', () async {
      final api = GoogleCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: client((_) => json({
              'id': 's1',
              'status': 'confirmed',
              'recurrence': ['RRULE:FREQ=MONTHLY;BYDAY=-1FR'],
              'start': {'dateTime': '2026-10-30T09:00:00+02:00'},
            })),
        sleep: (_) async {},
      );
      expect((await api.seriesRepeat('s1'))?.describe(),
          'Every month on the last Friday');
      expect(sent.single.url.path, '/calendar/v3/calendars/primary/events/s1');
      await api.seriesRepeat('s1', calendarId: 'family#1@group.calendar');
      expect(sent.last.url.path,
          '/calendar/v3/calendars/family%231%40group.calendar/events/s1');
    });

    test('through the account: the series of the meeting; a meeting on its '
        'own asks nothing', () async {
      const microsoft = Account(
        id: 'a',
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      );
      final calendar = AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async =>
            'token',
        accounts: () => const [microsoft],
        httpClient: client((_) => json({
              'recurrence': {
                'pattern': {'type': 'daily', 'interval': 1},
              },
            })),
        sleep: (_) async {},
      );
      CalendarEvent one({String? seriesId}) => CalendarEvent(
            id: 'occurrence-4',
            accountId: 'a',
            title: 'Stand-up',
            start: DateTime(2026, 11, 17, 9, 30),
            end: DateTime(2026, 11, 17, 9, 45),
            seriesId: seriesId,
          );
      expect(await calendar.meetingRepeat(microsoft, one()), isNull);
      expect(sent, isEmpty);
      expect(
          (await calendar.meetingRepeat(microsoft, one(seriesId: 'series-1')))
              ?.describe(),
          'Every day');
      expect(sent.single.url.path, endsWith('/events/series-1'));
    });
  });

  group("on the meeting's sheet", () {
    setUpAll(() async {
      FakeWebViewPlatform.install();
      await loadRoboto();
    });

    // Tuesday 17 November 2026, as the pictures have it.
    DateTime at(int hour, [int minute = 0, int days = 0]) =>
        DateTime(2026, 11, 17 + days, hour, minute);
    const dana =
        MailAddress(email: 'dana.levi@hadco.example', name: 'Dana Levi');
    const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');

    late SampleMailEngine engine;

    CalendarEvent sync(
      Account a, {
      String? seriesId = 'series-1',
      int? reminder = 15,
      EventShowAs showAs = EventShowAs.busy,
      bool private = false,
      List<String> categories = const [],
      EventResponse response = EventResponse.accepted,
      String title = 'Weekly sync',
    }) =>
        CalendarEvent(
          id: 'm',
          accountId: a.id,
          title: title,
          start: at(14, 0, 7),
          end: at(15, 0, 7),
          location: 'Room 4',
          organizer: dana,
          attendees: [
            const EventAttendee(dana, response: EventResponse.organizer),
            EventAttendee(ron, response: response),
          ],
          response: response,
          seriesId: seriesId,
          reminderMinutes: reminder,
          showAs: showAs,
          isPrivate: private,
          categories: categories,
        );

    Future<void> pump(
      WidgetTester tester,
      CalendarEvent Function(Account a) event, {
      Size size = const Size(412, 915),
      double scale = 1.0,
      MailProvider provider = MailProvider.outlook,
      void Function(SampleMailEngine engine)? before,
      bool unreachable = false,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      engine = SampleMailEngine();
      before?.call(engine);
      final account = (await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Hadco',
            emailAddress: provider == MailProvider.gmail
                ? 'ron@gmail.example'
                : 'ron@hadco.example',
            provider: provider,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          )))!;
      if (unreachable) {
        engine.calendarRefusals[account.id] =
            const ConnectionFailed('No signal');
      }
      final shown = event(account);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
        meetingClockProvider.overrideWithValue(() => at(9)),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  key: const ValueKey('open-sheet'),
                  onPressed: () =>
                      showEventDetails(context, ref, shown, account),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-sheet')));
      await tester.pumpAndSettle();
    }

    String? textOf(WidgetTester tester, String key) {
      final found = find.byKey(ValueKey(key));
      if (found.evaluate().isEmpty) return null;
      return tester.widget<Text>(found).data;
    }

    /// Whether [p] shows all of its words, on as many lines as it needs:
    /// none cut short, and as tall as its lines are at its width.
    bool whole(RenderParagraph p) =>
        !p.didExceedMaxLines &&
        p.size.height + 0.5 >= p.getMaxIntrinsicHeight(p.size.width);

    RenderParagraph paragraphOf(WidgetTester tester, String key) =>
        tester.renderObject<RenderParagraph>(find
            .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(RichText),
                matchRoot: true)
            .first);

    testWidgets('under the time: how it repeats, then its reminder, how it '
        'shows, private and its categories, quieter than the time, and '
        'before the place', (tester) async {
      await pump(
        tester,
        (a) => sync(a, private: true, categories: ['Sales']),
        before: (engine) => engine.repeats['series-1'] =
            MeetingRepeat.fromRule(
                const ['RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20270630T120000Z'])!,
      );
      expect(textOf(tester, 'event-repeat'),
          'Every week on Tuesday, until 30 June 2027');
      expect(textOf(tester, 'event-facts'),
          'Reminder 15 minutes before · Busy · Private · Sales');

      final when = tester.getRect(find.byKey(const ValueKey('event-when')));
      final repeat = tester.getRect(find.byKey(const ValueKey('event-repeat')));
      final facts = tester.getRect(find.byKey(const ValueKey('event-facts')));
      final place = tester.getRect(find.text('Room 4'));
      expect(repeat.top, greaterThanOrEqualTo(when.bottom));
      expect(facts.top, greaterThanOrEqualTo(repeat.bottom));
      expect(place.top, greaterThanOrEqualTo(facts.bottom));
      expect(repeat.left, when.left, reason: 'lined up with the time');

      // Quiet: the colour the sheet's other quiet lines have.
      final theme =
          Theme.of(tester.element(find.byKey(const ValueKey('event-when'))));
      for (final key in ['event-repeat', 'event-facts']) {
        expect(tester.widget<Text>(find.byKey(ValueKey(key))).style?.color,
            theme.colorScheme.onSurfaceVariant,
            reason: key);
      }
    });

    testWidgets('a series not known yet, or that cannot be said, is said to '
        'repeat and no more', (tester) async {
      await pump(tester, (a) => sync(a));
      expect(textOf(tester, 'event-repeat'), 'Repeats');
    });

    testWidgets("a series whose calendar cannot be reached just now: it "
        'repeats, and the sheet is as it was', (tester) async {
      await pump(tester, (a) => sync(a),
          unreachable: true,
          before: (engine) => engine.repeats['series-1'] =
              MeetingRepeat.fromRule(const ['RRULE:FREQ=DAILY'])!);
      expect(textOf(tester, 'event-repeat'), 'Repeats');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('event-accept')), findsOneWidget);
    });

    testWidgets('a meeting on its own says nothing of repeating; one with no '
        'reminder says none', (tester) async {
      await pump(tester, (a) => sync(a, seriesId: null, reminder: null));
      expect(find.byKey(const ValueKey('event-repeat')), findsNothing);
      expect(find.textContaining('Repeats'), findsNothing);
      expect(textOf(tester, 'event-facts'), 'Busy');
      expect(find.textContaining('Reminder'), findsNothing);
    });

    testWidgets('on a Google calendar, a meeting answered maybe shows as '
        'busy, as Google keeps it', (tester) async {
      await pump(
          tester,
          (a) => sync(a,
              seriesId: null,
              showAs: EventShowAs.tentative,
              response: EventResponse.tentative),
          provider: MailProvider.gmail);
      expect(textOf(tester, 'event-facts'),
          'Reminder 15 minutes before · Busy');
    });

    testWidgets('the rest of the sheet is as it was: the time, the place, the '
        'account and the answer, in that order', (tester) async {
      await pump(tester, (a) => sync(a));
      final when = tester.getRect(find.byKey(const ValueKey('event-when')));
      final place = tester.getRect(find.text('Room 4'));
      // The account's line, before Ron's own among the people.
      final account = tester.getRect(find.text('ron@hadco.example').first);
      final answer = tester.getRect(find.text('You accepted'));
      expect(when.bottom, lessThanOrEqualTo(place.top));
      expect(place.bottom, lessThanOrEqualTo(account.top));
      expect(account.bottom, lessThanOrEqualTo(answer.top));
      expect(find.byKey(const ValueKey('event-accept')), findsOneWidget);
    });

    for (final (width, scale) in [(360.0, 1.3), (412.0, 1.0)]) {
      testWidgets('at $width wide and text size $scale, every word shows, a '
          'long line on two', (tester) async {
        await pump(
          tester,
          (a) => sync(a,
              private: true,
              categories: ['Sales', 'Plant 2 rollout'],
              title: 'סנכרון שבועי'),
          size: Size(width, 800),
          scale: scale,
          before: (engine) => engine.repeats['series-1'] =
              MeetingRepeat.fromRule(const [
            'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;UNTIL=20270630T120000Z',
          ])!,
        );
        expect(tester.takeException(), isNull);
        for (final key in ['event-repeat', 'event-facts']) {
          expect(whole(paragraphOf(tester, key)), isTrue, reason: key);
        }
      });
    }
  });
}
