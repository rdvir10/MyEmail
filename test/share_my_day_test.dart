import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/files/file_bridge.dart' show FakeFileBridge;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/state/attachment_providers.dart'
    show fileBridgeProvider;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';

import 'fakes/fake_webview.dart';

/// Share my day in the calendar's own menu (the last piece of calendar
/// idea #48): the day the view is on, as a meeting's sheet shares its day.
void main() {
  setUp(FakeWebViewPlatform.install);

  final today = DateTime.now();
  DateTime on(int days, int h) =>
      DateTime(today.year, today.month, today.day + days, h);
  String day(int days) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
      'Nov', 'Dec',
    ];
    final d = DateTime(today.year, today.month, today.day + days);
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]}'
        '${d.year == today.year ? '' : ' ${d.year}'}';
  }

  late FakeFileBridge files;

  Future<void> pump(WidgetTester tester, {bool calendar = true}) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final engine = SampleMailEngine();
    files = FakeFileBridge();
    if (calendar) {
      final a = (await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Hadco',
            emailAddress: 'ron@hadco.example',
            provider: MailProvider.outlook,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          )))!;
      CalendarEvent meeting(String id, String title, DateTime start) =>
          CalendarEvent(
            id: id,
            accountId: a.id,
            title: title,
            start: start,
            end: start.add(const Duration(hours: 1)),
          );
      engine.events[a.id] = [
        meeting('a', 'Supplier call', on(0, 14)),
        meeting('b', 'Plant tour', on(1, 9)),
      ];
    }
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      fileBridgeProvider.overrideWithValue(files),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      meetingClockProvider.overrideWithValue(() => on(0, 10)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: const CalendarScreen(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<List<String>> menu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('calendar-menu')));
    await tester.pumpAndSettle();
    return [
      for (final item in tester.widgetList<PopupMenuEntry<String>>(
          find.byWidgetPredicate((w) => w is PopupMenuEntry<String>)))
        if (item is PopupMenuItem<String>) '${item.value}',
    ];
  }

  testWidgets("Share my day is the menu's last, after I am away, and shows "
      'the day the view is on, to share', (tester) async {
    await pump(tester);
    final items = await menu(tester);
    expect(items.sublist(items.length - 2), ['away', 'share-day']);
    expect(find.text('Share my day'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calendar-share-day')));
    await tester.pumpAndSettle();
    expect(find.text(day(0)), findsWidgets, reason: 'the day, as its title');
    expect(find.text('14:00–15:00  Supplier call'), findsOneWidget);
    expect(find.text('09:00–10:00  Plant tour'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('day-share')));
    await tester.pumpAndSettle();
    expect(files.sharedTexts,
        [(text: '${day(0)}\n14:00–15:00  Supplier call', subject: day(0))]);
  });

  testWidgets('moved on a day, it is that day', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
    await tester.pumpAndSettle();
    await menu(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-next')));
    await tester.pumpAndSettle();
    await menu(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-share-day')));
    await tester.pumpAndSettle();
    expect(find.text('09:00–10:00  Plant tour'), findsOneWidget);
    expect(find.text('14:00–15:00  Supplier call'), findsNothing);
    expect(files.sharedTexts, isEmpty, reason: 'nothing until Share');
  });

  testWidgets('no calendar, no Share my day', (tester) async {
    await pump(tester, calendar: false);
    await menu(tester);
    expect(find.byKey(const ValueKey('calendar-share-day')), findsNothing);
  });
}
