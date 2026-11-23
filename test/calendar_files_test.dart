import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/calendar/internet_calendars.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart' show ConnectionFailed;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_files.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/internet_calendar.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting.dart';
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

    testWidgets('a series says nothing more where it goes whole',
        (tester) async {
      await pumpCard(tester, weekly);
      expect(find.textContaining('not copied'), findsNothing);
      expect(find.textContaining('Only the first'), findsNothing);
    });

    testWidgets('before Add to calendar, it says the dates it leaves out or '
        'moves are not copied', (tester) async {
      for (final ics in [
        weekly.replaceFirst(
            'END:VEVENT', 'EXDATE:20261223T120000Z\r\nEND:VEVENT'),
        weekly.replaceFirst(
          'END:VCALENDAR',
          'BEGIN:VEVENT\r\nUID:sync@example.com\r\n'
              'RECURRENCE-ID:20261209T120000Z\r\nSUMMARY:Weekly sync\r\n'
              'DTSTART:20261210T120000Z\r\nDTEND:20261210T123000Z\r\n'
              'END:VEVENT\r\nEND:VCALENDAR',
        ),
      ]) {
        await pumpCard(tester, ics);
        expect(find.textContaining('not copied'), findsOneWidget);
        expect(tester.getTopLeft(find.textContaining('not copied')).dy,
            lessThan(tester.getTopLeft(find.text('Add to calendar')).dy));
      }
    });

    testWidgets('and where the phone cannot be given its repeat, that only '
        'the first meeting goes', (tester) async {
      await pumpCard(
          tester, weekly.replaceFirst('BYDAY=WE;', 'BYDAY=WE;BYHOUR=12;'));
      expect(find.textContaining('Only the first meeting'), findsOneWidget);
      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();
      expect(phone.inserted.single.rule, isNull);
    });
  });

  // What the review of #67 found in the reading (calendar-ideas-2,
  // reviews/h3.json), each pinned here.
  group('reading a calendar file', () {
    FileEvent only(String text) => CalendarFile.read(text)!.events.single;

    String london(String day, {String rule = 'FREQ=WEEKLY;BYDAY=TH'}) =>
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:$day\r\nSUMMARY:London\r\n'
        'DTSTART;TZID=Europe/London:${day}T100000\r\n'
        'DTEND;TZID=Europe/London:${day}T110000\r\n'
        '${rule.isEmpty ? '' : 'RRULE:$rule\r\n'}'
        'END:VEVENT\r\nEND:VCALENDAR';

    test('a series set in a zone the phone knows goes on that zone\'s clock, '
        'to a Microsoft and to a Google calendar', () {
      final series = only(london('20261203'));
      final draft = series.draftFor(
        accountId: 'a',
        calendarId: CalendarEvent.mainCalendar,
        timeZone: 'America/New_York',
      );
      expect(draft.start, DateTime(2026, 12, 3, 10));
      expect(draft.end, DateTime(2026, 12, 3, 11));
      expect(draft.timeZone, 'Europe/London');
      expect(draft.recurrence?.kind, RepeatKind.weekly);
      expect(draft.recurrence?.days, {DateTime.thursday});
      final graph = GraphCalendarApi.eventJson(draft);
      expect(graph['start'],
          {'dateTime': '2026-12-03T10:00:00', 'timeZone': 'Europe/London'});
      expect(graph['end'],
          {'dateTime': '2026-12-03T11:00:00', 'timeZone': 'Europe/London'});
      final google = GoogleCalendarApi.eventJson(draft);
      expect((google['start'] as Map)['dateTime'], startsWith('2026-12-03T10:00'));
      expect((google['start'] as Map)['timeZone'], 'Europe/London');
    });

    test('one on its own goes at its instant on the phone\'s clock, as '
        'before', () {
      final single = only(london('20261203', rule: ''));
      final draft = single.draftFor(
        accountId: 'a',
        calendarId: CalendarEvent.mainCalendar,
        timeZone: 'Asia/Jerusalem',
      );
      expect(draft.start, DateTime.utc(2026, 12, 3, 10).toLocal());
      expect(draft.timeZone, 'Asia/Jerusalem');
    });

    test("a zone the phone does not know is read from the file's own "
        'definition of it (Q3)', () {
      const text = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VTIMEZONE\r\nTZID:Customized Time Zone\r\n'
          'BEGIN:STANDARD\r\nDTSTART:16011028T020000\r\n'
          'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n'
          'TZOFFSETFROM:+0300\r\nTZOFFSETTO:+0200\r\nEND:STANDARD\r\n'
          'BEGIN:DAYLIGHT\r\nDTSTART:16010325T020000\r\n'
          'RRULE:FREQ=YEARLY;BYDAY=-1FR;BYMONTH=3\r\n'
          'TZOFFSETFROM:+0200\r\nTZOFFSETTO:+0300\r\nEND:DAYLIGHT\r\n'
          'END:VTIMEZONE\r\n'
          'BEGIN:VEVENT\r\nUID:x\r\nSUMMARY:Board\r\n'
          'DTSTART;TZID="Customized Time Zone":20261203T100000\r\n'
          'DTEND;TZID="Customized Time Zone":20261203T110000\r\n'
          'END:VEVENT\r\nEND:VCALENDAR\r\n';
      final e = only(text);
      expect(e.event.start.toUtc(), DateTime.utc(2026, 12, 3, 8));
      expect(e.event.start.add(e.event.length).toUtc(),
          DateTime.utc(2026, 12, 3, 9));
      expect(e.zoneUnknown, isFalse);
      // In summer, by the same definition: 10:00 at +03:00.
      expect(only(text.replaceAll('20261203', '20260702')).event.start.toUtc(),
          DateTime.utc(2026, 7, 2, 7));
    });

    test('one it does not define either is read as written, and says so',
        () {
      final e = only('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\n'
          'SUMMARY:Board\r\nDTSTART;TZID=Somewhere Else:20261203T100000\r\n'
          'END:VEVENT\r\nEND:VCALENDAR');
      expect(e.zoneUnknown, isTrue);
      expect(e.start, DateTime(2026, 12, 3, 10));
    });

    testWidgets('its row says so before Add', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('elsewhere.ics',
            text: 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\n'
                'SUMMARY:Board\r\n'
                'DTSTART;TZID=Somewhere Else:20261203T100000\r\n'
                'END:VEVENT\r\nEND:VCALENDAR'),
        calendarOpened: true,
      ));
      expect(find.textContaining('time zone is one MyEmail does not know'),
          findsOneWidget);
    });

    test('folded lines are put back together, and quickly however many',
        () {
      final long = StringBuffer('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n'
          'UID:f\r\nSUMMARY:Folded\r\nDTSTART:20261203T120000Z\r\n'
          'DESCRIPTION:x');
      for (var i = 0; i < 300; i++) {
        long.write('\r\n y$i');
      }
      long.write('\r\nEND:VEVENT\r\nEND:VCALENDAR');
      final description = only(long.toString()).event.description;
      expect(description, startsWith('xy0y1y2'));
      expect(description, endsWith('y298y299'));

      final huge = StringBuffer('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n'
          'UID:h\r\nDTSTART:20261203T120000Z\r\nDESCRIPTION:x');
      while (huge.length < 1024 * 1024) {
        huge.write('\r\n y');
      }
      huge.write('\r\nEND:VEVENT\r\nEND:VCALENDAR');
      final took = Stopwatch()..start();
      expect(CalendarFile.read(huge.toString()), isNotNull);
      took.stop();
      // 7.8 s on this PC before (each line added to a growing string).
      expect(took.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a count past 999 cannot be copied, to a calendar or the phone',
        () {
      FileEvent counted(int n) => only('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n'
          'UID:c\r\nSUMMARY:Daily\r\nDTSTART:20261203T120000Z\r\n'
          'RRULE:FREQ=DAILY;COUNT=$n\r\nEND:VEVENT\r\nEND:VCALENDAR');
      expect(counted(999).repeatKept, isTrue);
      expect(counted(999).phoneRuleKept, isTrue);
      expect(counted(1000).repeatKept, isFalse);
      expect(counted(1000).phoneRuleKept, isFalse);
      expect(counted(100000).repeat, isNull);
    });

    test('an hour past 23, or a day that is none, is not read', () {
      for (final at in ['20261203T990000Z', '20261203T246000', '20261340']) {
        expect(
          CalendarFile.read('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:b\r\n'
              'SUMMARY:Odd\r\nDTSTART:$at\r\nEND:VEVENT\r\nEND:VCALENDAR'),
          isNull,
          reason: at,
        );
      }
    });

    testWidgets('an Add tried again on another calendar is a new meeting, '
        'not the first answered again', (tester) async {
      final failing = _FailingOnce();
      engine = failing;
      final (c, hadco) = await pumpOpened(tester, SharedContent(
        calendarFile: aFile('school.ics', text: school),
        calendarOpened: true,
      ));
      await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Gmail',
            emailAddress: 'ron@gmail.example',
            provider: MailProvider.gmail,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          ));
      c.invalidate(accountsProvider);
      await settle(tester);

      await tapAdd(tester, "Parents' evening");
      failing.failNext = true;
      await tapAdd(tester, "Parents' evening");
      expect(failing.tried, hasLength(2));
      expect(failing.tried.map((d) => d.accountId), [hadco.id, hadco.id]);
      expect(failing.tried[1].transactionId, failing.tried[0].transactionId,
          reason: 'tried again on the same calendar: the same key, so a '
              'meeting made after all is not made twice');

      await tester.tap(find.byKey(const ValueKey('calendar-file-target')));
      await settle(tester);
      await tester.tap(find.text('Gmail').last);
      await settle(tester);
      await tapAdd(tester, "Parents' evening");
      expect(failing.tried, hasLength(3));
      expect(failing.tried[2].accountId, isNot(hadco.id));
      expect(failing.tried[2].transactionId,
          isNot(failing.tried[0].transactionId));
      expect(find.text('Added to Gmail'), findsOneWidget);
    });

    testWidgets('the list opens at the first event from today on, the ones '
        'before it above', (tester) async {
      final today = DateTime.now();
      String day(int fromToday) {
        final d = DateTime(today.year, today.month, today.day + fromToday);
        return '${d.year}${d.month.toString().padLeft(2, '0')}'
            '${d.day.toString().padLeft(2, '0')}';
      }

      final text = StringBuffer('BEGIN:VCALENDAR\r\n');
      for (var i = 40; i >= 1; i--) {
        text.write('BEGIN:VEVENT\r\nUID:p$i\r\nSUMMARY:Past $i\r\n'
            'DTSTART;VALUE=DATE:${day(-i)}\r\nEND:VEVENT\r\n');
      }
      for (final i in [1, 2]) {
        text.write('BEGIN:VEVENT\r\nUID:n$i\r\nSUMMARY:Next $i\r\n'
            'DTSTART;VALUE=DATE:${day(i)}\r\nEND:VEVENT\r\n');
      }
      text.write('END:VCALENDAR\r\n');
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('long.ics', text: text.toString()),
        calendarOpened: true,
      ));

      expect(find.text('Next 1').hitTestable(), findsOneWidget);
      expect(find.text('Past 40').hitTestable(), findsNothing);
      expect(find.byKey(const ValueKey('calendar-file-target')).hitTestable(),
          findsOneWidget, reason: 'where they go stays in sight');
      await tester.drag(find.text('Next 1'), const Offset(0, 400));
      await settle(tester);
      expect(find.text('Past 1').hitTestable(), findsOneWidget);
    });

    testWidgets('a series still running counts as from today, however long '
        'ago it began', (tester) async {
      final today = DateTime.now();
      String day(int fromToday) {
        final d = DateTime(today.year, today.month, today.day + fromToday);
        return '${d.year}${d.month.toString().padLeft(2, '0')}'
            '${d.day.toString().padLeft(2, '0')}';
      }

      final text = StringBuffer('BEGIN:VCALENDAR\r\n')
        ..write('BEGIN:VEVENT\r\nUID:w\r\nSUMMARY:Weekly class\r\n'
            'DTSTART;VALUE=DATE:${day(-70)}\r\nRRULE:FREQ=WEEKLY\r\n'
            'END:VEVENT\r\n')
        ..write('BEGIN:VEVENT\r\nUID:t\r\nSUMMARY:Term club\r\n'
            'DTSTART;VALUE=DATE:${day(-60)}\r\n'
            'RRULE:FREQ=WEEKLY;UNTIL=${day(20)}\r\nEND:VEVENT\r\n')
        ..write('BEGIN:VEVENT\r\nUID:e\r\nSUMMARY:Ended club\r\n'
            'DTSTART;VALUE=DATE:${day(-65)}\r\n'
            'RRULE:FREQ=WEEKLY;COUNT=3\r\nEND:VEVENT\r\n');
      for (var i = 40; i >= 1; i--) {
        text.write('BEGIN:VEVENT\r\nUID:p$i\r\nSUMMARY:Past $i\r\n'
            'DTSTART;VALUE=DATE:${day(-i)}\r\nEND:VEVENT\r\n');
      }
      text.write('BEGIN:VEVENT\r\nUID:n\r\nSUMMARY:Next 1\r\n'
          'DTSTART;VALUE=DATE:${day(2)}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n');
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('club.ics', text: text.toString()),
        calendarOpened: true,
      ));

      expect(find.text('Weekly class').hitTestable(), findsOneWidget,
          reason: 'no end: still running');
      expect(find.text('Term club').hitTestable(), findsOneWidget,
          reason: 'its end is still to come');
      expect(find.text('Next 1').hitTestable(), findsOneWidget);
      expect(find.text('Ended club').hitTestable(), findsNothing,
          reason: 'its three meetings are over');
      expect(find.text('Past 1').hitTestable(), findsNothing);
      expect(
        tester.getTopLeft(find.text('Weekly class')).dy,
        lessThan(tester.getTopLeft(find.text('Next 1')).dy),
        reason: 'from today, in the order they began',
      );
    });

    test('whether a series still runs on a day', () {
      FileEvent one(String rule) => CalendarFile.read(
              'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nSUMMARY:A\r\n'
              'DTSTART:20260901T090000Z\r\nDTEND:20260901T100000Z\r\n'
              '${rule.isEmpty ? '' : 'RRULE:$rule\r\n'}'
              'END:VEVENT\r\nEND:VCALENDAR')!
          .events
          .single;
      final day = DateTime(2026, 12, 1);
      expect(one('').runsOnOrAfter(day), isFalse);
      expect(one('FREQ=WEEKLY').runsOnOrAfter(day), isTrue);
      expect(one('FREQ=WEEKLY;UNTIL=20261215T000000Z').runsOnOrAfter(day),
          isTrue);
      expect(one('FREQ=WEEKLY;UNTIL=20261110T000000Z').runsOnOrAfter(day),
          isFalse);
      expect(one('FREQ=DAILY;COUNT=200').runsOnOrAfter(day), isTrue);
      expect(one('FREQ=DAILY;COUNT=20').runsOnOrAfter(day), isFalse);
      expect(one('FREQ=HOURLY').runsOnOrAfter(day), isFalse,
          reason: 'a rule not read is its first meeting alone');
    });
  });

  // What comes in from outside, after the review of #67.
  group('what comes in from outside', () {
    testWidgets('a file too large is said to be, and not read',
        (tester) async {
      await pumpOpened(
        tester,
        SharedContent.fromMap({'calendarOpened': true, 'calendarTooLarge': true}),
      );
      expect(find.text('That calendar file is too large for MyEmail to read.'),
          findsOneWidget);
      expect(find.byType(CalendarFileScreen), findsNothing);
    });

    testWidgets("Android's copy of a file is let go once it has been read",
        (tester) async {
      final copy = Directory('${temp.path}/incoming/1f2e3d')
        ..createSync(recursive: true);
      final file = File('${copy.path}/school.ics')..writeAsStringSync(school);
      await pumpOpened(tester, SharedContent(
        calendarFile: IncomingFile(
          path: file.path,
          name: 'school.ics',
          mimeType: 'text/calendar',
          sizeBytes: file.lengthSync(),
        ),
        calendarOpened: true,
      ));
      expect(find.text('Swimming'), findsOneWidget);
      expect(copy.existsSync(), isFalse);
    });

    test('a link with a user part before its host is no calendar link', () {
      for (final link in [
        'webcal://calendar.google.com@evil.example/feed.ics',
        'webcal://user:secret@example.com/feed.ics',
      ]) {
        expect(calendarLinkIn(link), isNull, reason: link);
        expect(feedUrlOf(link), isNull, reason: link);
      }
      expect(feedUrlOf('webcal://example.com/feed.ics'),
          'https://example.com/feed.ics');
    });

    testWidgets('and one handed in says where it is from, above the link',
        (tester) async {
      await pumpOpened(
        tester,
        SharedContent.fromMap({
          'calendarLink': 'webcal://calendar.example.org/school/'
              'a-very-long-path/that-goes-on/terms.ics',
          'calendarOpened': true,
        }),
      );
      expect(find.text('From calendar.example.org'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('From calendar.example.org')).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('internet-calendar-link')))
            .dy),
      );
    });

    testWidgets('one refused is said to be', (tester) async {
      await pumpOpened(
        tester,
        SharedContent.fromMap({
          'calendarLink': 'webcal://calendar.google.com@evil.example/f.ics',
          'calendarOpened': true,
        }),
      );
      expect(find.text('Add from a link'), findsNothing);
      expect(find.textContaining('does not open that link'), findsOneWidget);
    });
  });

  group('the reader of calendars from links', () {
    late Directory kept;

    setUp(() => kept = Directory.systemTemp.createTempSync('myemail-links'));
    tearDown(() => kept.deleteSync(recursive: true));

    const calendar = InternetCalendar(
      id: 'c1',
      name: 'Team',
      url: 'https://example.com/team.ics',
      colour: 0xFF8E24AA,
    );

    test('stops reading past 4 MB, and says so', () async {
      var given = 0;
      final client = http_testing.MockClient.streaming((request, _) async {
        Stream<List<int>> endless() async* {
          final chunk = List.filled(64 * 1024, 0x41);
          yield 'BEGIN:VCALENDAR\r\n'.codeUnits;
          while (true) {
            given += chunk.length;
            yield chunk;
          }
        }

        return http.StreamedResponse(endless(), 200);
      });
      final reader =
          FileInternetCalendars(client: client, folder: () async => kept);
      await expectLater(
        reader.read(calendar),
        throwsA(isA<FeedUnreadable>()
            .having((e) => e.message, 'message', contains('too large'))),
      );
      expect(given, lessThan(6 * 1024 * 1024),
          reason: 'not read to the end, which there is none of');
      expect(await reader.kept(calendar), isNull);
    });

    test('reads one of a fair size, off the UI isolate, and keeps it',
        () async {
      final client = http_testing.MockClient(
          (request) async => http.Response(school, 200));
      final reader =
          FileInternetCalendars(client: client, folder: () async => kept);
      final feed = await reader.read(calendar);
      expect(feed.name, "Ella's school");
      expect(feed.events, hasLength(3));
      final again = FileInternetCalendars(folder: () async => kept);
      expect((await again.kept(calendar))?.feed.events, hasLength(3));
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
      expect(files.single, contains('android:mimeType="application/ics"'));
      expect(files.single, contains('android:mimeType="text/x-vcalendar"'),
          reason: 'how some apps hand an .ics over');
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
      expect(take, contains('copyInBackground(listOf(data), CALENDAR_LARGEST)'),
          reason: 'copyIn, and mayCopyIn before it, as for any share');
      expect(take, contains('"calendarFile"'));
      expect(take, contains('"calendarTooLarge"'));
      expect(bridge, contains('private fun copyAtMost('),
          reason: 'a calendar is copied no further than 4 MB');
      expect(
        RegExp(r'CALENDAR_TYPES = setOf\(([^)]*)\)').firstMatch(bridge)?[1],
        allOf(contains('"text/calendar"'), contains('"application/ics"'),
            contains('"text/x-vcalendar"')),
      );
      expect(take, contains('"calendarLink"'));
      expect(take, isNot(contains('openInputStream')));
      final share = RegExp(r'fun takeShare\([\s\S]*?\n    }')
          .firstMatch(bridge)!
          .group(0)!;
      expect(share, contains('if (takeCalendar(intent, pushNow)) return'));
    });
  });

  // An event the file or the invitation shows as free (TRANSP:TRANSPARENT,
  // a school's holidays, an office closed) went to the calendar as busy:
  // the calendars take an event that says nothing as busy, so Ron was busy
  // all day to his colleagues and in Insert free times.
  group('an event shown as free', () {
    const holidays = 'BEGIN:VCALENDAR\r\n'
        "X-WR-CALNAME:Ella's school\r\n"
        'BEGIN:VEVENT\r\n'
        'UID:break@example.com\r\n'
        'SUMMARY:Winter break\r\n'
        'DTSTART;VALUE=DATE:20261221\r\n'
        'DTEND;VALUE=DATE:20261222\r\n'
        'TRANSP:TRANSPARENT\r\n'
        'END:VEVENT\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:play@example.com\r\n'
        'SUMMARY:School play\r\n'
        'DTSTART:20261218T150000Z\r\n'
        'DTEND:20261218T163000Z\r\n'
        'TRANSP:OPAQUE\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';

    FileEvent named(String title) => CalendarFile.read(holidays)!
        .events
        .singleWhere((e) => e.title == title);

    test('goes to a calendar as free; one busy says nothing, as before', () {
      final free = named('Winter break').draftFor(
        accountId: 'a',
        calendarId: CalendarEvent.mainCalendar,
        timeZone: 'Asia/Jerusalem',
      );
      expect(free.allDay, isTrue);
      expect(free.showAs, EventShowAs.free);
      expect(GraphCalendarApi.eventJson(free)['showAs'], 'free');
      expect(GoogleCalendarApi.eventJson(free)['transparency'], 'transparent');

      final busy = named('School play').draftFor(
        accountId: 'a',
        calendarId: CalendarEvent.mainCalendar,
        timeZone: 'Asia/Jerusalem',
      );
      expect(busy.showAs, isNull, reason: "the calendar's own way stands");
      expect(GraphCalendarApi.eventJson(busy).containsKey('showAs'), isFalse);
    });

    testWidgets('Add keeps it free on a calendar', (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('holidays.ics', text: holidays),
        calendarOpened: true,
      ));

      await tapAdd(tester, 'Winter break');
      expect(engine.meetings.single.showAs, EventShowAs.free);
      await tapAdd(tester, 'School play');
      expect(engine.meetings.last.showAs, isNull);
    });

    testWidgets("and in the phone's calendar app", (tester) async {
      await pumpOpened(tester, SharedContent(
        calendarFile: aFile('holidays.ics', text: holidays),
        calendarOpened: true,
      ));

      await tester.tap(find.byKey(const ValueKey('calendar-file-target')));
      await settle(tester);
      await tester.tap(
          find.byKey(const ValueKey('calendar-file-target:phone')).last);
      await settle(tester);
      await tapAdd(tester, 'Winter break');
      expect(phone.inserted.single.free, isTrue);
      expect(phone.inserted.single.allDay, isTrue);
      await tapAdd(tester, 'School play');
      expect(phone.inserted.last.free, isFalse);
    });

    String notice(String status) => 'BEGIN:VCALENDAR\r\n'
        'METHOD:REQUEST\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:closed@example.com\r\n'
        'SUMMARY:Office closed\r\n'
        'DTSTART;VALUE=DATE:20261224\r\n'
        'DTEND;VALUE=DATE:20261225\r\n'
        '$status'
        'ORGANIZER:mailto:hr@example.com\r\n'
        'ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:ron@example.com\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';

    test("an invitation's free is read: TRANSP, or Outlook's intended "
        'status where it gives one', () {
      bool? freeOf(String status) =>
          CalendarInvite.parse(notice(status))?.free;
      expect(freeOf('TRANSP:TRANSPARENT\r\n'), isTrue);
      expect(freeOf('TRANSP:OPAQUE\r\n'), isFalse);
      expect(freeOf(''), isFalse);
      expect(
          freeOf('TRANSP:OPAQUE\r\nX-MICROSOFT-CDO-INTENDEDSTATUS:FREE\r\n'),
          isTrue);
      expect(
          freeOf('TRANSP:TRANSPARENT\r\n'
              'X-MICROSOFT-CDO-INTENDEDSTATUS:BUSY\r\n'),
          isFalse,
          reason: 'what Outlook means the invited to show as comes first');
      expect(freeOf('TRANSP:nonsense\r\n'), isFalse);
    });

    testWidgets("an invitation's Add to calendar keeps it free",
        (tester) async {
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(phone),
      ]);
      addTearDown(c.dispose);
      for (final (status, free) in [
        ('TRANSP:TRANSPARENT\r\n', true),
        ('TRANSP:OPAQUE\r\n', false),
      ]) {
        await tester.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: InviteCard(
                key: ValueKey(status),
                message: MailMessage(
                  id: 'acct-personal:INBOX#2',
                  accountId: 'acct-personal',
                  folderId: 'acct-personal:INBOX',
                  uid: 2,
                  subject: 'Office closed',
                  from: const MailAddress(email: 'hr@example.com'),
                  to: const [MailAddress(email: 'ron@example.com')],
                  date: DateTime(2026, 11, 20),
                  preview: '',
                ),
                invite: CalendarInvite.parse(notice(status))!,
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to calendar'));
        await tester.pumpAndSettle();
        expect(phone.inserted.last.free, free, reason: status);
      }
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
  // A file is read off the UI's isolate, in real time.
  for (var i = 0;
      i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// The sample engine whose next create fails as an answer that never
/// came does, with each create asked kept.
class _FailingOnce extends SampleMailEngine {
  final List<MeetingDraft> tried = [];
  bool failNext = true;

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    tried.add(meeting);
    if (failNext) {
      failNext = false;
      throw const ConnectionFailed('The answer never came.');
    }
    return super.createMeeting(meeting);
  }
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
