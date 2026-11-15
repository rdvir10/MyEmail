import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart' show ConnectionFailed;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart' show EventNotes;
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/text_links.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show CalendarScreen, showEventDetails;
import 'package:myemail/ui/calendar/event_notes.dart'
    show ShownNotes, notesAsShown;
import 'package:myemail/ui/calendar/my_day_pane.dart';
import 'package:myemail/ui/compose/compose_screen.dart' show ComposeScreen;

import 'fakes/fake_webview.dart';

/// A meeting's sheet: the whole of its notes, with what they link to a
/// tap away (calendar idea #43), and its place a tap from directions,
/// there, in My Day and on an invitation's card (#40).
void main() {
  setUpAll(FakeWebViewPlatform.install);

  /// What links open, kept instead of opened; [answer] is what the phone
  /// says to each.
  List<String> catchLaunches(
    WidgetTester tester, {
    bool Function(String url)? answer,
  }) {
    final opened = <String>[];
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      launcher,
      (call) async {
        final url = '${(call.arguments as Map)['url']}';
        opened.add(url);
        return answer?.call(url) ?? true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, null));
    return opened;
  }

  group('links in plain text', () {
    List<String> words(String text) => [
          for (final l in linksInText(text)) text.substring(l.start, l.end),
        ];
    List<String> targets(String text) =>
        [for (final l in linksInText(text)) '${l.target}'];

    test('web addresses, without the full stop or bracket of their '
        "sentence; over plain http too, as a message's links are", () {
      const text = 'The deck: https://hadco.example/q3?view=all. Or '
          'www.hadco.example/q3, (https://hadco.example/q4).';
      expect(words(text), [
        'https://hadco.example/q3?view=all',
        'www.hadco.example/q3',
        'https://hadco.example/q4',
      ]);
      expect(targets(text), [
        'https://hadco.example/q3?view=all',
        'https://www.hadco.example/q3',
        'https://hadco.example/q4',
      ]);
      expect(targets('Old: http://old.example/x or http://www.old.example.'),
          ['http://old.example/x', 'http://www.old.example']);
      expect(
          words('Click here to join the meeting'
              '<https://teams.microsoft.com/l/meetup-join/x>'),
          ['https://teams.microsoft.com/l/meetup-join/x']);
    });

    test("email addresses, to write to; one in a web address is the "
        "address's", () {
      expect(targets('Write to dana.levi@hadco.example, or to me.'),
          ['mailto:dana.levi@hadco.example']);
      expect(words('See https://hadco.example/?to=dana@hadco.example now'),
          ['https://hadco.example/?to=dana@hadco.example']);
    });

    test('phone numbers, with the code a dial-in takes after them; not a '
        'meeting ID, a passcode, a date or a time', () {
      expect(targets('+1 469-555-0123,,123456789# United States, Dallas'),
          ['tel:+14695550123,,123456789%23']);
      expect(targets('+16465588656,,81234567890#,,,,*123456# US (New York)'),
          ['tel:+16465588656,,81234567890%23,,,,*123456%23']);
      expect(targets('Mobile 054-555-1234, office (555) 123-4567'),
          ['tel:0545551234', 'tel:5551234567']);
      expect(
          linksInText('Meeting ID: 244 810 212 347\nPasscode: 7aP9Rv\n'
              'On 2026-11-17, 10:00–11:00'),
          isEmpty);
    });
  });

  late _NotesEngine engine;
  late Account hadco;
  CalendarEvent? showing;
  Account? showingAccount;

  /// [home] over Hadco's calendar, [events] on it: by default a button
  /// that opens the sheet of the meeting [open] names.
  Future<void> host(
    WidgetTester tester, {
    Widget? home,
    DateTime? clock,
    List<CalendarEvent> Function(Account hadco)? events,
    Size size = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    engine = _NotesEngine();
    hadco = (await tester.runAsync(() => engine.addOAuthAccount(
          displayName: 'Hadco',
          emailAddress: 'ron@hadco.example',
          provider: MailProvider.outlook,
          token: OAuthToken(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.utc(2030),
          ),
        )))!;
    if (events != null) engine.events[hadco.id] = events(hadco);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(
          FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      if (clock != null) meetingClockProvider.overrideWithValue(() => clock),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: home ??
            Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Center(
                  child: TextButton(
                    key: const ValueKey('open-sheet'),
                    onPressed: () => showEventDetails(
                        context, ref, showing!, showingAccount),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  CalendarEvent meeting({
    String preview = '',
    String location = '',
    String? accountId,
    DateTime? start,
    int people = 0,
  }) {
    final at = start ?? DateTime(2026, 11, 17, 14);
    return CalendarEvent(
      id: 'm',
      accountId: accountId ?? hadco.id,
      title: 'Supplier call',
      start: at,
      end: at.add(const Duration(hours: 1)),
      location: location,
      organizer: const MailAddress(email: 'dana@hadco.example', name: 'Dana'),
      attendees: [
        for (var i = 1; i <= people; i++)
          EventAttendee(
              MailAddress(email: 'guest$i@hadco.example', name: 'Guest $i')),
      ],
      preview: preview,
    );
  }

  /// [event]'s sheet, from Hadco's calendar, or a calendar from a link.
  Future<void> open(
    WidgetTester tester,
    CalendarEvent event, {
    bool fromLink = false,
    bool settle = true,
  }) async {
    showing = event;
    showingAccount = fromLink ? null : hadco;
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group("the whole of a meeting's notes on its sheet (#43)", () {
    void close(WidgetTester tester) => Navigator.of(
            tester.element(find.byKey(const ValueKey('event-notes'))))
        .pop();

    testWidgets('the first lines at once, then the whole of them, asked for '
        'once each time the sheet opens', (tester) async {
      await host(tester);
      const first = 'Agenda: the numbers for Q3, then the plan for Q4.';
      engine.eventNotesOf['m'] = const EventNotes(
          text: '$first\nThe deck: https://hadco.example/q3\n'
              'Dial in: +1 469-555-0123');

      await open(tester, meeting(preview: first), settle: false);
      expect(find.textContaining(first), findsOneWidget);
      expect(find.textContaining('The deck'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.textContaining('The deck: https://hadco.example/q3'),
          findsOneWidget);
      expect(engine.eventNotesAsked, 1);

      close(tester);
      await tester.pumpAndSettle();
      await open(tester, meeting(preview: first));
      expect(engine.eventNotesAsked, 2);
    });

    testWidgets('on a phone, notes scrolled out of a long sheet and back are '
        'not asked for again, and Show more stays as it was left',
        (tester) async {
      await host(tester, size: const Size(400, 800));
      final lines = [for (var i = 1; i <= 40; i++) 'Point $i of the agenda'];
      engine.eventNotesOf['m'] = EventNotes(text: lines.join('\n'));
      await open(tester, meeting(preview: lines.first, people: 30));
      final sheet = find.byType(ListView).last;
      final more = find.byKey(const ValueKey('linked-text-more'));

      await tester.dragUntilVisible(more, sheet, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(engine.eventNotesAsked, 1);

      // Up to the answers and Join, the notes far out of sight, and down.
      await tester.dragUntilVisible(
          find.text('Supplier call'), sheet, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Point 40 of the agenda', skipOffstage: false),
          findsOneWidget,
          reason: 'kept while out of sight');
      await tester.dragUntilVisible(more, sheet, const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(engine.eventNotesAsked, 1);
      expect(find.descendant(of: more, matching: find.text('Show less')),
          findsOneWidget);
    });

    testWidgets('its web addresses, phone numbers and email addresses are a '
        'tap away', (tester) async {
      await host(tester);
      final opened = catchLaunches(tester);
      engine.eventNotesOf['m'] = const EventNotes(
          text: 'The deck: https://hadco.example/q3\n'
              'Last year: http://old.example/q3\n'
              'Dial in: +1 469-555-0123\n'
              'Questions to dana@hadco.example');
      await open(tester, meeting(preview: 'The deck'));

      await tester
          .tapOnText(find.textRange.ofSubstring('https://hadco.example/q3'));
      await tester.pump();
      await tester
          .tapOnText(find.textRange.ofSubstring('http://old.example/q3'));
      await tester.pump();
      await tester.tapOnText(find.textRange.ofSubstring('+1 469-555-0123'));
      await tester.pump();
      expect(opened, [
        'https://hadco.example/q3',
        'http://old.example/q3',
        'tel:+14695550123',
      ]);

      await tester.tapOnText(find.textRange.ofSubstring('dana@hadco.example'));
      await tester.pumpAndSettle();
      final compose = tester.widget<ComposeScreen>(find.byType(ComposeScreen));
      expect([for (final a in compose.draft.to) a.email],
          ['dana@hadco.example']);
      expect(compose.draft.accountId, hadco.id);
      expect(find.byKey(const ValueKey('event-notes')), findsNothing,
          reason: 'the sheet closes for a message, as for its others');
    });

    testWidgets('long notes fold after twelve lines under Show more',
        (tester) async {
      await host(tester);
      final lines = [for (var i = 1; i <= 40; i++) 'Point $i of the agenda'];
      engine.eventNotesOf['m'] = EventNotes(text: lines.join('\n'));
      await open(tester, meeting(preview: lines.take(5).join(' ')));

      Text notes() =>
          tester.widget<Text>(find.byKey(const ValueKey('linked-text')));
      final more = find.byKey(const ValueKey('linked-text-more'));
      expect(notes().maxLines, 12);
      expect(find.descendant(of: more, matching: find.text('Show more')),
          findsOneWidget);

      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(notes().maxLines, isNull);
      expect(find.descendant(of: more, matching: find.text('Show less')),
          findsOneWidget);
    });

    testWidgets("Teams' block goes under the notes, its dial-in a tap away",
        (tester) async {
      await host(tester);
      final opened = catchLaunches(tester);
      engine.eventNotesOf['m'] = const EventNotes(
        text: 'Agenda: the numbers',
        keptBelow: '<div><span>_______________________________________'
            '_________________________________________</span></div>'
            '<div><b>Microsoft Teams meeting</b></div>'
            '<div>Or call in (audio only)</div>'
            '<div><a href="tel:+14695550123,,123456789#">+1 469-555-0123,,'
            '123456789#</a> United States, Dallas</div>'
            '<div>Phone Conference ID: 123 456 789#</div>',
      );
      await open(tester, meeting(preview: 'Agenda: the numbers ____'));

      expect(find.textContaining('Microsoft Teams meeting'), findsOneWidget);
      expect(find.textContaining('____'), findsNothing);
      await tester.tapOnText(
          find.textRange.ofSubstring('+1 469-555-0123,,123456789#'));
      await tester.pump();
      expect(opened, ['tel:+14695550123,,123456789%23']);
    });

    testWidgets("an outside Teams invitation's rule of underscores is not "
        'shown', (tester) async {
      await host(tester);
      engine.eventNotesOf['m'] = EventNotes(
          text: 'Agenda: the numbers\n\n${'_' * 80}\n'
              'Microsoft Teams meeting\nMeeting ID: 244 810 212 347\n'
              '${'_' * 80}');
      await open(tester, meeting(preview: 'Agenda: the numbers'));

      expect(find.textContaining('Meeting ID: 244 810 212 347'),
          findsOneWidget);
      expect(find.textContaining('____'), findsNothing);
    });

    testWidgets('Hebrew notes read from the right', (tester) async {
      await host(tester);
      engine.eventNotesOf['m'] =
          const EventNotes(text: 'סדר היום: המספרים של הרבעון');
      await open(tester, meeting(preview: 'סדר היום'));

      final notes =
          tester.widget<Text>(find.byKey(const ValueKey('linked-text')));
      expect(notes.textDirection, TextDirection.rtl);
      expect(find.textContaining('המספרים של הרבעון'), findsOneWidget);
    });

    testWidgets('a calendar that does not answer leaves the first lines, and '
        'says nothing of it', (tester) async {
      await host(tester);
      engine.notesFailure = const ConnectionFailed('No connection.');
      await open(tester, meeting(preview: 'Agenda: the numbers'));

      expect(engine.eventNotesAsked, 1);
      expect(find.textContaining('Agenda: the numbers'), findsOneWidget);
      expect(find.textContaining('connection'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a calendar from a link shows the first lines it has, and is '
        'asked for nothing', (tester) async {
      await host(tester);
      await open(
        tester,
        meeting(preview: 'Gates open at nine.', accountId: 'internet:fair'),
        fromLink: true,
      );

      expect(find.textContaining('Gates open at nine.'), findsOneWidget);
      expect(engine.eventNotesAsked, 0);
    });

    testWidgets('a meeting with no notes shows none, and asks for none',
        (tester) async {
      await host(tester);
      await open(tester, meeting());

      expect(find.byKey(const ValueKey('event-notes')), findsNothing);
      expect(find.text('Supplier call'), findsOneWidget);
      expect(engine.eventNotesAsked, 0);
    });
  });

  group('links written as words in HTML notes (#43)', () {
    const deck = 'https://hadco.sharepoint.com/q3.pptx?web=1&e=x';

    test('a named link keeps its address, its words a tap from it; one that '
        'goes nowhere a message would follow stays words', () {
      final shown = notesAsShown(EventNotes(
        text: 'not what the sheet reads where there is HTML',
        html: '<html><body><p>The deck: <a class="x" href="'
            '${deck.replaceAll('&', '&amp;')}"><span>Q3 deck.pptx</span></a>'
            '</p><p>Questions to <a href="mailto:dana@hadco.example">Dana'
            '</a>; <a href="javascript:alert(1)">this</a> stays words.</p>'
            '<p><a href=\'https://hadco.example/plan\'><img src="cid:a">'
            '</a></p><p><a href="tel:+1%20469-555-0123,,123456789#">Dial '
            'in</a>, not <a href="tel:*21*0545551234#">this</a>.</p>'
            '<p><a href="tel:%E0%A4">Nor</a> <a href="tel:%zz1234567">'
            'these</a>.</p></body></html>',
      ));
      expect(
          shown.text,
          'The deck: Q3 deck.pptx\n'
          'Questions to Dana; this stays words.\n'
          'https://hadco.example/plan\n'
          'Dial in, not this.\n'
          'Nor these.');
      expect(
          [for (final l in shown.links) shown.text.substring(l.start, l.end)],
          ['Q3 deck.pptx', 'Dana', 'https://hadco.example/plan', 'Dial in'],
          reason: 'a link with no words shows its address; a code to the '
              'phone is no number to ring');
      expect([for (final l in shown.links) '${l.target}'], [
        deck,
        'mailto:dana@hadco.example',
        'https://hadco.example/plan',
        'tel:+14695550123,,123456789%23',
      ]);
      expect([for (final l in shown.links) l.kind], [
        TextLinkKind.web,
        TextLinkKind.email,
        TextLinkKind.web,
        TextLinkKind.phone,
      ]);
    });

    test("Teams' block keeps its links too, without its rows of "
        'underscores', () {
      final shown = notesAsShown(EventNotes(
        text: 'Agenda',
        html: '<div>Agenda</div>',
        keptBelow: '<div>${'_' * 40}</div><div><a href="https://teams.'
            'microsoft.com/l/meetup-join/x">Click here to join the meeting'
            '</a></div>',
      ));
      expect(shown.text, 'Agenda\n\nClick here to join the meeting');
      expect('${shown.links.single.target}',
          'https://teams.microsoft.com/l/meetup-join/x');
    });

    testWidgets('on the sheet, a named link opens its address as a '
        "message's link does", (tester) async {
      await host(tester);
      final opened = catchLaunches(tester);
      engine.eventNotesOf['m'] = EventNotes(
        text: 'The deck: Q3 deck.pptx',
        html: '<p>The deck: <a href="${deck.replaceAll('&', '&amp;')}">'
            'Q3 deck.pptx</a></p>',
      );
      await open(tester, meeting(preview: 'The deck: Q3 deck.pptx'));

      await tester.tapOnText(find.textRange.ofSubstring('Q3 deck.pptx'));
      await tester.pump();
      expect(opened, [deck]);
    });

    List<String> words(ShownNotes shown) =>
        [for (final l in shown.links) shown.text.substring(l.start, l.end)];
    List<String> targets(ShownNotes shown) =>
        [for (final l in shown.links) '${l.target}'];

    test('a link whose words are an address, an email address or a number, '
        'and which goes elsewhere, shows where it goes beside them', () {
      final shown = notesAsShown(const EventNotes(
        text: '',
        html: '<p><a href="https://evil.example/login">https://hadco.'
            'sharepoint.com/q3</a></p>'
            '<p><a href="https://evil.example/login">hadco.sharepoint.com'
            '</a></p>'
            '<p><a href="https://evil.example/x">Open hadco.sharepoint.com '
            'now</a></p>'
            '<p><a href="mailto:boss@evil.example">dana@hadco.example</a></p>'
            '<p><a href="tel:+19005550199">+1 469-555-0123</a></p>',
      ));
      expect(
          shown.text,
          'https://hadco.sharepoint.com/q3 (evil.example)\n'
          'hadco.sharepoint.com (evil.example)\n'
          'Open hadco.sharepoint.com now (evil.example)\n'
          'dana@hadco.example (boss@evil.example)\n'
          '+1 469-555-0123 (+19005550199)');
      expect(words(shown), [
        'evil.example',
        'evil.example',
        'evil.example',
        'boss@evil.example',
        '+19005550199',
      ], reason: 'what is a tap from where it goes says where that is');
      expect(targets(shown), [
        'https://evil.example/login',
        'https://evil.example/login',
        'https://evil.example/x',
        'mailto:boss@evil.example',
        'tel:+19005550199',
      ]);
    });

    test('one that goes where its words say keeps them: the same host, '
        'through Safe Links too, the same address and the same number', () {
      const wrapped = 'https://nam12.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fhadco.sharepoint.com%2Fq3&data=x';
      final shown = notesAsShown(EventNotes(
        text: '',
        html: '<p><a href="https://hadco.sharepoint.com/sites/q3?web=1">'
            'hadco.sharepoint.com/q3</a></p>'
            '<p><a href="${wrapped.replaceAll('&', '&amp;')}">https://www.'
            'hadco.sharepoint.com/q3</a></p>'
            '<p><a href="mailto:Dana%40Hadco.example">dana@hadco.example</a>'
            '</p><p><a href="tel:+14695550123,,123456789#">+1 469-555-0123,,'
            '123456789#</a></p>',
      ));
      expect(
          shown.text,
          'hadco.sharepoint.com/q3\n'
          'https://www.hadco.sharepoint.com/q3\n'
          'dana@hadco.example\n'
          '+1 469-555-0123,,123456789#');
      expect(words(shown), shown.text.split('\n'));
      expect(targets(shown), [
        'https://hadco.sharepoint.com/sites/q3?web=1',
        wrapped,
        'mailto:Dana@Hadco.example',
        'tel:+14695550123,,123456789%23',
      ]);
    });

    test('a number to ring takes its extension after a pause, and nothing '
        'else written after its ;', () {
      final shown = notesAsShown(const EventNotes(
        text: '',
        html: '<p><a href="tel:+1-469-555-0123;ext=4567">Desk</a>, '
            '<a href="tel:+14695550123;postd=pp123%23">Bridge</a>, '
            '<a href="tel:+14695550123;isub=99;phone-context=hadco.example">'
            'Line</a>, <a href="tel:+14695550123,,123456789#">Teams</a></p>',
      ));
      expect(words(shown), ['Desk', 'Bridge', 'Line', 'Teams']);
      expect(targets(shown), [
        'tel:+14695550123,4567',
        'tel:+14695550123,,123%23',
        'tel:+14695550123',
        'tel:+14695550123,,123456789%23',
      ]);
    });

    test('marks a page holds of its own are no links', () {
      final shown = notesAsShown(const EventNotes(
        text: '',
        html: '<p>\u{E000}-1\u{E001}x\u{E002} and \u{E000}9\u{E001}y'
            '\u{E002}</p>',
      ));
      expect(shown.links, isEmpty);
      expect(shown.text, '-1x and 9y');
    });

    testWidgets('on the sheet, such a link is a tap from where its words say, '
        'and where it goes is a tap of its own', (tester) async {
      await host(tester);
      final opened = catchLaunches(tester);
      engine.eventNotesOf['m'] = const EventNotes(
        text: 'The deck: https://hadco.sharepoint.com/q3',
        html: '<p>The deck: <a href="https://evil.example/login">'
            'https://hadco.sharepoint.com/q3</a></p>',
      );
      await open(tester, meeting(preview: 'The deck'));

      await tester.tapOnText(
          find.textRange.ofSubstring('https://hadco.sharepoint.com/q3'));
      await tester.pump();
      await tester.tapOnText(find.textRange.ofSubstring('evil.example'));
      await tester.pump();
      expect(opened,
          ['https://hadco.sharepoint.com/q3', 'https://evil.example/login']);
    });

    test("Outlook's notes come with their page, above Teams' block; Edit's "
        'text is as it was', () async {
      Future<EventNotes> notes(String type, String body,
          {bool online = false}) {
        final api = GraphCalendarApi(
          accessToken: ({bool force = false}) async => 't',
          httpClient: http_testing.MockClient((_) async => http.Response(
              jsonEncode({
                'id': 'e1',
                'isOnlineMeeting': online,
                'body': {'contentType': type, 'content': body},
              }),
              200)),
          sleep: (_) async {},
        );
        return api.notes('e1');
      }

      const page = '<html><body><p>The deck: <a href="https://hadco.example/'
          'q3">Q3 deck</a></p></body></html>';
      final html = await notes('html', page);
      expect(html.text, 'The deck: Q3 deck');
      expect(html.html, page);

      final teams = await notes(
          'html',
          '<html><body><div>Agenda</div><div>${'_' * 40}</div>'
              '<div>Microsoft Teams meeting</div></body></html>',
          online: true);
      expect(teams.html, contains('Agenda'));
      expect(teams.html, isNot(contains('Microsoft Teams meeting')));
      expect(teams.keptBelow, contains('Microsoft Teams meeting'));

      expect((await notes('text', 'Agenda only')).html, isNull,
          reason: 'plain text has no page to read links from');
    });

    test("Google's notes come with their page where the description is one",
        () async {
      Future<EventNotes> notes(String description) => GoogleCalendarApi(
            accessToken: ({bool force = false}) async => 't',
            httpClient: http_testing.MockClient((_) async => http.Response(
                jsonEncode({'id': 'e1', 'description': description}), 200)),
            sleep: (_) async {},
          ).notes('e1');

      const page = 'The deck: <a href="https://hadco.example/q3">Q3 deck</a>';
      final html = await notes(page);
      expect(html.text, 'The deck: Q3 deck');
      expect(html.html, page);
      expect((await notes('Agenda only')).html, isNull);
    });
  });

  group('the place, a tap from directions (#40)', () {
    const cafe = 'Café Noir, 12 Rothschild Blvd';
    const inMaps = 'geo:0,0?q=Caf%C3%A9+Noir%2C+12+Rothschild+Blvd';
    final link = find.byKey(const ValueKey('place-link'));

    testWidgets("on the sheet it opens the phone's maps app", (tester) async {
      await host(tester);
      final opened = catchLaunches(tester);
      await open(tester, meeting(location: cafe));

      expect(find.text(cafe), findsOneWidget);
      await tester.tap(link);
      await tester.pump();
      expect(opened, [inMaps]);
    });

    testWidgets('with no maps app, Google Maps on the web', (tester) async {
      await host(tester);
      final opened =
          catchLaunches(tester, answer: (url) => !url.startsWith('geo:'));
      await open(tester, meeting(location: cafe));

      await tester.tap(link);
      await tester.pump();
      expect(opened, [
        inMaps,
        'https://www.google.com/maps/search/'
            '?api=1&query=Caf%C3%A9+Noir%2C+12+Rothschild+Blvd',
      ]);
    });

    testWidgets('one that only names an online meeting, or is its link, '
        'stays as it was', (tester) async {
      await host(tester);
      for (final place in [
        'Microsoft Teams Meeting',
        'https://us02web.zoom.us/j/81234567890',
      ]) {
        await open(tester, meeting(location: place));
        expect(find.text(place), findsOneWidget);
        expect(link, findsNothing, reason: place);
        Navigator.of(tester.element(find.text(place))).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('a Hebrew place still reads from the right', (tester) async {
      await host(tester);
      const place = 'קפה נואר, רוטשילד 12';
      await open(tester, meeting(location: place));

      final text = tester.widget<Text>(
          find.descendant(of: link, matching: find.text(place)));
      expect(text.textDirection, TextDirection.rtl);
    });

    testWidgets("in My Day the place opens the maps app, and the rest of "
        'the row its sheet', (tester) async {
      final opened = catchLaunches(tester);
      final now = DateTime(2026, 11, 17, 9);
      await host(
        tester,
        home: const Scaffold(body: MyDayPane()),
        clock: now,
        events: (hadco) => [meeting(location: cafe)],
      );

      final row = find.byKey(const ValueKey('my-day-event:m'));
      await tester.tap(find.descendant(of: row, matching: link));
      await tester.pump();
      expect(opened, [inMaps]);
      expect(find.byKey(const ValueKey('event-when')), findsNothing);

      await tester
          .tap(find.descendant(of: row, matching: find.text('Supplier call')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-when')), findsOneWidget);
    });

    testWidgets("the agenda's row is no link: a tap there opens the sheet, "
        'where the place is one', (tester) async {
      final n = DateTime.now();
      await host(
        tester,
        home: const CalendarScreen(),
        events: (hadco) => [
          meeting(
            location: cafe,
            start: DateTime(n.year, n.month, n.day + 1, 14),
          ),
        ],
      );

      final row = find.byKey(const ValueKey('agenda-event:m'));
      expect(find.descendant(of: row, matching: find.textContaining(cafe)),
          findsOneWidget);
      expect(find.descendant(of: row, matching: link), findsNothing);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(link, findsOneWidget);
    });
  });
}

/// The sample engine, whose notes can be made not to come.
class _NotesEngine extends SampleMailEngine {
  /// Thrown by [eventNotes] while set.
  Object? notesFailure;

  @override
  Future<EventNotes> eventNotes(
    CalendarEvent event, {
    bool wholeSeries = false,
  }) async {
    final failure = notesFailure;
    if (failure != null) {
      eventNotesAsked++;
      throw failure;
    }
    return super.eventNotes(event, wholeSeries: wholeSeries);
  }
}
