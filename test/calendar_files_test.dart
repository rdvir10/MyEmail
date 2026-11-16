import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/calendar/internet_calendars.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_files.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/recurrence.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_file_screen.dart';
import 'package:myemail/ui/messages/invite_card.dart';
import 'package:myemail/ui/shell/file_drop_host.dart';

/// Calendar files and links opened with MyEmail (calendar idea #67): an
/// .ics from Files, a browser or any app shows its events, each added to
/// the calendar Ron picks, repeat and all; a webcal: link offers itself
/// under Calendars from links; and a repeating invitation added from its
/// card keeps its repeat. What comes from outside is a stranger's: nothing
/// in it throws, and nothing is added until Ron says where.
void main() {
  /// A school's calendar: an evening, a weekly class with a date left out
  /// and people on it, and a monthly meeting by its place in the month,
  /// which New meeting has no words for.
  const school = 'BEGIN:VCALENDAR\r\n'
      'PRODID:-//Example//School//EN\r\n'
      "X-WR-CALNAME:Ella's school\r\n"
      'BEGIN:VEVENT\r\n'
      'UID:evening@example.com\r\n'
      "SUMMARY:Parents' evening\r\n"
      'DTSTART:20261203T120000Z\r\n'
      'DTEND:20261203T130000Z\r\n'
      'LOCATION:School hall\r\n'
      'DESCRIPTION:Bring the reading log.\r\n'
      'END:VEVENT\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:swim@example.com\r\n'
      'SUMMARY:Swimming\r\n'
      'DTSTART:20261202T120000Z\r\n'
      'DTEND:20261202T130000Z\r\n'
      'RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20270630T120000Z\r\n'
      'EXDATE:20261223T120000Z\r\n'
      'ORGANIZER:mailto:coach@example.com\r\n'
      'ATTENDEE;CN=Coach:mailto:coach@example.com\r\n'
      'ATTENDEE;CN=Dana:mailto:dana@example.com\r\n'
      'END:VEVENT\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:committee@example.com\r\n'
      'SUMMARY:Committee\r\n'
      'DTSTART:20261204T120000Z\r\n'
      'DTEND:20261204T130000Z\r\n'
      'RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=1\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR\r\n';

  late Directory temp;
  late FakeFileBridge bridge;
  late FakeDeviceCalendar phone;
  late MemoryInternetCalendars links;
  late SampleMailEngine engine;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('myemail-ics');
    bridge = FakeFileBridge();
    phone = FakeDeviceCalendar(timeZone: 'Asia/Jerusalem');
    links = MemoryInternetCalendars();
    engine = SampleMailEngine();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  IncomingFile aFile(String name, {String? text, List<int>? bytes}) {
    final file = File('${temp.path}/$name');
    if (bytes != null) {
      file.writeAsBytesSync(bytes);
    } else {
      file.writeAsStringSync(text ?? '');
    }
    return IncomingFile(
      path: file.path,
      name: name,
      mimeType: 'text/calendar',
      sizeBytes: file.lengthSync(),
    );
  }

  /// The app opened with [content], on a Hadco account whose calendar
  /// MyEmail writes to.
  Future<(ProviderContainer, Account)> pumpOpened(
    WidgetTester tester,
    SharedContent? content,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    bridge.openedWith = content;
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      fileBridgeProvider.overrideWithValue(bridge),
      deviceCalendarProvider.overrideWithValue(phone),
      internetCalendarReaderProvider.overrideWithValue(links),
    ]);
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: FileDropHost(child: Scaffold(body: Text('The mail'))),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester);
    return (c, hadco);
  }

  group('a calendar file opened with MyEmail', () {
    testWidgets('shows its events, earliest first, how each repeats, and '
        'adds nothing by itself', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('school.ics', text: school),
        calendarOpened: true,
      ));

      expect(find.byType(CalendarFileScreen), findsOneWidget);
      expect(find.text("Ella's school"), findsOneWidget);
      final titles = [
        for (final t in ['Swimming', "Parents' evening", 'Committee'])
          tester.getTopLeft(find.text(t)).dy,
      ];
      expect(titles, orderedEquals([...titles]..sort()));
      expect(find.text('Every week on Wednesday, until 30 June 2027'),
          findsOneWidget);
      expect(find.textContaining('School hall'), findsOneWidget);
      expect(find.textContaining('nobody'), findsWidgets,
          reason: 'it says nobody on it is told');
      expect(engine.meetings, isEmpty);
      expect(phone.inserted, isEmpty);
    });

    testWidgets('Add puts it on the calendar picked, repeat and all, as '
        'your own: nobody on it is invited', (tester) async {
      final (_, hadco) = await pumpOpened(tester, SharedContent(
        calendarFile: aFile('school.ics', text: school),
        calendarOpened: true,
      ));

      await tapAdd(tester, 'Swimming');

      final made = engine.meetings.single;
      expect(made.accountId, hadco.id);
      expect(made.calendarId, CalendarEvent.mainCalendar);
      expect(made.title, 'Swimming');
      expect(made.attendees, isEmpty, reason: 'nothing sent to anyone');
      expect(made.start, DateTime.utc(2026, 12, 2, 12).toLocal());
      expect(made.end, DateTime.utc(2026, 12, 2, 13).toLocal());
      expect(made.recurrence?.kind, RepeatKind.weekly);
      expect(made.recurrence?.days, {DateTime.wednesday});
      expect(made.recurrence?.until, DateTime(2027, 6, 30));
      expect(made.timeZone, 'Asia/Jerusalem');
      expect(find.text('Added to Hadco'), findsOneWidget);
      expect(find.textContaining('left out in the file'), findsOneWidget,
          reason: 'the date the file leaves out is said, as it is not left '
              'out on the calendar');

      await tapAdd(tester, "Parents' evening");
      expect(engine.meetings.last.location, 'School hall');
      expect(engine.meetings.last.notes, 'Bring the reading log.');
      expect(engine.meetings.last.recurrence, isNull);
    });

    testWidgets('a repeat New meeting has no words for is said, and only the '
        'first meeting goes to an account', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('school.ics', text: school),
        calendarOpened: true,
      ));

      expect(find.textContaining('only the first'), findsOneWidget);
      await tapAdd(tester, 'Committee');
      expect(engine.meetings.single.recurrence, isNull);
      expect(find.text('Added to Hadco'), findsOneWidget);
    });

    testWidgets("the phone's calendar app takes such a repeat whole",
        (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('school.ics', text: school),
        calendarOpened: true,
      ));

      await tester.tap(find.byKey(const ValueKey('calendar-file-target')));
      await settle(tester);
      await tester.tap(
          find.byKey(const ValueKey('calendar-file-target:phone')).last);
      await settle(tester);
      expect(find.textContaining('only the first'), findsNothing);

      await tapAdd(tester, 'Committee');
      final handed = phone.inserted.single;
      expect(handed.title, 'Committee');
      expect(handed.rule, 'RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=1');
      expect(handed.attendees, isEmpty);
    });

    testWidgets('a file that is no calendar says so, and nothing else',
        (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('notes.ics', text: 'Shopping: milk, eggs'),
        calendarOpened: true,
      ));
      expect(find.text('This file has no events MyEmail can read.'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-file-target')), findsNothing);
    });

    testWidgets('nor do bytes that are not text, or events with no time',
        (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('photo.ics',
            bytes: [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0xFE]),
        calendarOpened: true,
      ));
      expect(find.text('This file has no events MyEmail can read.'),
          findsOneWidget);
    });

    testWidgets('one with no time it can be placed at', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('odd.ics',
            text: 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:When?\n'
                'DTSTART:tomorrow\nRRULE:FREQ=;;;=\nEND:VEVENT\n'
                'BEGIN:VEVENT\nDTSTART;TZID="Nowhere:20261201T100000\n'
                'END:VEVENT\nEND:VCALENDAR'),
        calendarOpened: true,
      ));
      expect(find.text('This file has no events MyEmail can read.'),
          findsOneWidget);
    });

    testWidgets('one too large to be a calendar is not read', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('huge.ics',
            text: 'BEGIN:VCALENDAR\n${'X' * (5 * 1024 * 1024)}'),
        calendarOpened: true,
      ));
      expect(find.textContaining('too large'), findsOneWidget);
    });

    testWidgets('one Android could not copy in is said to be unreadable',
        (tester) async {
      await pumpOpened(
        tester,
        SharedContent.fromMap({'calendarOpened': true, 'skipped': 1}),
      );
      expect(find.text('That calendar file could not be read.'),
          findsOneWidget);
      expect(find.byType(CalendarFileScreen), findsNothing);
    });

    testWidgets('on a tablet its events are no wider than a page reads',
        (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('school.ics', text: school),
        calendarOpened: true,
      ));
      tester.view.physicalSize = const Size(1280, 800);
      await settle(tester);
      final card = find.byKey(const ValueKey('calendar-file-event')).first;
      expect(tester.getSize(card).width, lessThanOrEqualTo(720));
      expect(tester.getCenter(card).dx, closeTo(640, 1),
          reason: 'in the middle, its margins scrolling with it');
    });

    testWidgets('a Hebrew title reads from the right', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('hebrew.ics',
            text: 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:h\n'
                'SUMMARY:ישיבת צוות\nDTSTART:20261203T120000Z\n'
                'DTEND:20261203T130000Z\nEND:VEVENT\nEND:VCALENDAR'),
        calendarOpened: true,
      ));
      final title = tester.widget<Text>(find.text('ישיבת צוות'));
      expect(title.textDirection, TextDirection.rtl);
    });
  });

  group('a calendar link opened with MyEmail', () {
    testWidgets('offers to add it under Calendars from links, read only '
        'once Add is pressed', (tester) async {
      const link = 'webcal://example.com/team.ics';
      links.feeds['https://example.com/team.ics'] = school;
      final (c, _) = await pumpOpened(
        tester,
        SharedContent.fromMap({'calendarLink': link, 'calendarOpened': true}),
      );

      expect(find.text('Add from a link'), findsOneWidget);
      final field = tester.widget<TextField>(
          find.byKey(const ValueKey('internet-calendar-link')));
      expect(field.controller!.text, link);
      expect(links.asked, isEmpty, reason: 'nothing fetched until Add');

      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(c.read(internetCalendarsProvider), isEmpty);

      await tester.runAsync(() async {
        bridge.receiveShare(SharedContent.fromMap(
            {'calendarLink': link, 'calendarOpened': true})!);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('internet-calendar-save')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await settle(tester);

      final added = c.read(internetCalendarsProvider).single;
      expect(added.url, 'https://example.com/team.ics');
      expect(added.name, "Ella's school");
    });

    test('only a webcal: link is taken for one', () {
      expect(
        SharedContent.fromMap({
          'calendarLink': 'webcals://example.com/a.ics',
          'calendarOpened': true,
        })!.calendarLink,
        'webcals://example.com/a.ics',
      );
      for (final other in [
        'javascript:alert(1)',
        'file:///data/data/com.rdvir.mailtree/x',
        'content://evil/x',
        'webcal:',
        42,
      ]) {
        expect(
          SharedContent.fromMap({'calendarLink': other, 'calendarOpened': true})
              ?.calendarLink,
          isNull,
          reason: '$other',
        );
      }
    });
  });

  group('an invitation that repeats', () {
    // Exchange defines its zones beside the event, each with a RRULE of
    // its own: the event's is the one after BEGIN:VEVENT.
    const weekly = 'BEGIN:VCALENDAR\r\n'
        'METHOD:PUBLISH\r\n'
        'BEGIN:VTIMEZONE\r\n'
        'TZID:Israel Standard Time\r\n'
        'BEGIN:STANDARD\r\n'
        'DTSTART:16010101T020000\r\n'
        'TZOFFSETFROM:+0300\r\n'
        'TZOFFSETTO:+0200\r\n'
        'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10\r\n'
        'END:STANDARD\r\n'
        'END:VTIMEZONE\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:sync@example.com\r\n'
        'SUMMARY:Weekly sync\r\n'
        'DTSTART:20261202T120000Z\r\n'
        'DTEND:20261202T123000Z\r\n'
        'RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20270630T120000Z\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';

    test("the event's own repeat is read, not its zone's", () {
      expect(CalendarInvite.parse(weekly)!.rule,
          'FREQ=WEEKLY;BYDAY=WE;UNTIL=20270630T120000Z');
      expect(
        CalendarInvite.parse(weekly.replaceFirst(
                RegExp(r'RRULE:FREQ=WEEKLY[^\r]*\r\n'), ''))!
            .rule,
        isNull,
      );
    });

    test('the phone is handed a repeat it reads, or none', () {
      final at = DateTime.utc(2026, 12, 2, 12);
      String? rule(String text, {DateTime? ownDay}) => ruleForPhone(text,
          start: at, ownDay: ownDay, local: (t) => t.add(const Duration(hours: 3)));
      expect(rule('FREQ=WEEKLY;BYDAY=WE;UNTIL=20270630T120000Z'),
          'RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20270630T120000Z');
      expect(rule('freq=monthly;byday=1fr'), 'RRULE:FREQ=MONTHLY;BYDAY=1FR');
      for (final odd in [
        'FREQ=WEEKLY;BYDAY=WE;X-EVIL=1',
        'FREQ=HOURLY',
        'BYDAY=WE',
        'FREQ=WEEKLY;FREQ=DAILY',
        'FREQ=WEEKLY;BYDAY=WE"\nEXTRA',
        'FREQ=WEEKLY;INTERVAL=-2',
        '',
        null,
      ]) {
        expect(rule(odd ?? ''), isNull, reason: '$odd');
      }
      // A meeting on its own clock's Tuesday that is the phone's Wednesday:
      // BYDAY=TU, read on the phone's clock, would be the wrong day.
      expect(
        rule('FREQ=WEEKLY;BYDAY=TU', ownDay: DateTime(2026, 12, 1)),
        isNull,
      );
      expect(rule('FREQ=DAILY;COUNT=5', ownDay: DateTime(2026, 12, 1)),
          'RRULE:FREQ=DAILY;COUNT=5',
          reason: 'every day is every day on any clock');
    });

    Future<void> pumpCard(WidgetTester tester, String ics) async {
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(phone),
      ]);
      addTearDown(c.dispose);
      final message = MailMessage(
        id: 'acct-personal:INBOX#1',
        accountId: 'acct-personal',
        folderId: 'acct-personal:INBOX',
        uid: 1,
        subject: 'Weekly sync',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'ron@example.com')],
        date: DateTime(2026, 11, 20),
        preview: '',
      );
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: InviteCard(
              message: message,
              invite: CalendarInvite.parse(ics)!,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('its card says how it repeats, and Add to calendar keeps it',
        (tester) async {
      await pumpCard(tester, weekly);

      expect(find.text('Every week on Wednesday, until 30 June 2027'),
          findsOneWidget);
      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();
      expect(phone.inserted.single.rule,
          'RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20270630T120000Z');
    });

    testWidgets('one that does not repeat says nothing of it, and goes as one '
        'meeting, as before', (tester) async {
      await pumpCard(
        tester,
        weekly.replaceFirst(RegExp(r'RRULE:FREQ=WEEKLY[^\r]*\r\n'), ''),
      );

      expect(find.byIcon(Icons.repeat), findsNothing);
      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();
      expect(phone.inserted.single.title, 'Weekly sync');
      expect(phone.inserted.single.rule, isNull);
    });
  });

  // Android's half, which no Dart test runs: the filters that offer the
  // app for a calendar, and what is taken from what it is opened with.
  group('the Android half', () {
    const main = 'android/app/src/main';
    final manifest = File('$main/AndroidManifest.xml').readAsStringSync();
    final activity = RegExp(
      r'<activity\s+android:name="\.MainActivity"[\s\S]*?</activity>',
    ).firstMatch(manifest)!.group(0)!;
    final filters = RegExp(r'<intent-filter>[\s\S]*?</intent-filter>')
        .allMatches(activity)
        .map((m) => m.group(0)!)
        .toList();
    final bridge = File('$main/kotlin/com/rdvir/mailtree/FilesBridge.kt')
        .readAsStringSync();

    test('MyEmail is offered for a calendar file, and a webcal: link', () {
      final files = filters.where((f) =>
          f.contains('android.intent.action.VIEW') &&
          f.contains('android:mimeType="text/calendar"'));
      expect(files, hasLength(1));
      expect(files.single, contains('android:scheme="content"'),
          reason: 'a file another app grants, never a path');
      expect(files.single, isNot(contains('android:scheme="file"')));
      final links = filters.where((f) =>
          f.contains('android.intent.action.VIEW') &&
          f.contains('android:scheme="webcal"'));
      expect(links, hasLength(1));
      expect(links.single, contains('android:scheme="webcals"'));
      expect(links.single, contains('category.BROWSABLE'));
    });

    test('and asks for no permission to be', () {
      expect(manifest, isNot(contains('CALENDAR"')),
          reason: 'no READ_ or WRITE_CALENDAR: the phone\'s calendar app is '
              'handed an event, as before');
    });

    test('a calendar file is copied in as a share is, under the same checks',
        () {
      final take = RegExp(r'private fun takeCalendar\([\s\S]*?\n    }')
          .firstMatch(bridge)
          ?.group(0);
      expect(take, isNotNull);
      expect(take, contains('Intent.ACTION_VIEW'));
      expect(take, contains('copyInBackground(listOf(data))'),
          reason: 'copyIn, and mayCopyIn before it, as for any share');
      expect(take, contains('"calendarFile"'));
      expect(take, contains('"calendarLink"'));
      expect(take, isNot(contains('openInputStream')));
      final share = RegExp(r'fun takeShare\([\s\S]*?\n    }')
          .firstMatch(bridge)!
          .group(0)!;
      expect(share, contains('if (takeCalendar(intent, pushNow)) return'));
    });
  });
}

/// Let the sample engine's small delays and any disk reads pass, then draw.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Add pressed on the event called [title].
Future<void> tapAdd(WidgetTester tester, String title) async {
  final card = find.ancestor(
    of: find.text(title),
    matching: find.byKey(const ValueKey('calendar-file-event')),
  );
  final add = find.descendant(
    of: card,
    matching: find.byKey(const ValueKey('calendar-file-add')),
  );
  await tester.ensureVisible(add);
  await tester.pumpAndSettle();
  await tester.tap(add);
  await settle(tester);
}
