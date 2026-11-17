import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/state/attachment_providers.dart'
    show fileBridgeProvider;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show showEventDetails;
import 'package:myemail/ui/calendar/meeting_share.dart';
import 'package:myemail/ui/messages/date_format.dart' show formatDay;

import 'fakes/fake_webview.dart';

/// Copy or share a meeting, or a day's meetings (calendar idea #48): as
/// plain text, to the clipboard or to Android's share sheet. A link in a
/// place is named, not written out, in a day's list; one meeting shared on
/// purpose gives its link to join whole.
void main() {
  const dana = MailAddress(email: 'dana.levi@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');
  const teams = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_x';
  const zoom = 'https://us02web.zoom.us/j/81234567890?pwd=Q2xTb3B';

  // Next Tuesday, as the sheet's pictures have it.
  final tuesday = DateTime(2026, 11, 24);
  DateTime at(int hour, [int minute = 0, int days = 0]) =>
      DateTime(tuesday.year, tuesday.month, tuesday.day + days, hour, minute);
  final day = formatDay(tuesday);

  CalendarEvent meeting(
    String id, {
    String accountId = 'a',
    String calendarId = CalendarEvent.mainCalendar,
    String title = 'Supplier call',
    DateTime? start,
    Duration length = const Duration(hours: 1),
    bool allDay = false,
    String location = '',
    String? joinUrl,
    EventResponse response = EventResponse.accepted,
    bool cancelled = false,
    bool private = false,
    bool readOnly = false,
  }) {
    final from = start ?? at(14);
    return CalendarEvent(
      id: id,
      accountId: accountId,
      calendarId: calendarId,
      title: title,
      start: from,
      end: allDay
          ? DateTime(from.year, from.month, from.day + 1)
          : from.add(length),
      allDay: allDay,
      location: location,
      joinUrl: joinUrl,
      organizer: dana,
      attendees: [
        const EventAttendee(dana, response: EventResponse.organizer),
        EventAttendee(ron, response: response),
      ],
      response: response,
      cancelled: cancelled,
      isPrivate: private,
      readOnly: readOnly,
    );
  }

  group("one meeting's details, shared on purpose", () {
    test('its title, when, where, and the link to join it, whole', () {
      expect(
        meetingText(
          meeting('m',
              location: 'Room 4 (2nd floor), Hadco HQ', joinUrl: teams),
          use24h: true,
        ),
        'Supplier call\n'
        '$day, 14:00–15:00\n'
        'Room 4 (2nd floor), Hadco HQ\n'
        'Join: $teams',
      );
      expect(
        meetingText(meeting('m'), use24h: false),
        'Supplier call\n$day, 2:00 PM–3:00 PM',
        reason: "the phone's own clock; nothing for what it has none of",
      );
    });

    test('a link written as its place is named there, and given whole to '
        'join by', () {
      expect(
        meetingText(meeting('m', location: zoom, joinUrl: zoom), use24h: true),
        'Supplier call\n$day, 14:00–15:00\nZoom\nJoin: $zoom',
      );
    });

    test("a place that is only a link to somewhere, a map's, is the link",
        () {
      const map = 'https://maps.app.goo.gl/AbC123';
      expect(meetingText(meeting('m', location: map), use24h: true),
          'Supplier call\n$day, 14:00–15:00\n$map');
    });

    test('a place that is nothing but links: only the link to somewhere, '
        "not a meeting's link and its passcode beside it", () {
      const map = 'https://maps.app.goo.gl/AbC';
      final text = meetingText(
          meeting('m', location: '$zoom $map'), use24h: true);
      expect(text, 'Supplier call\n$day, 14:00–15:00\n$map');
      expect(text, isNot(contains('pwd=')));
    });

    test("a map's link inside Safe Links goes out as the link it holds: the "
        "wrapper carries Ron's own address and tenant", () {
      const wrapped = 'https://nam12.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fmaps.app.goo.gl%2FAbC'
          '&data=05%7C02%7Cron%40hadco.example%7C8f1e%7C72f9&reserved=0';
      final text = meetingText(meeting('m', location: wrapped), use24h: true);
      expect(text,
          'Supplier call\n$day, 14:00–15:00\nhttps://maps.app.goo.gl/AbC');

      // One that holds no single link to go by is named, never written.
      const twice = 'https://nam12.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fa.example%2F&url=https%3A%2F%2Fb.example%2F'
          '&data=05%7C02%7Cron%40hadco.example';
      final named = meetingText(meeting('m', location: twice), use24h: true);
      expect(named, isNot(contains('data=')));
      expect(named, isNot(contains('%40')));
      expect(named.split('\n'), hasLength(3), reason: 'a place line still');
    });

    test('a whole day, untitled, Hebrew as it is written', () {
      expect(
          meetingText(meeting('m', allDay: true, title: ''), use24h: true),
          '(No title)\nAll day, $day');
      expect(
          meetingText(meeting('m', title: 'סנכרון שבועי'), use24h: true)
              .split('\n')
              .first,
          'סנכרון שבועי');
    });
  });

  group("a day's meetings, as a few lines", () {
    test('the day, then each meeting, the whole days first, with when and '
        'where; a link in a place named, never written out', () {
      final text = dayText(
        tuesday,
        [
          meeting('lunch',
              title: 'Lunch with Tom', start: at(12), location: 'Café Noir'),
          meeting('call',
              start: at(10),
              location: 'Zoom: $zoom',
              joinUrl: zoom),
          meeting('count', title: 'Inventory count', allDay: true),
          meeting('sync', title: 'Weekly sync', start: at(16), joinUrl: teams),
        ],
        use24h: true,
      );
      expect(
        text,
        '$day\n'
        'All day  Inventory count\n'
        '10:00–11:00  Supplier call · Zoom\n'
        '12:00–13:00  Lunch with Tom · Café Noir\n'
        '16:00–17:00  Weekly sync · Online',
      );
      expect(text, isNot(contains('zoom.us')));
      expect(text, isNot(contains('teams.microsoft.com')));
    });

    test("a link in a meeting's title is named too, never written out", () {
      final text = dayText(
        tuesday,
        [meeting('t', title: 'Board call $zoom', location: 'Room 4')],
        use24h: true,
      );
      expect(text, '$day\n14:00–15:00  Board call · Zoom · Room 4');
      expect(text, isNot(contains('pwd=')));
    });

    test('what Ron will not be at is left out: declined, cancelled', () {
      expect(
        dayText(
          tuesday,
          [
            meeting('a', start: at(9), response: EventResponse.declined),
            meeting('b', start: at(11), cancelled: true),
            meeting('c', title: 'Plant tour', start: at(13)),
          ],
          use24h: true,
        ),
        '$day\n13:00–14:00  Plant tour',
      );
    });

    test('a meeting on two calendars is said once', () {
      expect(
        dayText(
          tuesday,
          [
            meeting('h', accountId: 'hadco'),
            meeting('g', accountId: 'gmail', title: ' supplier CALL '),
          ],
          use24h: true,
        ).split('\n'),
        hasLength(2),
      );
      expect(
        dayText(
          tuesday,
          [
            meeting('a', accountId: 'gmail'),
            meeting('b', accountId: 'gmail', calendarId: 'team@group'),
          ],
          use24h: true,
        ).split('\n'),
        hasLength(2),
        reason: "one account's two calendars",
      );
    });

    test('two meetings on one calendar are two lines, whatever they share',
        () {
      expect(
        dayText(
          tuesday,
          [
            meeting('x', title: 'Call', location: 'Room 4'),
            meeting('y', title: 'Call', location: 'Home'),
          ],
          use24h: true,
        ),
        '$day\n14:00–15:00  Call · Room 4\n14:00–15:00  Call · Home',
      );
      // Three: two on one calendar, and a copy of one on another.
      expect(
        dayText(
          tuesday,
          [
            meeting('x', title: 'Call'),
            meeting('y', title: 'Call'),
            meeting('z', accountId: 'gmail', title: 'Call'),
          ],
          use24h: true,
        ).split('\n'),
        hasLength(3),
      );
    });

    test('a meeting on two calendars, private on either, says only Private, '
        'whichever comes first', () {
      final open = meeting('o',
          accountId: 'gmail', title: 'Doctor', location: 'Clinic');
      final closed =
          meeting('c', accountId: 'hadco', title: 'Doctor', private: true);
      for (final order in [
        [open, closed],
        [closed, open],
      ]) {
        expect(dayText(tuesday, order, use24h: true),
            '$day\n14:00–15:00  Private');
      }
    });

    test("a private meeting says only that the time is taken: it is kept to "
        'the account', () {
      expect(
        dayText(tuesday,
            [meeting('p', title: 'Doctor', location: 'Clinic', private: true)],
            use24h: true),
        '$day\n14:00–15:00  Private',
      );
    });

    test('one from the night before, or on into the next, says so', () {
      expect(
        dayText(
          tuesday,
          [
            meeting('late',
                start: at(23, 0, -1), length: const Duration(hours: 2)),
            meeting('night',
                title: 'Night shift',
                start: at(22),
                length: const Duration(hours: 9)),
          ],
          use24h: true,
        ),
        '$day\nUntil 01:00  Supplier call\nFrom 22:00  Night shift',
      );
    });

    test('a day with nothing on says so; only the day asked for is listed',
        () {
      expect(dayText(tuesday, const [], use24h: true), '$day\nNothing on.');
      expect(
          dayText(tuesday, [meeting('w', start: at(9, 0, 1))], use24h: true),
          '$day\nNothing on.');
    });
  });

  group("on the meeting's sheet", () {
    setUpAll(FakeWebViewPlatform.install);

    late SampleMailEngine engine;
    late FakeFileBridge files;
    late List<String> copied;

    Future<void> pump(
      WidgetTester tester,
      List<CalendarEvent> Function(Account a) events, {
      bool use24h = true,
      MailProvider provider = MailProvider.outlook,
    }) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SizedBox());
      copied = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add('${(call.arguments as Map)['text']}');
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      engine = SampleMailEngine();
      files = FakeFileBridge();
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
      final all = events(account);
      engine.events[account.id] = all;
      final container = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        fileBridgeProvider.overrideWithValue(files),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
        meetingClockProvider
            .overrideWithValue(() => DateTime(2026, 11, 17, 9)),
      ]);
      addTearDown(container.dispose);
      container.listen(accountsProvider, (_, _) {});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(alwaysUse24HourFormat: use24h),
            child: child!,
          ),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  key: const ValueKey('open-sheet'),
                  onPressed: () =>
                      showEventDetails(context, ref, all.first, account),
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

    Future<List<String>> menu(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      return [
        for (final item in tester.widgetList<PopupMenuItem<String>>(
            find.byType(PopupMenuItem<String>)))
          (item.child! as Text).data!,
      ];
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    String? said(WidgetTester tester) {
      final bar = find.byType(SnackBar);
      if (bar.evaluate().isEmpty) return null;
      return tester
          .widget<Text>(
              find.descendant(of: bar, matching: find.byType(Text)).first)
          .data;
    }

    testWidgets("under ⋮, after Duplicate: Copy details, Share and Share the "
        'day', (tester) async {
      await pump(tester, (a) => [meeting('m', accountId: a.id)]);
      expect(await menu(tester), [
        'Email everyone',
        'Forward',
        'Propose a new time',
        'My reminder',
        'Show me as',
        'Duplicate',
        'Copy details',
        'Share',
        'Share the day',
        'Decline and remove',
      ]);
    });

    testWidgets('a meeting on a calendar only read has them too, and nothing '
        'that would change it', (tester) async {
      await pump(
          tester, (a) => [meeting('m', accountId: a.id, readOnly: true)]);
      expect(await menu(tester), ['Copy details', 'Share', 'Share the day']);
    });

    testWidgets('Copy details puts the text on the clipboard, and says so',
        (tester) async {
      await pump(
          tester,
          (a) => [
                meeting('m',
                    accountId: a.id, location: 'Room 4', joinUrl: teams),
              ]);
      await menu(tester);
      await tapKey(tester, 'event-copy');
      expect(copied,
          ['Supplier call\n$day, 14:00–15:00\nRoom 4\nJoin: $teams']);
      expect(said(tester), 'Details copied.');
      expect(files.sharedTexts, isEmpty);
    });

    testWidgets("Share hands it to Android's share sheet, its title as the "
        "subject, on the phone's own clock", (tester) async {
      await pump(tester, (a) => [meeting('m', accountId: a.id)],
          use24h: false);
      await menu(tester);
      await tapKey(tester, 'event-share');
      expect(files.sharedTexts, [
        (
          text: 'Supplier call\n$day, 2:00 PM–3:00 PM',
          subject: 'Supplier call',
        ),
      ]);
      expect(copied, isEmpty);
    });

    testWidgets("Share the day shows the day's meetings as they will go, to "
        'copy or to share', (tester) async {
      await pump(
          tester,
          (a) => [
                meeting('m', accountId: a.id, location: 'Room 4'),
                meeting('t',
                    accountId: a.id,
                    title: 'Plant tour',
                    start: at(9),
                    location: zoom),
                meeting('x', accountId: a.id, start: at(9, 0, 1)),
              ]);
      await menu(tester);
      await tapKey(tester, 'event-share-day');
      final expected = '$day\n'
          '09:00–10:00  Plant tour · Zoom\n'
          '14:00–15:00  Supplier call · Room 4';
      expect(find.text(day), findsWidgets, reason: 'the day, as its title');
      expect(find.text('09:00–10:00  Plant tour · Zoom'), findsOneWidget);
      expect(
          find.text('14:00–15:00  Supplier call · Room 4'), findsOneWidget);

      await tapKey(tester, 'day-copy');
      expect(copied, [expected]);
      expect(said(tester), 'Day copied.');

      // The sheet closed as the box opened: open it again.
      await tapKey(tester, 'open-sheet');
      await menu(tester);
      await tapKey(tester, 'event-share-day');
      await tapKey(tester, 'day-share');
      expect(files.sharedTexts, [(text: expected, subject: day)]);
    });

    testWidgets("the day's box keeps Copy and Share off, and says Reading…, "
        'until the calendars have read the day', (tester) async {
      await pump(tester, (a) => [meeting('m', accountId: a.id)]);
      await menu(tester);
      await tester.tap(find.byKey(const ValueKey('event-share-day')));
      // A moment in: the device's kept copy is shown, the calendar still
      // being read (the sample engine answers in 30 ms).
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(find.text('Reading…'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('day-share')))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('day-copy')))
              .onPressed,
          isNull);

      await tester.pumpAndSettle();
      expect(find.text('Reading…'), findsNothing);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('day-share')))
              .onPressed,
          isNotNull);
      expect(find.text('14:00–15:00  Supplier call'), findsOneWidget);
    });

    testWidgets("a Hebrew line in the day's list reads from the right",
        (tester) async {
      await pump(
          tester,
          (a) => [meeting('m', accountId: a.id, title: 'סנכרון שבועי')]);
      await menu(tester);
      await tapKey(tester, 'event-share-day');
      final line =
          tester.widget<Text>(find.text('14:00–15:00  סנכרון שבועי'));
      expect(line.textDirection, TextDirection.rtl);
    });
  });
}
