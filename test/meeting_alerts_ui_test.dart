import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting_alerts.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/meeting_alert_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart' show mailNotifierProvider;
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/my_day_pane.dart';
import 'package:myemail/ui/calendar/next_meeting_bar.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The next meeting over the mail (#9), My Day beside it (#10), the
/// calendar opened from a reminder or the agenda (#31, #33), and their
/// settings.
void main() {
  // A Monday morning, ten minutes before the sync.
  final now = DateTime(2026, 10, 26, 9, 50);
  late MemoryUiStateStore ui;

  setUp(() {
    ui = MemoryUiStateStore();
    FakeWebViewPlatform.install();
  });

  CalendarEvent meeting(
    Account hadco,
    String id,
    DateTime start, {
    String title = 'Weekly sync',
    String? joinUrl = 'https://teams.microsoft.com/l/meetup-join/x',
  }) =>
      CalendarEvent(
        id: id,
        accountId: hadco.id,
        title: title,
        start: start,
        end: start.add(const Duration(minutes: 30)),
        organizer: const MailAddress(email: 'dana@example.com', name: 'Dana'),
        attendees: const [
          EventAttendee(MailAddress(email: 'dana@example.com', name: 'Dana'),
              response: EventResponse.organizer),
        ],
        response: EventResponse.notResponded,
        joinUrl: joinUrl,
        reminderMinutes: 15,
      );

  Future<(ProviderContainer, SampleMailEngine, Account)> pump(
    WidgetTester tester,
    Widget home, {
    List<CalendarEvent> Function(Account hadco)? events,
    Size size = const Size(1000, 1400),
    DateTime? clock,
    FakeMailNotifier? notifier,
    Future<void> Function(SampleMailEngine engine, Account hadco)? prepare,
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
    engine.events[hadco.id] = events?.call(hadco) ?? const [];
    if (prepare != null) await tester.runAsync(() => prepare(engine, hadco));
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      phoneCalendarProvider.overrideWithValue(FakePhoneCalendar()),
      if (clock != null) meetingClockProvider.overrideWithValue(() => clock),
      if (notifier != null) mailNotifierProvider.overrideWithValue(notifier),
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
    return (c, engine, hadco);
  }

  const barHome = Scaffold(
    body: Column(children: [NextMeetingBar(), Expanded(child: SizedBox())]),
  );

  String barText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('next-meeting-text')))
      .textSpan!
      .toPlainText();

  group('the next meeting over the mail (#9)', () {
    testWidgets('a quarter of an hour before, with Join', (tester) async {
      await pump(tester, barHome,
          clock: now,
          events: (hadco) => [meeting(hadco, 'a', DateTime(2026, 10, 26, 10))]);
      expect(find.byKey(const ValueKey('next-meeting-bar')), findsOneWidget);
      expect(barText(tester), 'Weekly sync  in 10 min');
      expect(find.byKey(const ValueKey('next-meeting-join')), findsOneWidget);
    });

    testWidgets('nothing before then, and nothing without a calendar',
        (tester) async {
      await pump(tester, barHome,
          clock: now,
          events: (hadco) => [meeting(hadco, 'a', DateTime(2026, 10, 26, 10, 30))]);
      expect(find.byKey(const ValueKey('next-meeting-bar')), findsNothing);
    });

    testWidgets('a tap opens it; a swipe puts it away until the next',
        (tester) async {
      final (c, _, hadco) = await pump(tester, barHome,
          clock: now,
          events: (hadco) => [
                meeting(hadco, 'a', DateTime(2026, 10, 26, 10)),
                meeting(hadco, 'b', DateTime(2026, 10, 26, 10, 5),
                    title: 'Design review', joinUrl: null),
              ]);
      await tester.tap(find.byKey(const ValueKey('next-meeting-bar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-accept')), findsOneWidget,
          reason: "the meeting's own sheet");
      Navigator.of(tester.element(find.byKey(const ValueKey('event-accept'))))
          .pop();
      await tester.pumpAndSettle();

      await tester.drag(
          find.byKey(const ValueKey('next-meeting-bar')), const Offset(800, 0));
      await tester.pumpAndSettle();
      expect(barText(tester), 'Design review  in 15 min');
      expect(find.byKey(const ValueKey('next-meeting-join')), findsNothing);
      final first = meeting(hadco, 'a', DateTime(2026, 10, 26, 10));
      expect(c.read(meetingBarDismissedProvider), {meetingKey(first)});
      expect(ui.readIds(UiStateKeys.meetingBarDismissed), {meetingKey(first)});
    });
  });

  group('My Day beside the mail (#10)', () {
    testWidgets("today's meetings in the folders' place, and back",
        (tester) async {
      await pump(tester, const AppShell(),
          size: const Size(1400, 900),
          clock: now,
          events: (hadco) => [
                meeting(hadco, 'a', DateTime(2026, 10, 26, 9),
                    title: 'Stand-up', joinUrl: null),
                meeting(hadco, 'b', DateTime(2026, 10, 26, 10)),
                meeting(hadco, 'c', DateTime(2026, 10, 26, 15),
                    title: 'Design review'),
              ]);
      expect(find.byType(FolderTreePanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-day-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(MyDayPane), findsOneWidget);
      expect(find.byType(FolderTreePanel), findsNothing);
      for (final id in ['a', 'b', 'c']) {
        expect(find.byKey(ValueKey('my-day-event:$id')), findsOneWidget);
      }
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('my-day-join')),
              matching: find.text('Join Weekly sync')),
          findsOneWidget);
      expect(find.text('Tuesday 27 October'), findsOneWidget);
      expect(find.text('Nothing on tomorrow'), findsOneWidget);
      expect(ui.readString(UiStateKeys.myDay), 'true');

      await tester.tap(find.byKey(const ValueKey('my-day-close')));
      await tester.pumpAndSettle();
      expect(find.byType(MyDayPane), findsNothing);
      expect(find.byType(FolderTreePanel), findsOneWidget);
    });

    testWidgets('a meeting there opens its sheet', (tester) async {
      await ui.writeString(UiStateKeys.myDay, 'true');
      await pump(tester, const AppShell(),
          size: const Size(1400, 900),
          clock: now,
          events: (hadco) =>
              [meeting(hadco, 'c', DateTime(2026, 10, 26, 15))]);
      await tester.tap(find.byKey(const ValueKey('my-day-event:c')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-accept')), findsOneWidget);
    });

    testWidgets("tomorrow's meetings under today's, its date opening the "
        'calendar on it', (tester) async {
      await ui.writeString(UiStateKeys.myDay, 'true');
      await pump(tester, const AppShell(),
          size: const Size(1400, 900),
          clock: now,
          events: (hadco) => [
                meeting(hadco, 'c', DateTime(2026, 10, 26, 15)),
                meeting(hadco, 'late', DateTime(2026, 10, 26, 23, 45),
                    title: 'Launch watch'),
                meeting(hadco, 't', DateTime(2026, 10, 27, 9),
                    title: 'Planning'),
              ]);
      expect(find.byKey(const ValueKey('my-day-event:c')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-day-tomorrow:c')), findsNothing);
      expect(find.byKey(const ValueKey('my-day-tomorrow:t')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-day-event:t')), findsNothing);
      for (final day in ['my-day-event', 'my-day-tomorrow']) {
        expect(find.byKey(ValueKey('$day:late')), findsOneWidget,
            reason: 'over midnight, in both');
      }
      expect(find.text('Nothing on tomorrow'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('my-day-tomorrow:t')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-accept')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const ValueKey('event-accept'))))
          .pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('my-day-tomorrow-date')));
      await tester.pumpAndSettle();
      expect(tester.widget<CalendarScreen>(find.byType(CalendarScreen)).day,
          DateTime(2026, 10, 27));
    });

    testWidgets('a free day says so, with tomorrow still under it',
        (tester) async {
      await ui.writeString(UiStateKeys.myDay, 'true');
      await pump(tester, const AppShell(),
          size: const Size(1400, 900),
          clock: now,
          events: (hadco) => [meeting(hadco, 't', DateTime(2026, 10, 27, 9))]);
      expect(find.text('Nothing on today'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-day-tomorrow:t')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-day-join')), findsNothing);
    });
  });

  group('a notification tapped', () {
    testWidgets("a meeting's reminder opens it on the calendar",
        (tester) async {
      final today = DateTime.now();
      final at = DateTime(today.year, today.month, today.day, 12);
      final notifier = FakeMailNotifier();
      await pump(
        tester,
        const AppShell(),
        notifier: notifier,
        events: (hadco) => [meeting(hadco, 'r', at, title: 'Board review')],
        prepare: (engine, hadco) async {
          // Read once, as the reminder's pass read it: the device keeps it.
          await engine.calendarEvents(hadco.id,
              DateTime(at.year, at.month, at.day), at.add(const Duration(days: 1)));
          notifier.launchPayload =
              MeetingRef.of(meeting(hadco, 'r', at, title: 'Board review'))
                  .payload;
        },
      );
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('event-accept')), findsOneWidget,
          reason: "the meeting's sheet over the calendar");
    });

    testWidgets("the agenda opens the calendar on its day", (tester) async {
      final notifier = FakeMailNotifier()
        ..launchPayload = calendarDayPayload(DateTime(2027, 2, 1));
      await pump(tester, const AppShell(), notifier: notifier);
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.text('February 2027'), findsWidgets);
    });
  });

  group('Settings, Calendar', () {
    testWidgets('reminders by account, and the morning agenda',
        (tester) async {
      final (c, _, hadco) = await pump(tester, const CalendarSettingsScreen());
      final reminders = find.byKey(ValueKey('meeting-reminders:${hadco.id}'));
      await tester.scrollUntilVisible(reminders, 200);
      expect(tester.widget<SwitchListTile>(reminders).value, isTrue,
          reason: 'a Microsoft account reminds unless switched off');
      await tester.tap(reminders);
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).meetingReminders, {hadco.id: false});

      final agenda = find.byKey(const ValueKey('calendar-agenda'));
      await tester.scrollUntilVisible(agenda, 200);
      expect(tester.widget<SwitchListTile>(agenda).value, isTrue);
      expect(find.byKey(const ValueKey('calendar-agenda-time')), findsOneWidget);
      await tester.tap(agenda);
      await tester.pumpAndSettle();
      expect(c.read(calendarPrefsProvider).agendaAt, isNull);
      expect(find.byKey(const ValueKey('calendar-agenda-time')), findsNothing);
    });
  });
}
