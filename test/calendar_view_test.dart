import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/calendar/phone_calendar_sync.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart' show ConnectionFailed;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';

/// The calendar in the app (#50), and Microsoft calendars in the phone's
/// calendar (#51).
void main() {
  CalendarEvent event(
    String id,
    DateTime start,
    DateTime end, {
    bool allDay = false,
    String title = 'Meeting',
    EventResponse response = EventResponse.none,
    bool cancelled = false,
    String accountId = 'a',
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        response: response,
        cancelled: cancelled,
      );

  group('a day', () {
    final day = DateTime(2026, 10, 27);

    test('what falls on it, whole days first, then by when they start', () {
      final events = [
        event('late', DateTime(2026, 10, 27, 15), DateTime(2026, 10, 27, 16)),
        event('early', DateTime(2026, 10, 27, 9), DateTime(2026, 10, 27, 10)),
        event('day', DateTime(2026, 10, 27), DateTime(2026, 10, 28), allDay: true),
        event('before', DateTime(2026, 10, 26, 9), DateTime(2026, 10, 27)),
        event('over', DateTime(2026, 10, 26, 22), DateTime(2026, 10, 27, 2)),
        event('next', DateTime(2026, 10, 28), DateTime(2026, 10, 29), allDay: true),
      ];
      expect([for (final e in eventsOn(day, events)) e.id],
          ['day', 'over', 'early', 'late'],
          reason: 'one that ends as the day starts was the day before');
    });

    test('overlapping meetings side by side, others the full width', () {
      DateTime at(int h, [int m = 0]) => DateTime(2026, 10, 27, h, m);
      final slots = {
        for (final s in layOutDay([
          event('a', at(9), at(10)),
          event('b', at(9, 30), at(11)),
          event('c', at(10), at(10, 30)),
          event('d', at(12), at(13)),
        ]))
          s.event.id: (s.column, s.columns),
      };
      expect(slots['a'], (0, 2));
      expect(slots['b'], (1, 2));
      expect(slots['c'], (0, 2), reason: "a's column is free again at ten");
      expect(slots['d'], (0, 1));
    });
  });

  group('read from the calendars', () {
    test("Graph's events, asked for in UTC, in local time", () {
      final e = GraphCalendarApi.eventFrom({
        'id': 'g1',
        'subject': 'Project review',
        'start': {'dateTime': '2026-10-27T12:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-10-27T13:00:00.0000000', 'timeZone': 'UTC'},
        'isAllDay': false,
        'location': {'displayName': 'Room 2'},
        'organizer': {
          'emailAddress': {'name': 'Dana Levi', 'address': 'dana@hadco.example'},
        },
        'attendees': [
          {
            'type': 'required',
            'status': {'response': 'accepted'},
            'emailAddress': {'name': 'Yossi', 'address': 'yossi@hadco.example'},
          },
          {
            'type': 'resource',
            'status': {'response': 'accepted'},
            'emailAddress': {'name': 'Room 2', 'address': 'room2@hadco.example'},
          },
        ],
        'onlineMeeting': {'joinUrl': 'https://teams.microsoft.com/l/x'},
        'showAs': 'tentative',
        'responseStatus': {'response': 'tentativelyAccepted'},
        'isReminderOn': true,
        'reminderMinutesBeforeStart': 15,
        'bodyPreview': 'Agenda attached',
      }, 'hadco')!;
      expect(e.start, DateTime.utc(2026, 10, 27, 12).toLocal());
      expect(e.end, DateTime.utc(2026, 10, 27, 13).toLocal());
      expect(e.location, 'Room 2');
      expect(e.organizer!.name, 'Dana Levi');
      expect(e.attendees.single.response, EventResponse.accepted,
          reason: 'the room is not a person');
      expect(e.joinUrl, 'https://teams.microsoft.com/l/x');
      expect(e.response, EventResponse.tentative);
      expect(e.showAs, EventShowAs.tentative);
      expect(e.reminderMinutes, 15);
      expect(e.accountId, 'hadco');

      final day = GraphCalendarApi.eventFrom({
        'id': 'g2',
        'subject': 'Holiday',
        'isAllDay': true,
        'start': {'dateTime': '2026-11-02T00:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-11-04T00:00:00.0000000', 'timeZone': 'UTC'},
        'isReminderOn': false,
        'reminderMinutesBeforeStart': 1080,
      }, 'hadco')!;
      expect(day.allDay, isTrue);
      expect(day.start, DateTime(2026, 11, 2), reason: "the phone's midnight");
      expect(day.end, DateTime(2026, 11, 4));
      expect(day.reminderMinutes, isNull, reason: 'the reminder is off');
    });

    test("Google's events, its whole days, and the account's own answer", () {
      final e = GoogleCalendarApi.eventFrom({
        'id': 'e1',
        'summary': 'Lunch',
        'start': {'dateTime': '2026-10-29T12:30:00+02:00'},
        'end': {'dateTime': '2026-10-29T13:30:00+02:00'},
        'organizer': {'email': 'dana@example.com'},
        'attendees': [
          {'email': 'dana@example.com', 'organizer': true, 'responseStatus': 'accepted'},
          {'email': 'me@gmail.example', 'self': true, 'responseStatus': 'needsAction'},
        ],
        'conferenceData': {
          'entryPoints': [
            {'entryPointType': 'phone', 'uri': 'tel:+1'},
            {'entryPointType': 'video', 'uri': 'https://meet.google.com/abc'},
          ],
        },
        'reminders': {
          'useDefault': false,
          'overrides': [
            {'method': 'popup', 'minutes': 10},
            {'method': 'email', 'minutes': 60},
          ],
        },
        'htmlLink': 'https://calendar.google.com/event?eid=x',
      }, 'gmail')!;
      expect(e.start, DateTime.utc(2026, 10, 29, 10, 30).toLocal());
      expect(e.response, EventResponse.notResponded);
      expect(e.attendees.first.response, EventResponse.organizer);
      expect(e.joinUrl, 'https://meet.google.com/abc');
      expect(e.reminderMinutes, 60, reason: 'the earliest warning');

      final day = GoogleCalendarApi.eventFrom({
        'id': 'e2',
        'summary': 'Away',
        'start': {'date': '2026-11-02'},
        'end': {'date': '2026-11-03'},
        'transparency': 'transparent',
      }, 'gmail')!;
      expect(day.allDay, isTrue);
      expect(day.start, DateTime(2026, 11, 2));
      expect(day.showAs, EventShowAs.free);
      expect(
        GoogleCalendarApi.eventFrom({
          'id': 'e3',
          'status': 'cancelled',
          'start': {'date': '2026-11-02'},
          'end': {'date': '2026-11-03'},
        }, 'gmail'),
        isNull,
      );
    });
  });

  group("the phone's calendar", () {
    test('an event as the provider takes it, with a digest of what it says',
        () {
      final day = event('d', DateTime(2026, 11, 2), DateTime(2026, 11, 3),
          allDay: true);
      final row = phoneEventOf(day);
      expect(row['start'], DateTime.utc(2026, 11, 2).millisecondsSinceEpoch,
          reason: 'a whole day is midnight to midnight in UTC');
      expect(row['end'], DateTime.utc(2026, 11, 3).millisecondsSinceEpoch);
      final timed =
          event('t', DateTime(2026, 11, 2, 9), DateTime(2026, 11, 2, 10));
      expect(phoneEventOf(timed)['start'],
          DateTime(2026, 11, 2, 9).millisecondsSinceEpoch);
      expect(phoneEventOf(timed)['digest'], phoneEventOf(timed)['digest']);
      expect(
        phoneEventOf(event('t', DateTime(2026, 11, 2, 9),
            DateTime(2026, 11, 2, 10), title: 'Moved'))['digest'],
        isNot(phoneEventOf(timed)['digest']),
      );
      expect(digestOf('a'), 'af63dc4c8601ec8c', reason: "FNV-1a's own value");
      expect(goesToPhone(timed), isTrue);
      expect(
        goesToPhone(event('x', DateTime(2026), DateTime(2026), cancelled: true)),
        isFalse,
      );
      expect(
        goesToPhone(event('x', DateTime(2026), DateTime(2026),
            response: EventResponse.declined)),
        isFalse,
      );
    });

    late SampleMailEngine engine;
    late FakePhoneCalendar phone;
    late List<Account> accounts;
    late Account hadco;
    final now = DateTime(2026, 10, 24, 10);

    setUp(() async {
      engine = SampleMailEngine();
      phone = FakePhoneCalendar();
      hadco = await engine.addOAuthAccount(
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.utc(2030),
        ),
      );
      engine.events[hadco.id] = [
        event('m1', DateTime(2026, 10, 26, 9), DateTime(2026, 10, 26, 10),
            accountId: hadco.id),
        event('m2', DateTime(2026, 11, 2), DateTime(2026, 11, 3),
            allDay: true, accountId: hadco.id),
        event('gone', DateTime(2026, 10, 27, 9), DateTime(2026, 10, 27, 10),
            cancelled: true, accountId: hadco.id),
      ];
      accounts = await engine.loadAccounts();
    });

    test("a Microsoft account's events go in, and only what changed is "
        'written again', () async {
      final sync =
          PhoneCalendarSync(engine: engine, phone: phone, clock: () => now);
      expect(await sync.run(accounts, {hadco.id}), isEmpty);
      expect(phone.made[hadco.id]!.account, 'ron@hadco.example');
      expect(phone.eventsOf[hadco.id]!.keys, unorderedEquals(['m1', 'm2']),
          reason: 'not the cancelled one');

      engine.events[hadco.id] = [
        event('m1', DateTime(2026, 10, 26, 9), DateTime(2026, 10, 26, 11),
            accountId: hadco.id),
      ];
      expect(await sync.run(accounts, {hadco.id}), isEmpty);
      expect(phone.eventsOf[hadco.id]!.keys, ['m1']);
      expect(phone.eventsOf[hadco.id]!['m1']!['end'],
          DateTime(2026, 10, 26, 11).millisecondsSinceEpoch);
    });

    test('switched off, its calendar is taken out; a Gmail one never goes in',
        () async {
      final sync =
          PhoneCalendarSync(engine: engine, phone: phone, clock: () => now);
      await sync.run(accounts, {hadco.id, 'acct-personal'});
      expect(phone.made.keys, [hadco.id]);
      await sync.run(accounts, {});
      expect(phone.made, isEmpty);
    });

    test('without the permission, or the calendar, it says so', () async {
      phone.allowed = false;
      final sync =
          PhoneCalendarSync(engine: engine, phone: phone, clock: () => now);
      expect((await sync.run(accounts, {hadco.id}))[hadco.id],
          isA<PhoneCalendarNotAllowed>());

      phone.allowed = true;
      engine.calendarRefusals[hadco.id] =
          const SignInNeedsConsent('Allow it first.');
      expect((await sync.run(accounts, {hadco.id}))[hadco.id],
          isA<SignInNeedsConsent>());
      expect(phone.made, isEmpty);
    });

    test('brought up to date at most every half hour', () async {
      final ui = MemoryUiStateStore();
      await ui.writeIds(UiStateKeys.phoneCalendars, {hadco.id});
      var at = now;
      Future<void> pass() =>
          syncPhoneCalendarsIfDue(engine, ui, phone: phone, clock: () => at);
      await pass();
      expect(phone.eventsOf[hadco.id], hasLength(2));
      phone.eventsOf.clear();
      at = now.add(const Duration(minutes: 10));
      await pass();
      expect(phone.eventsOf, isEmpty, reason: 'too soon');
      at = now.add(const Duration(minutes: 31));
      await pass();
      expect(phone.eventsOf[hadco.id], hasLength(2));
    });
  });

  group('on screen', () {
    Future<(ProviderContainer, Account)> pump(
      WidgetTester tester,
      Widget home, {
      FakePhoneCalendar? phone,
      void Function(SampleMailEngine engine, Account hadco)? prepare,
      Size size = const Size(1000, 1400),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = SampleMailEngine();
      final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Hadco',
            emailAddress: 'ron@hadco.example',
            provider: MailProvider.outlook,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          )))!;
      prepare?.call(engine, hadco);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        if (phone != null) phoneCalendarProvider.overrideWithValue(phone),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: home,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (c, hadco);
    }

    DateTime today() {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }

    testWidgets('the agenda lists the days with something on, and an event '
        'opens with Join', (tester) async {
      final t = today();
      await pump(tester, const CalendarScreen(), prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          CalendarEvent(
            id: 'review',
            accountId: hadco.id,
            title: 'Project review',
            start: DateTime(t.year, t.month, t.day + 1, 14),
            end: DateTime(t.year, t.month, t.day + 1, 15),
            joinUrl: 'https://teams.microsoft.com/l/x',
            organizer:
                const MailAddress(email: 'dana@hadco.example', name: 'Dana'),
          ),
        ];
      });

      expect(find.text('Project review'), findsOneWidget);
      expect(find.textContaining('Tomorrow'), findsOneWidget);
      expect(find.text('14:00'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('agenda-event:review')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-join')), findsOneWidget);
      expect(find.text('Dana'), findsOneWidget, reason: 'the organiser');
    });

    testWidgets('Day shows the hours, and Week the days, each a tap from '
        'its day', (tester) async {
      final (c, _) = await pump(tester, const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
      if (today().weekday <= DateTime.friday) {
        expect(find.textContaining('Stand-up'), findsOneWidget,
            reason: "the sample's weekday stand-up");
      }

      await tester.tap(find.byKey(const ValueKey('calendar-view-week')));
      await tester.pumpAndSettle();
      final t = today();
      final dayKey =
          find.byKey(ValueKey('week-day:${t.year}-${t.month}-${t.day}'));
      expect(dayKey, findsOneWidget);
      await tester.tap(dayKey);
      await tester.pumpAndSettle();
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
    });

    testWidgets('a calendar not allowed yet is offered Allow', (tester) async {
      await pump(tester, const CalendarScreen(), prepare: (engine, hadco) {
        engine.calendarRefusals[hadco.id] =
            const SignInNeedsConsent('Allow it first.');
      });
      expect(find.textContaining('Not allowed yet'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
    });

    testWidgets("Settings, Calendar: switched on, Hadco's calendar goes into "
        "the phone's; off, it comes out", (tester) async {
      final phone = FakePhoneCalendar();
      final (c, hadco) =
          await pump(tester, const CalendarSettingsScreen(), phone: phone);
      final row = find.byKey(ValueKey('phone-calendar:${hadco.id}'));
      expect(row, findsOneWidget);
      expect(find.byKey(const ValueKey('phone-calendar:acct-personal')),
          findsNothing, reason: "a Gmail account's is there through Google");

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(c.read(phoneCalendarsProvider), {hadco.id});
      expect(phone.made.keys, [hadco.id]);
      expect(phone.eventsOf[hadco.id], isNotEmpty);
      expect(find.textContaining("in the phone's calendar now"), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(c.read(phoneCalendarsProvider), isEmpty);
      expect(phone.made, isEmpty);
    });

    testWidgets('a refused permission leaves it off, and says where to allow '
        'it', (tester) async {
      final phone = FakePhoneCalendar(allowed: false, grants: false);
      final (c, hadco) =
          await pump(tester, const CalendarSettingsScreen(), phone: phone);
      await tester.tap(find.byKey(ValueKey('phone-calendar:${hadco.id}')));
      await tester.pumpAndSettle();
      expect(c.read(phoneCalendarsProvider), isEmpty);
      expect(find.textContaining('calendar permission'), findsOneWidget);
    });

    CalendarEvent at(
      Account hadco,
      String id,
      String title,
      DateTime start, {
      Duration length = const Duration(hours: 1),
      EventResponse response = EventResponse.none,
    }) =>
        CalendarEvent(
          id: id,
          accountId: hadco.id,
          title: title,
          start: start,
          end: start.add(length),
          response: response,
        );

    String day(DateTime d) => '${d.year}-${d.month}-${d.day}';

    testWidgets('a meeting you declined is left out, and shown struck '
        'through once Show declined meetings is on (#1)', (tester) async {
      final t = today();
      final (c, _) = await pump(tester, const CalendarScreen(),
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          at(hadco, 'no', 'Said no', DateTime(t.year, t.month, t.day + 1, 10),
              response: EventResponse.declined),
          at(hadco, 'yes', 'Going', DateTime(t.year, t.month, t.day + 1, 12),
              response: EventResponse.accepted),
        ];
      });
      expect(find.text('Going'), findsOneWidget);
      expect(find.text('Said no'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-show-declined')));
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).showDeclined, isTrue);
      expect(find.text('Said no'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Said no')).style?.decoration,
          TextDecoration.lineThrough);
      expect(find.text('Declined'), findsOneWidget);
    });

    testWidgets('what was read is shown again when the calendar cannot be '
        'read (#2)', (tester) async {
      final t = today();
      final (c, hadco) = await pump(tester, const CalendarScreen(),
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          at(hadco, 'k', 'Kept meeting',
              DateTime(t.year, t.month, t.day + 1, 10)),
        ];
      });
      expect(find.text('Kept meeting'), findsOneWidget);

      (c.read(mailEngineProvider) as SampleMailEngine)
              .calendarRefusals[hadco.id] =
          const ConnectionFailed('No connection.');
      c.read(calendarRefreshProvider.notifier).now();
      await tester.pumpAndSettle();
      expect(find.text('Kept meeting'), findsOneWidget);
      expect(find.text('No connection.'), findsOneWidget);
    });

    testWidgets('the title opens a month to pick a day from, and the view '
        'goes there (#3)', (tester) async {
      await pump(tester, const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-title')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-next')));
      await tester.pumpAndSettle();

      final t = today();
      final target = DateTime(t.year, t.month + 1, 15);
      await tester.tap(find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byKey(ValueKey('month-day:${day(target)}')),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('day-head:${day(target)}')), findsOneWidget);
    });

    testWidgets('a swipe turns to the next day, and Back to the one before '
        '(#4)', (tester) async {
      await pump(tester, const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      final t = today();
      final tomorrow = DateTime(t.year, t.month, t.day + 1);
      expect(find.byKey(ValueKey('day-head:${day(t)}')), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('day-head:${day(tomorrow)}')), findsOneWidget);
      expect(find.byKey(ValueKey('day-head:${day(t)}')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('calendar-previous')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('day-head:${day(t)}')), findsOneWidget);
    });

    testWidgets('Month on a tablet: titles in the boxes, and a day opens Day '
        '(#5)', (tester) async {
      final t = today();
      final board = DateTime(t.year, t.month, t.day == 10 ? 11 : 10);
      final (c, _) = await pump(tester, const CalendarScreen(),
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          at(hadco, 'board', 'Board',
              DateTime(board.year, board.month, board.day, 10)),
        ];
      });
      await tester.tap(find.byKey(const ValueKey('calendar-view-month')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-event:board')), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('month-day:${day(board)}')));
      await tester.pumpAndSettle();
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
      expect(find.byKey(ValueKey('day-head:${day(board)}')), findsOneWidget);
    });

    testWidgets('Month on a phone: dots, the day picked listed under it, and '
        'a second tap opens it (#5)', (tester) async {
      final t = today();
      final board = DateTime(t.year, t.month, t.day == 10 ? 11 : 10);
      final (c, _) = await pump(tester, const CalendarScreen(),
          size: const Size(400, 800), prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          at(hadco, 'board', 'Board',
              DateTime(board.year, board.month, board.day, 10)),
        ];
      });
      await tester.tap(find.byKey(const ValueKey('calendar-view-month')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-event:board')), findsNothing,
          reason: 'dots on a phone, not titles');

      final cell = find.byKey(ValueKey('month-day:${day(board)}'));
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('Board'), findsOneWidget, reason: 'listed under it');
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
    });

    testWidgets('Week shows the work week alone once chosen (#6)',
        (tester) async {
      final (c, _) = await pump(tester, const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-span:workWeek')));
      await tester.pumpAndSettle();
      expect(c.read(calendarViewProvider), CalendarViewMode.week);
      expect(c.read(calendarWeekSpanProvider), WeekSpan.workWeek);
      final heads = find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('week-day:'));
      expect(heads, findsNWidgets(5), reason: 'Monday to Friday');
      expect(find.text('Work week'), findsOneWidget,
          reason: 'on the view button');
    });

    testWidgets('the agenda goes back before the day it opens at (#7)',
        (tester) async {
      final t = today();
      await pump(tester, const CalendarScreen(), prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          at(hadco, 'past', 'Earlier meeting',
              DateTime(t.year, t.month, t.day - 3, 10)),
          at(hadco, 'soon', 'Later meeting',
              DateTime(t.year, t.month, t.day + 2, 10)),
        ];
      });
      expect(find.text('Later meeting'), findsOneWidget);
      expect(find.text('Earlier meeting'), findsNothing, reason: 'above');

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(find.text('Earlier meeting'), findsOneWidget);
    });

    testWidgets('a pinch makes the hours taller, and the height is kept (#8)',
        (tester) async {
      final (c, _) = await pump(tester, const CalendarScreen());
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      final centre = tester.getCenter(find.byType(SingleChildScrollView));
      final a = await tester.startGesture(centre - const Offset(0, 40),
          pointer: 7);
      final b = await tester.startGesture(centre + const Offset(0, 40),
          pointer: 8);
      await tester.pump();
      await a.moveBy(const Offset(0, -40));
      await b.moveBy(const Offset(0, 40));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(c.read(calendarHourHeightProvider), closeTo(112, 0.5),
          reason: 'the fingers twice as far apart');
    });

    testWidgets('Settings, Calendar: declined meetings, what Week shows, and '
        'the working day', (tester) async {
      final (c, _) = await pump(tester, const CalendarSettingsScreen(),
          phone: FakePhoneCalendar());
      await tester.tap(find.byKey(const ValueKey('calendar-declined-switch')));
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).showDeclined, isTrue);

      await tester.tap(find.byKey(const ValueKey('calendar-week-span')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work week').last);
      await tester.pumpAndSettle();
      expect(c.read(calendarWeekSpanProvider), WeekSpan.workWeek);

      await tester.tap(find.byKey(const ValueKey('calendar-day-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('08:00').last);
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).dayStart, 8);
    });
  });
}
