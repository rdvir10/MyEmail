import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart' show SignInNeedsConsent;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/internet_calendars.dart';
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/account_calendars.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/internet_calendar.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';

import 'fakes/fake_webview.dart';

/// Every calendar in each account (#25), on screen: Calendars shown, a
/// calendar that is only read, New meeting's Calendar, and calendars from
/// links in Settings (#28).
void main() {
  late MemoryUiStateStore ui;
  late MemoryInternetCalendars links;

  setUp(() {
    ui = MemoryUiStateStore();
    links = MemoryInternetCalendars();
    FakeWebViewPlatform.install();
  });

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<(ProviderContainer, SampleMailEngine, Account)> pump(
    WidgetTester tester,
    Widget Function(Account hadco) home, {
    Future<void> Function(SampleMailEngine engine, Account hadco)? prepare,
    MailProvider provider = MailProvider.outlook,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = SampleMailEngine();
    final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
          displayName: 'Hadco',
          emailAddress: 'ron@hadco.example',
          provider: provider,
          token: OAuthToken(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.utc(2030),
          ),
        )))!;
    if (prepare != null) await tester.runAsync(() => prepare(engine, hadco));
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      phoneCalendarProvider.overrideWithValue(FakePhoneCalendar()),
      internetCalendarReaderProvider.overrideWithValue(links),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: home(hadco),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (c, engine, hadco);
  }

  CalendarEvent meeting(
    Account hadco,
    String id,
    String title, {
    String calendarId = CalendarEvent.mainCalendar,
    bool readOnly = false,
    int hour = 10,
  }) {
    final t = today();
    return CalendarEvent(
      id: id,
      accountId: hadco.id,
      calendarId: calendarId,
      title: title,
      start: DateTime(t.year, t.month, t.day, hour),
      end: DateTime(t.year, t.month, t.day, hour + 1),
      organizer: const MailAddress(email: 'dana@example.com'),
      response: EventResponse.notResponded,
      readOnly: readOnly,
    );
  }

  Future<void> twoCalendars(SampleMailEngine engine, Account hadco) async {
    engine.calendarLists[hadco.id] = [
      CalendarInfo.main(hadco.id),
      CalendarInfo(
          accountId: hadco.id, id: 'BBB', name: 'Projects', colour: 0xFFE3008C),
    ];
    engine.events[hadco.id] = [
      meeting(hadco, 'm', 'Weekly sync'),
      meeting(hadco, 'p', 'Site walk', calendarId: 'BBB', hour: 14),
    ];
    // Listed once, as the calendar does as it reads them.
    await engine.calendarsOf(hadco.id);
  }

  testWidgets("Calendars shown lists an account's calendars, each switched "
      'on or off', (tester) async {
    await ui.writeString(UiStateKeys.calendarView, 'agenda');
    final (_, _, hadco) =
        await pump(tester, (_) => const CalendarScreen(), prepare: twoCalendars);
    expect(find.text('Site walk'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calendar-accounts')));
    await tester.pumpAndSettle();
    final projects = find.byKey(ValueKey('calendar-shown:${hadco.id}|BBB'));
    expect(projects, findsOneWidget);
    await tester.tap(projects);
    await tester.pumpAndSettle();
    expect(ui.readIds(UiStateKeys.hiddenCalendars), {'${hadco.id}|BBB'});
    Navigator.of(tester.element(projects)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Site walk'), findsNothing);
    expect(find.text('Weekly sync'), findsOneWidget);
  });

  testWidgets("a Google account signed in before the list was asked for "
      'offers Allow', (tester) async {
    // A calendar from a link, so there is a choice to make.
    await ui.writeString(
      UiStateKeys.internetCalendars,
      InternetCalendar.listToText(const [
        InternetCalendar(
          id: 'il',
          name: 'Holidays in Israel',
          url: 'https://example.com/il.ics',
          colour: 0xFF0B8043,
        ),
      ]),
    );
    links.feeds['https://example.com/il.ics'] =
        'BEGIN:VCALENDAR\r\nEND:VCALENDAR';
    final (_, _, google) = await pump(tester, (_) => const CalendarScreen(),
        provider: MailProvider.gmail, prepare: (engine, hadco) async {
      engine.events[hadco.id] = [meeting(hadco, 'm', 'Weekly sync')];
      engine.calendarListRefusals[hadco.id] =
          const SignInNeedsConsent('Sign in again.');
    });
    await tester.tap(find.byKey(const ValueKey('calendar-accounts')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('calendar-list-allow:${google.id}')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-shown:internet:il')),
        findsOneWidget);
  });

  testWidgets('a meeting on a calendar that is only read offers no answers',
      (tester) async {
    await ui.writeString(UiStateKeys.calendarView, 'agenda');
    await pump(tester, (_) => const CalendarScreen(),
        prepare: (engine, hadco) async {
      engine.events[hadco.id] = [
        meeting(hadco, 'h', 'Holiday', readOnly: true),
        meeting(hadco, 'm', 'Weekly sync', hour: 14),
      ];
    });
    await tester.tap(find.byKey(const ValueKey('agenda-event:h')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-accept')), findsNothing);
    expect(find.byKey(const ValueKey('event-more')), findsNothing);
    Navigator.of(tester.element(find.text('Holiday').last)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-accept')), findsOneWidget,
        reason: 'one on a calendar of its own still answers');
  });

  testWidgets('New meeting asks which calendar when there is a choice',
      (tester) async {
    final (_, engine, _) = await pump(
        tester, (hadco) => NewMeetingScreen(accountId: hadco.id),
        prepare: twoCalendars);
    await tester.tap(find.byKey(const ValueKey('meeting-calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('meeting-calendar:BBB')).last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('meeting-title')),
          matching: find.byType(TextField),
          matchRoot: true,
        ),
        'On Projects');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(engine.meetings.single.calendarId, 'BBB');
  });

  group('Settings, Calendar, calendars from links', () {
    const ics = 'BEGIN:VCALENDAR\r\nX-WR-CALNAME:Team fixtures\r\n'
        'BEGIN:VEVENT\r\nUID:g1\r\nSUMMARY:Match\r\n'
        'DTSTART:20261028T170000Z\r\nEND:VEVENT\r\nEND:VCALENDAR';

    testWidgets('one added from a link, named as it names itself',
        (tester) async {
      links.feeds['https://example.com/team.ics'] = ics;
      final (c, _, _) = await pump(tester, (_) => const CalendarSettingsScreen());
      final add = find.byKey(const ValueKey('internet-calendar-add'));
      await tester.scrollUntilVisible(add, 200);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('internet-calendar-link')), 'nonsense');
      await tester.tap(find.byKey(const ValueKey('internet-calendar-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('internet-calendar-problem')),
          findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('internet-calendar-link')),
          'webcal://example.com/team.ics');
      await tester.tap(find.byKey(const ValueKey('internet-calendar-save')));
      await tester.pumpAndSettle();
      final added = c.read(internetCalendarsProvider).single;
      expect(added.name, 'Team fixtures');
      expect(added.url, 'https://example.com/team.ics');
      expect(find.text('Team fixtures'), findsOneWidget);

      await tester.tap(
          find.byKey(ValueKey('internet-calendar-remove:${added.id}')));
      await tester.pumpAndSettle();
      expect(c.read(internetCalendarsProvider), isEmpty);
    });

    testWidgets("a country's public holidays", (tester) async {
      final (c, _, _) = await pump(tester, (_) => const CalendarSettingsScreen());
      final holidays = find.byKey(const ValueKey('internet-calendar-holidays'));
      await tester.scrollUntilVisible(holidays, 200);
      await tester.tap(holidays);
      await tester.pumpAndSettle();
      final israel = find.byKey(const ValueKey('holidays:en.jewish'));
      await tester.scrollUntilVisible(israel, 200,
          scrollable: find.descendant(
              of: find.byType(SimpleDialog),
              matching: find.byType(Scrollable)));
      await tester.tap(israel);
      await tester.pumpAndSettle();
      final added = c.read(internetCalendarsProvider).single;
      expect(added.name, 'Holidays in Israel');
      expect(added.url, holidayFeedUrl('en.jewish'));
    });
  });
}
