import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/calendar/phone_calendar_sync.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/mail_engine.dart' show ConnectionFailed;
import 'package:myemail/domain/draft.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/ui/compose/compose_screen.dart' show ComposeScreen;
import 'package:myemail/ui/meetings/new_meeting_screen.dart'
    show NewMeetingScreen;

import 'fakes/fake_webview.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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
      expect(digestOf(''), 'cbf29ce484222325');
      expect(digestOf('foobar'), '85944171f73967e8');
      expect(digestOf('Réunion – 9:00'), '97e9d7e645d295a6',
          reason: 'by its UTF-8 bytes, as before');
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

    PhoneCalendarSync syncWith(DateTime Function() clock) => PhoneCalendarSync(
          engine: engine,
          phone: phone,
          uiState: MemoryUiStateStore(),
          clock: clock,
        );

    test("a Microsoft account's events go in, and only what changed is "
        'written again', () async {
      final sync = syncWith(() => now);
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

    group('read again', () {
      // A morning, so no pass below crosses midnight, which reads it all.
      // The sample engine keeps its reads as made by the same clock.
      final at = DateTime(2026, 11, 16, 9);
      final today = DateTime(at.year, at.month, at.day);
      var clock = at;
      CalendarEvent on(String id, int day, {String title = 'Review'}) => event(
            id,
            DateTime(today.year, today.month, today.day + day, 9),
            DateTime(today.year, today.month, today.day + day, 10),
            title: title,
            accountId: hadco.id,
          );
      String titleOf(String id) =>
          phone.eventsOf[hadco.id]![id]!['title'] as String;

      setUp(() {
        clock = at;
        engine.calendarClock = () => clock;
      });

      test('the next four weeks every pass, the months after them every six '
          'hours', () async {
        final sync = syncWith(() => clock);
        engine.events[hadco.id] = [on('soon', 2), on('later', 100)];
        await sync.run(accounts, {hadco.id});
        expect(phone.eventsOf[hadco.id]!.keys,
            unorderedEquals(['soon', 'later']));

        engine.events[hadco.id] = [
          on('soon', 2, title: 'Soon, renamed'),
          on('later', 100, title: 'Later, renamed'),
        ];
        clock = at.add(const Duration(minutes: 30));
        await sync.run(accounts, {hadco.id});
        expect(titleOf('soon'), 'Soon, renamed');
        expect(titleOf('later'), 'Review',
            reason: 'as kept from the last read, and not taken out');

        clock = at.add(const Duration(hours: 6, minutes: 1));
        await sync.run(accounts, {hadco.id});
        expect(titleOf('later'), 'Later, renamed');
      });

      test('a meeting moved past the next four weeks is read where it went',
          () async {
        final sync = syncWith(() => clock);
        engine.events[hadco.id] = [on('soon', 2), on('later', 100)];
        await sync.run(accounts, {hadco.id});

        engine.events[hadco.id] = [on('soon', 60), on('later', 100)];
        clock = at.add(const Duration(minutes: 30));
        await sync.run(accounts, {hadco.id});
        expect(phone.eventsOf[hadco.id]!['soon']?['start'],
            on('soon', 60).start.millisecondsSinceEpoch,
            reason: 'gone from the next weeks, so the rest is read too');
      });

      test('a meeting moved after another read of its days is still not '
          'lost', () async {
        final sync = syncWith(() => clock);
        engine.events[hadco.id] = [on('soon', 1), on('later', 100)];
        await sync.run(accounts, {hadco.id});

        // Both moved further out; the reminders read the next three days,
        // and the calendar screen the month 'later' was in, before the
        // phone's next pass. Neither read sees where they went.
        engine.events[hadco.id] = [on('soon', 42), on('later', 200)];
        clock = at.add(const Duration(minutes: 10));
        await engine.calendarEvents(
            hadco.id, today, DateTime(today.year, today.month, today.day + 3));
        await engine.calendarEvents(
            hadco.id,
            DateTime(today.year, today.month, today.day + 90),
            DateTime(today.year, today.month, today.day + 120));
        clock = at.add(const Duration(minutes: 30));
        await sync.run(accounts, {hadco.id});
        int? startOf(String id) =>
            phone.eventsOf[hadco.id]![id]?['start'] as int?;
        expect(startOf('soon'), on('soon', 42).start.millisecondsSinceEpoch);
        expect(startOf('later'), on('later', 200).start.millisecondsSinceEpoch);
      });
    });

    test('switched off, its calendar is taken out; a Gmail one never goes in',
        () async {
      final sync = syncWith(() => now);
      await sync.run(accounts, {hadco.id, 'acct-personal'});
      expect(phone.made.keys, [hadco.id]);
      await sync.run(accounts, {});
      expect(phone.made, isEmpty);
    });

    test('without the permission, or the calendar, it says so', () async {
      phone.allowed = false;
      final sync = syncWith(() => now);
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

    test('brought up to date by the worker, not again by the app at once',
        () async {
      // Each keeps its own copy of the settings, and the app's, kept alive
      // by push, did not have the time the worker wrote.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      Future<UiStateStore> copy() async => PrefsUiStateStore(
            await SharedPreferencesWithCache.create(
              cacheOptions: const SharedPreferencesWithCacheOptions(),
            ),
          );
      final app = await copy();
      await app.writeIds(UiStateKeys.phoneCalendars, {hadco.id});
      final worker = await copy();
      await syncPhoneCalendarsIfDue(engine, worker,
          phone: phone, clock: () => now);
      expect(phone.eventsOf[hadco.id], hasLength(2));
      phone.eventsOf.clear();

      await syncPhoneCalendarsIfDue(engine, app,
          phone: phone, clock: () => now.add(const Duration(minutes: 10)));
      expect(phone.eventsOf, isEmpty, reason: 'too soon');
    });
  });

  group('on screen', () {
    Future<(ProviderContainer, Account)> pump(
      WidgetTester tester,
      Widget home, {
      FakePhoneCalendar? phone,
      void Function(SampleMailEngine engine, Account hadco)? prepare,
      Size size = const Size(1000, 1400),
      SampleMailEngine? using,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = using ?? SampleMailEngine();
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
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
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

    testWidgets('all-day events fold to a line, the first and how many more',
        (tester) async {
      final t = today();
      const titles = ['Holiday', 'Birthday', 'Office day'];
      final (c, _) = await pump(tester, const CalendarScreen(),
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          for (final title in titles)
            CalendarEvent(
              id: title,
              accountId: hadco.id,
              title: title,
              start: DateTime(t.year, t.month, t.day),
              end: DateTime(t.year, t.month, t.day + 1),
              allDay: true,
            ),
        ];
      });
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      int shown() =>
          titles.where((x) => find.text(x).evaluate().isNotEmpty).length;
      expect(shown(), 3, reason: 'open, as they always were');

      await tester.tap(find.byKey(const ValueKey('all-day-fold')));
      await tester.pumpAndSettle();
      expect(c.read(calendarAllDayFoldedProvider), isTrue);
      expect(shown(), 1);
      expect(find.text('+2'), findsOneWidget);

      // The count opens them all again.
      await tester.tap(find.byKey(
          ValueKey('all-day-more:${t.year}-${t.month}-${t.day}')));
      await tester.pumpAndSettle();
      expect(c.read(calendarAllDayFoldedProvider), isFalse);
      expect(shown(), 3);
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

    testWidgets('scrolling near the end of the agenda asks for the next 30 '
        'days, and no more until they have come (#141)', (tester) async {
      final t = today();
      final engine = _HeldCalendarEngine();
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (_, hadco) {
        engine.shown.addAll([
          for (var i = 0; i < 20; i++)
            at(hadco, 'm$i', 'Meeting $i',
                DateTime(t.year, t.month, t.day + i, 10)),
        ]);
      });
      final next = DateTime(t.year, t.month, t.day + 30);
      expect(engine.asked, isNot(contains(next)));

      // The next 30 days answer only when let go, as on a slow connection,
      // and have nothing on meanwhile, so the end stays near.
      engine.hold = true;
      final list = find.byType(CustomScrollView);
      Future<void> scroll(List<double> steps) async {
        final drag = await tester.startGesture(tester.getCenter(list));
        for (final dy in steps) {
          await drag.moveBy(Offset(0, dy));
          await tester.pump();
        }
        await drag.up();
        await tester.pump(const Duration(milliseconds: 100));
      }

      Set<DateTime> asked() => {
            for (final d in engine.asked)
              if (d.isAfter(t)) d,
          };
      await scroll(List.filled(15, -40));
      expect(asked(), {next});

      // Once they have come, the 30 days after, as the end is still near.
      for (final answer in engine.held) {
        answer.complete();
      }
      await tester.pump();
      await scroll([...List.filled(3, 40.0), ...List.filled(3, -40.0)]);
      expect(asked(), {next, DateTime(t.year, t.month, t.day + 60)});
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

    // --- acting on a meeting (batch 2) ---------------------------------------

    const dana = MailAddress(email: 'dana@hadco.example', name: 'Dana Levi');
    const yossi = MailAddress(email: 'yossi@hadco.example', name: 'Yossi');
    const ron = MailAddress(email: 'ron@hadco.example');

    /// A meeting tomorrow at ten: Dana's, inviting the account, or with
    /// [own] the account's, with Yossi on it (or nobody, with [alone]).
    CalendarEvent tomorrowAt10(
      Account hadco, {
      String id = 'm',
      bool own = false,
      bool alone = false,
      List<EventAttendee>? people,
      String? seriesId,
    }) {
      final t = today();
      return CalendarEvent(
        id: id,
        accountId: hadco.id,
        seriesId: seriesId,
        title: own ? (alone ? 'Dentist' : 'Planning') : 'Budget',
        start: DateTime(t.year, t.month, t.day + 1, 10),
        end: DateTime(t.year, t.month, t.day + 1, 11),
        organizer: own ? null : dana,
        isOrganizer: own,
        response: own ? EventResponse.organizer : EventResponse.notResponded,
        attendees: people ??
            (alone
                ? const []
                : own
                    ? const [EventAttendee(yossi, response: EventResponse.accepted)]
                    : const [
                        EventAttendee(dana, response: EventResponse.organizer),
                        EventAttendee(ron, response: EventResponse.notResponded),
                      ]),
      );
    }

    Future<void> openSheet(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(ValueKey('agenda-event:$id')));
      await tester.pumpAndSettle();
    }

    testWidgets('an invitation is answered from its sheet, each answer asking '
        'first how it goes, as Outlook does (#12)', (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [tomorrowAt10(hadco)];
      });
      Future<void> answer(String button, String how) async {
        await openSheet(tester, 'm');
        await tester.tap(find.byKey(ValueKey(button)));
        await tester.pumpAndSettle();
        expect(find.text('Send the response now'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey(how)));
        await tester.pumpAndSettle();
      }

      await answer('event-accept', 'answer-now');
      expect(engine.calendarActions, ['respond m accepted']);
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);

      await openSheet(tester, 'm');
      expect(
        tester.widget(find.byKey(const ValueKey('event-accept'))),
        isA<FilledButton>(),
        reason: 'the answer it has stands out',
      );
      Navigator.of(tester.element(find.byKey(const ValueKey('event-accept'))))
          .pop();
      await tester.pumpAndSettle();

      await answer('event-tentative', 'answer-quiet');
      expect(engine.calendarActions.last, 'respond m tentative quietly',
          reason: 'on the calendar, with no word to the organiser');
      expect(find.text('Tentative. The organiser was not told.'),
          findsOneWidget);

      // Last: declined, it leaves the agenda.
      await answer('event-decline', 'answer-edit');
      await tester.enterText(
          find.byKey(const ValueKey('answer-note')), 'Away that week');
      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.last,
          'respond m declined note=Away that week');
    });

    testWidgets('Edit opens the meeting filled in, and Save sends what changed '
        '(#13)', (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [tomorrowAt10(hadco, own: true)];
      });
      await openSheet(tester, 'm');
      await tester.tap(find.byKey(const ValueKey('event-edit')));
      await tester.pumpAndSettle();
      expect(find.text('Edit meeting'), findsOneWidget);
      expect(find.text('Planning'), findsOneWidget, reason: 'the title');

      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('meeting-title')),
            matching: find.byType(TextField),
          ),
          'Planning, week 44');
      await tester.tap(find.byKey(const ValueKey('meeting-send')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['update m title=Planning, week 44']);
      expect(find.textContaining('Saved. Everyone on it is sent the change'),
          findsOneWidget);
    });

    testWidgets('a meeting of yours is cancelled with a note, and an '
        'appointment deleted with Undo (#14)', (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          tomorrowAt10(hadco, own: true),
          tomorrowAt10(hadco, id: 'a1', own: true, alone: true),
        ];
      });
      await openSheet(tester, 'm');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      expect(find.text('Cancel meeting'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('cancel-note')), 'Moved to Monday');
      await tester.tap(find.byKey(const ValueKey('cancel-go')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['cancel m note=Moved to Monday']);

      // The appointment: gone at once, back with Undo, and nothing asked of
      // the calendar.
      await openSheet(tester, 'a1');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('delete-undo')));
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsOneWidget);
      expect(engine.calendarActions, hasLength(1));

      // Again, and left: deleted once Undo has gone.
      await openSheet(tester, 'a1');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      // The message's time runs from when it is fully in; then it goes, and
      // the calendar is asked.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.last, 'remove a1');
      expect(find.text('Dentist'), findsNothing);
    });

    testWidgets('cancelling every meeting of a series says the past ones go '
        'too', (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          tomorrowAt10(hadco, own: true, seriesId: 'weekly'),
        ];
      });
      await openSheet(tester, 'm');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('series-all')),
          matching: find.textContaining('past ones too'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('series-one')),
          matching: find.textContaining('past'),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('series-all')));
      await tester.pumpAndSettle();
      expect(find.textContaining("from everyone's calendar, past ones too"),
          findsOneWidget,
          reason: 'said again just before it goes');
      await tester.tap(find.byKey(const ValueKey('cancel-go')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single, startsWith('cancel m'));
      expect(engine.calendarActions.single, contains('series'));
    });

    testWidgets('someone else\'s meeting is declined and taken off (#14)',
        (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [tomorrowAt10(hadco)];
      });
      await openSheet(tester, 'm');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cancel-note')), findsNothing,
          reason: 'no note to the organiser when declining this way');
      await tester.tap(find.byKey(const ValueKey('cancel-go')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['remove m declined']);
    });

    testWidgets('a meeting of yours dragged an hour later moves there (#15)',
        (tester) async {
      final engine = SampleMailEngine();
      final (c, _) = await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          tomorrowAt10(hadco, id: 'a1', own: true, alone: true),
        ];
      });
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-next')));
      await tester.pumpAndSettle();
      final block = find.byKey(const ValueKey('calendar-event:a1'));
      final hour = c.read(calendarHourHeightProvider);
      final grip = tester.getTopLeft(block) + const Offset(10, 8);
      final drag = await tester.startGesture(grip);
      await tester.pump(const Duration(milliseconds: 700));
      await drag.moveBy(Offset(0, hour / 2));
      await tester.pump();
      await drag.moveBy(Offset(0, hour / 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('calendar-drag-ghost')), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['update a1 start=11:00 end=12:00']);
    });

    testWidgets('Email everyone, and those who have not answered (#16, #35)',
        (tester) async {
      FakeWebViewPlatform.install();
      final t = today();
      await pump(tester, const CalendarScreen(), prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          CalendarEvent(
            id: 'm',
            accountId: hadco.id,
            title: 'Planning',
            start: DateTime(t.year, t.month, t.day + 1, 10),
            end: DateTime(t.year, t.month, t.day + 1, 11),
            isOrganizer: true,
            response: EventResponse.organizer,
            attendees: const [
              EventAttendee(yossi, response: EventResponse.accepted),
              EventAttendee(dana, response: EventResponse.notResponded),
              EventAttendee(MailAddress(email: 'ori@hadco.example'),
                  response: EventResponse.declined),
            ],
          ),
        ];
      });
      await openSheet(tester, 'm');
      expect(find.text('1 accepted · 1 declined · 1 not answered'),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-nudge')));
      await tester.pumpAndSettle();
      final compose = tester.widget<ComposeScreen>(find.byType(ComposeScreen));
      expect([for (final a in compose.draft.to) a.email], ['dana@hadco.example']);
      expect(compose.draft.subject, 'Planning');
    });

    testWidgets('Running late tells the organiser, and Invite and Duplicate '
        'go where they should (#17, #18, #19)', (tester) async {
      final engine = _SendingEngine();
      final t = DateTime.now();
      final soon = DateTime(t.year, t.month, t.day, t.hour, t.minute)
          .add(const Duration(minutes: 20));
      await pump(tester, const CalendarScreen(), using: engine,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          CalendarEvent(
            id: 'm',
            accountId: hadco.id,
            title: 'Budget',
            start: soon,
            end: soon.add(const Duration(hours: 1)),
            organizer: dana,
            response: EventResponse.accepted,
            attendees: const [EventAttendee(dana, response: EventResponse.organizer)],
          ),
          tomorrowAt10(hadco, id: 'p', own: true),
        ];
      });
      await openSheet(tester, 'm');
      await tester.tap(find.byKey(const ValueKey('event-late')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('late-10')));
      await tester.pumpAndSettle();
      expect(engine.drafts.single.to, [dana]);
      expect(engine.drafts.single.subject, 'Running late: Budget');
      expect(engine.drafts.single.htmlBody, contains('about 10 minutes late'));
      expect(find.text('Told Dana you are running 10 minutes late.'),
          findsOneWidget);

      await openSheet(tester, 'p');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-invite')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('invite-addresses')), 'ori@hadco.example');
      await tester.tap(find.byKey(const ValueKey('invite-go')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.last,
          'update p attendees=yossi@hadco.example,ori@hadco.example',
          reason: 'everyone, as Exchange wants the list; only Ori is new');

      await openSheet(tester, 'p');
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-duplicate')));
      await tester.pumpAndSettle();
      expect(find.text('New meeting'), findsOneWidget);
      expect(find.text('Planning'), findsOneWidget);
    });

    testWidgets('a second time zone down the side of Day, set in Settings '
        '(#24)', (tester) async {
      final (c, _) = await pump(tester, const CalendarSettingsScreen(),
          phone: FakePhoneCalendar());
      await tester.tap(find.byKey(const ValueKey('calendar-second-zone')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('zone-search')), 'Tokyo');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('zone:Asia/Tokyo')));
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).secondZone, 'Asia/Tokyo');

      await tester.tap(find.byKey(const ValueKey('calendar-dates-in-mail')));
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).datesInMail, isFalse);
    });

    testWidgets('the Day view shows the second zone\'s hours beside its own',
        (tester) async {
      final (c, _) = await pump(tester, const CalendarScreen());
      c
          .read(calendarPrefsProvider.notifier)
          .set(const CalendarPrefs(secondZone: 'Asia/Tokyo'));
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('second-zone-name')), findsOneWidget);
      expect(find.text('Tokyo'), findsOneWidget);
      expect(find.byKey(const ValueKey('second-zone-hour:9')), findsOneWidget);
    });

    testWidgets('a meeting written in UTC, as a calendar from a link writes '
        'it, is drawn at its hour here (#131)', (tester) async {
      final day = DateTime(2026, 11, 16);
      DateTime at(int h, [int m = 0]) =>
          DateTime(day.year, day.month, day.day, h, m);
      final (c, _) = await pump(tester, CalendarScreen(day: day),
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          CalendarEvent(
            id: 'first',
            accountId: hadco.id,
            title: 'first',
            start: at(0),
            end: at(0, 30),
          ),
          // A Google calendar's link writes a single event's times in UTC,
          // and the feed keeps them so.
          CalendarEvent(
            id: 'match',
            accountId: hadco.id,
            title: 'Match',
            start: at(10).toUtc(),
            end: at(11).toUtc(),
          ),
        ];
      });
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      double top(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('calendar-event:$id'))).dy;
      expect(top('match') - top('first'),
          10 * c.read(calendarHourHeightProvider),
          reason: 'on the line marked 10:00');
    });

    testWidgets('a meeting held and let go where it was is not moved, '
        'seconds and all (#131)', (tester) async {
      final day = DateTime(2026, 11, 16);
      final engine = SampleMailEngine();
      final (c, _) = await pump(tester, CalendarScreen(day: day),
          using: engine, prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          CalendarEvent(
            id: 'a1',
            accountId: hadco.id,
            title: 'Dentist',
            start: DateTime(day.year, day.month, day.day, 9, 0, 30),
            end: DateTime(day.year, day.month, day.day, 10, 0, 30),
            isOrganizer: true,
            response: EventResponse.organizer,
          ),
        ];
      });
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      final block = find.byKey(const ValueKey('calendar-event:a1'));
      for (final grip in [0.15, 0.9]) {
        final hour = c.read(calendarHourHeightProvider);
        final drag = await tester
            .startGesture(tester.getTopLeft(block) + Offset(10, grip * hour));
        await tester.pump(const Duration(milliseconds: 700));
        await drag.moveBy(const Offset(0, 3));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
      }
      expect(engine.calendarActions, isEmpty,
          reason: 'neither a move nor a stretch of less than a quarter hour');
    });

    // The next days the clocks change where the tests run. A zone without
    // summer time has none, and these are skipped there.
    for (final (name, change) in [
      ('go forward', _clockChange(shorter: true)),
      ('go back', _clockChange(shorter: false)),
    ]) {
      DateTime at(int h, [int m = 0]) =>
          DateTime(change!.year, change.month, change.day, h, m);

      testWidgets('on the day the clocks $name, Day draws a meeting at its '
          'hour, and a tap on an hour starts a meeting there (#131)',
          skip: change == null, (tester) async {
        final (c, _) = await pump(tester, CalendarScreen(day: change),
            prepare: (engine, hadco) {
          engine.events[hadco.id] = [
            for (final (id, from, to) in [
              ('first', at(0), at(0, 30)),
              ('late', at(22), at(23)),
            ])
              CalendarEvent(
                id: id,
                accountId: hadco.id,
                title: id,
                start: from,
                end: to,
              ),
          ];
        });
        await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
        await tester.pumpAndSettle();
        final hour = c.read(calendarHourHeightProvider);
        final first = find.byKey(const ValueKey('calendar-event:first'));
        final midnight = tester.getTopLeft(first).dy;
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('calendar-event:late')))
                  .dy -
              midnight,
          22 * hour,
          reason: 'on the line marked 22:00, not an hour off it',
        );

        await tester.tapAt(
            Offset(tester.getCenter(first).dx, midnight + 14 * hour + 5));
        await tester.pumpAndSettle();
        expect(
          tester.widget<NewMeetingScreen>(find.byType(NewMeetingScreen)).start,
          at(14),
        );
      });

      /// What a meeting of Ron's from midnight to one, held at [grip] of an
      /// hour's height from its top, and moved down [hours], is sent as.
      Future<List<String>> dragged(
        WidgetTester tester, {
        required double grip,
        required int hours,
      }) async {
        final engine = SampleMailEngine();
        final (c, _) = await pump(tester, CalendarScreen(day: change),
            using: engine, prepare: (engine, hadco) {
          engine.events[hadco.id] = [
            CalendarEvent(
              id: 'a1',
              accountId: hadco.id,
              title: 'Dentist',
              start: at(0),
              end: at(1),
              isOrganizer: true,
              response: EventResponse.organizer,
            ),
          ];
        });
        await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
        await tester.pumpAndSettle();
        // Up to midnight, where the meeting is.
        await tester.drag(
            find.byType(SingleChildScrollView), const Offset(0, 600));
        await tester.pumpAndSettle();
        final block = find.byKey(const ValueKey('calendar-event:a1'));
        final hour = c.read(calendarHourHeightProvider);
        final drag = await tester
            .startGesture(tester.getTopLeft(block) + Offset(10, grip * hour));
        await tester.pump(const Duration(milliseconds: 700));
        for (var i = 0; i < hours; i++) {
          await drag.moveBy(Offset(0, hour));
          await tester.pump();
        }
        await drag.up();
        await tester.pumpAndSettle();
        return engine.calendarActions;
      }

      testWidgets('on the day the clocks $name, a meeting dragged past 2 a.m. '
          'lands on the hour it was dropped on (#131)', skip: change == null,
          (tester) async {
        expect(await dragged(tester, grip: 0.15, hours: 4),
            ['update a1 start=04:00 end=05:00']);
      });

      testWidgets('on the day the clocks $name, a meeting stretched past 2 '
          'a.m. ends on the hour it was let go on (#131)',
          skip: change == null, (tester) async {
        expect(await dragged(tester, grip: 0.9, hours: 3),
            ['update a1 start=00:00 end=04:00'],
            reason: 'held by its foot');
      });
    }
  });
}

/// The next day, within a year and a bit, whose clocks go forward (a
/// 23-hour day) or back (25), or null where the clocks never change.
DateTime? _clockChange({required bool shorter}) {
  final now = DateTime.now();
  for (var i = 1; i < 400; i++) {
    final day = DateTime(now.year, now.month, now.day + i);
    final hours =
        DateTime(day.year, day.month, day.day + 1).difference(day).inHours;
    if (hours == (shorter ? 23 : 25)) return day;
  }
  return null;
}

/// The sample engine, keeping what it was asked to send.
class _SendingEngine extends SampleMailEngine {
  final List<Draft> drafts = [];

  @override
  Future<void> sendDraft(Draft draft) async => drafts.add(draft);
}

/// The sample engine with calendars holding only [shown], keeping the
/// first day of each stretch asked for, and while [hold], answering only
/// once what is [held] is let go.
class _HeldCalendarEngine extends SampleMailEngine {
  final List<CalendarEvent> shown = [];
  final List<DateTime> asked = [];
  final List<Completer<void>> held = [];
  bool hold = false;

  @override
  Future<List<CalendarEvent>> calendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  ) async {
    asked.add(start);
    if (hold) {
      final answer = Completer<void>();
      held.add(answer);
      await answer.future;
    }
    return [
      for (final e in shown)
        if (e.accountId == accountId &&
            e.start.isBefore(end) &&
            e.end.isAfter(start))
          e,
    ];
  }
}
