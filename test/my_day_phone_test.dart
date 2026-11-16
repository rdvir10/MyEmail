import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/meeting_alert_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/my_day_pane.dart';
import 'package:myemail/ui/messages/message_list_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// My Day on the phone (calendar idea #76): today's and tomorrow's
/// meetings without leaving the mail, as the tablet has them in its folder
/// pane. Held, the calendar button in the phone's top bar opens them as a
/// sheet over the mail; tapped, it is still the calendar (#98).
void main() {
  setUpAll(() async {
    FakeWebViewPlatform.install();
    await loadRoboto();
  });

  // A Monday morning, ten minutes before the sync.
  final now = DateTime(2026, 10, 26, 9, 50);
  late MemoryUiStateStore ui;

  setUp(() => ui = MemoryUiStateStore());

  const dana = MailAddress(email: 'dana@example.com', name: 'Dana');

  CalendarEvent meeting(
    Account hadco,
    String id,
    DateTime start, {
    String title = 'Weekly sync',
    String? joinUrl = 'https://teams.microsoft.com/l/meetup-join/x',
    String location = '',
  }) =>
      CalendarEvent(
        id: id,
        accountId: hadco.id,
        title: title,
        start: start,
        end: start.add(const Duration(minutes: 30)),
        location: location,
        organizer: dana,
        attendees: const [
          EventAttendee(dana, response: EventResponse.organizer),
        ],
        response: EventResponse.notResponded,
        joinUrl: joinUrl,
      );

  /// The day's meetings: a stand-up over, the sync next, a review later,
  /// and tomorrow's planning.
  List<CalendarEvent> day(Account hadco) => [
        meeting(hadco, 'a', DateTime(2026, 10, 26, 9),
            title: 'Stand-up', joinUrl: null),
        meeting(hadco, 'b', DateTime(2026, 10, 26, 10)),
        meeting(hadco, 'c', DateTime(2026, 10, 26, 15),
            title: 'Design review', location: 'Room 4'),
        meeting(hadco, 't', DateTime(2026, 10, 27, 9), title: 'Planning'),
      ];

  Future<(ProviderContainer, SampleMailEngine)> pump(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    double scale = 1.0,
    double bottomBar = 0,
    bool calendar = true,
    List<CalendarEvent> Function(Account hadco)? events,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(bottom: bottomBar);
    tester.view.viewPadding = FakeViewPadding(bottom: bottomBar);
    addTearDown(tester.view.reset);
    final engine = SampleMailEngine();
    if (calendar) {
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
      engine.events[hadco.id] = (events ?? day)(hadco);
    }
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      phoneCalendarProvider.overrideWithValue(FakePhoneCalendar()),
      meetingClockProvider.overrideWithValue(() => now),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const AppShell(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (c, engine);
  }

  final button = find.byKey(const ValueKey('mail-calendar'));
  final sheet = find.byKey(const ValueKey('my-day-sheet'));
  Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);

  Future<void> hold(WidgetTester tester) async {
    await tester.longPress(button);
    await tester.pumpAndSettle();
  }

  testWidgets('held, the calendar button opens My Day over the mail: the '
      "next meeting's Join, today, then tomorrow", (tester) async {
    await pump(tester);
    expect(sheet, findsNothing);
    await hold(tester);

    expect(sheet, findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(CalendarScreen), findsNothing,
        reason: 'over the mail, not the calendar');
    expect(find.byType(MessageListPane), findsOneWidget);
    expect(inSheet(find.text('My Day')), findsOneWidget);
    expect(inSheet(find.text('Monday 26 October')), findsOneWidget);
    expect(
        find.descendant(
            of: inSheet(find.byKey(const ValueKey('my-day-join'))),
            matching: find.text('Join Weekly sync')),
        findsOneWidget);
    for (final id in ['a', 'b', 'c']) {
      expect(inSheet(find.byKey(ValueKey('my-day-event:$id'))), findsOneWidget);
    }
    expect(inSheet(find.text('Tomorrow')), findsOneWidget);
    expect(inSheet(find.text('Tuesday 27 October')), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('my-day-tomorrow:t'))),
        findsOneWidget);
    // Join first, then today, then tomorrow, down the sheet.
    final join = tester.getRect(find.byKey(const ValueKey('my-day-join')));
    final first = tester.getRect(find.byKey(const ValueKey('my-day-event:a')));
    final tomorrow = tester.getRect(find.text('Tomorrow'));
    expect(join.bottom, lessThanOrEqualTo(first.top));
    expect(first.bottom, lessThan(tomorrow.top));
    // It sits over the mail and is not the whole screen.
    final drawn = tester.getRect(find.byType(BottomSheet));
    expect(drawn.top, greaterThan(100));
    expect(drawn.bottom, 915);
  });

  testWidgets('a tap is still the calendar, on today (#98)', (tester) async {
    await pump(tester);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(sheet, findsNothing);
  });

  testWidgets('a meeting there closes My Day and opens its sheet; Back is '
      'the mail', (tester) async {
    await pump(tester);
    await hold(tester);
    await tester.tap(find.byKey(const ValueKey('my-day-event:c')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.byKey(const ValueKey('event-accept')), findsOneWidget,
        reason: "the meeting's own sheet");
    expect(find.text('Design review'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-accept')), findsNothing);
    expect(sheet, findsNothing);
    expect(find.byType(MessageListPane), findsOneWidget);
  });

  testWidgets("an action on that meeting's sheet still reaches the calendar "
      'after My Day has gone', (tester) async {
    final (_, engine) = await pump(tester);
    await hold(tester);
    await tester.tap(find.byKey(const ValueKey('my-day-event:c')));
    await tester.pumpAndSettle();
    // Accept, sent now, from the menu under the button.
    await tester.tap(find.byKey(const ValueKey('event-accept')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('answer-now')).last);
    await tester.pumpAndSettle();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(engine.calendarActions, ['respond c accepted']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('its dates open the calendar on their day, My Day closed',
      (tester) async {
    await pump(tester);
    await hold(tester);
    await tester.tap(find.byKey(const ValueKey('my-day-date')));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(tester.widget<CalendarScreen>(find.byType(CalendarScreen)).day,
        isNull, reason: 'today, as the button opens it');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsNothing);
    expect(sheet, findsNothing);

    await hold(tester);
    await tester.tap(find.byKey(const ValueKey('my-day-tomorrow-date')));
    await tester.pumpAndSettle();
    expect(tester.widget<CalendarScreen>(find.byType(CalendarScreen)).day,
        DateTime(2026, 10, 27));
  });

  testWidgets('closed by its X or by Back, the mail is as it was, and the '
      "tablet's My Day is not switched on", (tester) async {
    final (c, _) = await pump(tester);
    final list = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere((s) => s.position.maxScrollExtent > 100);
    list.position.jumpTo(100);
    await tester.pumpAndSettle();

    await hold(tester);
    await tester.tap(inSheet(find.byKey(const ValueKey('my-day-close'))));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(c.read(myDayShownProvider), isFalse);
    expect(ui.readString(UiStateKeys.myDay), isNot('true'));

    await hold(tester);
    expect(
        tester.widget<IconButton>(inSheet(find.ancestor(
            of: find.byIcon(Icons.close), matching: find.byType(IconButton)))),
        isA<IconButton>().having((b) => b.tooltip, 'tooltip', 'Close'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(list.position.pixels, 100);
    expect(c.read(myDayShownProvider), isFalse);
  });

  testWidgets('it takes no row of the list: the list starts where it did',
      (tester) async {
    await pump(tester);
    final list = find.byType(MessageListPane);
    final before = tester.getRect(list);
    await hold(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.getRect(list), before);
    expect(find.byType(MyDayPane), findsNothing);
  });

  testWidgets('a screen reader is told the button holds My Day',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);
    final node = tester.getSemantics(button);
    final data = node.getSemanticsData();
    expect(data.tooltip, 'Calendar');
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.hasAction(SemanticsAction.longPress), isTrue);
    expect(node.hintOverrides?.onLongPressHint, 'My Day');
    semantics.dispose();
  });

  testWidgets('with no account that has a calendar, holding it opens '
      'nothing over the mail', (tester) async {
    await pump(tester, calendar: false);
    await tester.longPress(button);
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.byType(CalendarScreen), findsNothing);
  });

  for (final (size, scale) in [
    (const Size(360, 780), 1.3),
    (const Size(412, 915), 1.0),
    (const Size(427, 952), 1.0),
  ]) {
    testWidgets('${size.width.round()} wide, text at $scale, with a 48 high '
        'system bar: nothing cut, and the last meeting comes above the bar',
        (tester) async {
      await pump(tester,
          size: size,
          scale: scale,
          bottomBar: 48,
          events: (hadco) => [
                ...day(hadco),
                for (var h = 11; h < 21; h++)
                  meeting(hadco, 'x$h', DateTime(2026, 10, 27, h),
                      title: 'Customer visit – Initech, 400 Industrial Pkwy '
                          '$h',
                      location: 'Initech, 400 Industrial Pkwy'),
                meeting(hadco, 'he', DateTime(2026, 10, 27, 22),
                    title: 'פגישה עם רואה החשבון'),
              ]);
      await hold(tester);
      expect(tester.takeException(), isNull);
      for (final text in ['My Day', 'Monday 26 October', 'Join Weekly sync']) {
        final p = tester.renderObject<RenderParagraph>(
            inSheet(find.text(text)).first);
        if (text != 'Join Weekly sync') {
          expect(p.didExceedMaxLines, isFalse, reason: text);
        }
        expect(p.size.width, greaterThan(0));
      }
      // Scrolled to its end.
      final list = tester
          .state<ScrollableState>(inSheet(find.byType(Scrollable)).first)
          .position;
      // Its length is known as its rows are laid out: to the end until
      // the end stays put.
      for (var i = 0; i < 5; i++) {
        list.jumpTo(list.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      final last =
          tester.getRect(find.byKey(const ValueKey('my-day-tomorrow:he')));
      expect(last.bottom, lessThanOrEqualTo(size.height - 48));
      // A Hebrew title reads from the right, as on the tablet.
      final hebrew = tester.widget<Text>(find.text('פגישה עם רואה החשבון'));
      expect(hebrew.textDirection, TextDirection.rtl);
      expect(tester.takeException(), isNull);
    });
  }
}
