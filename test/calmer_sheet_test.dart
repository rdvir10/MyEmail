import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/google_calendar_api.dart'
    show GoogleCalendarApi;
import 'package:myemail/data/graph/graph_calendar_api.dart'
    show GraphCalendarApi;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting_moment.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show showEventDetails;

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// A calmer meeting sheet (calendar idea #93): the one button that fits the
/// moment filled, Open in Outlook under ⋮, how long until it starts, the
/// notes before the people, a long list of people folded, and each answer
/// coloured and said. Drawn with the app's own theme and Roboto, at a
/// phone's and a tablet's size, at text sizes 1.0 and 1.3, light and dark.
void main() {
  setUpAll(() async {
    FakeWebViewPlatform.install();
    await loadRoboto();
  });

  const phone = Size(412, 915);
  const narrowPhone = Size(360, 780);

  // Tuesday 17 November 2026, as the pictures have it.
  DateTime at(int hour, [int minute = 0, int days = 0]) =>
      DateTime(2026, 11, 17 + days, hour, minute);

  /// The time as the sheet sees it, moved on by a test.
  var clock = at(9);
  setUp(() => clock = at(9));

  const dana = MailAddress(email: 'dana.levi@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');
  const teams = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_x';
  const outlook = 'https://outlook.office.com/calendar/item/x';

  /// A meeting of Dana's on [a]'s calendar, Ron invited, online unless
  /// [joinUrl] is null.
  CalendarEvent invited(
    Account a, {
    DateTime? start,
    String? joinUrl = teams,
    EventResponse response = EventResponse.notResponded,
    String? webLink,
    String preview = '',
    String location = '',
    List<EventAttendee> more = const [],
    bool readOnly = false,
  }) {
    final from = start ?? at(10);
    return CalendarEvent(
      id: 'm',
      accountId: a.id,
      title: 'Supplier call',
      start: from,
      end: from.add(const Duration(hours: 1)),
      location: location,
      joinUrl: joinUrl,
      webLink: webLink,
      organizer: dana,
      attendees: [
        const EventAttendee(dana, response: EventResponse.organizer),
        EventAttendee(ron, response: response),
        ...more,
      ],
      response: response,
      preview: preview,
      readOnly: readOnly,
    );
  }

  /// One Ron organised, with [people] invited.
  CalendarEvent organised(
    Account a, {
    DateTime? start,
    List<EventAttendee> people = const [
      EventAttendee(dana, response: EventResponse.accepted),
    ],
    String preview = '',
  }) {
    final from = start ?? at(10, 0, 7);
    return CalendarEvent(
      id: 'm',
      accountId: a.id,
      title: 'Q4 planning',
      start: from,
      end: from.add(const Duration(hours: 1)),
      joinUrl: teams,
      organizer: ron,
      isOrganizer: true,
      attendees: [
        const EventAttendee(ron, response: EventResponse.organizer),
        ...people,
      ],
      response: EventResponse.organizer,
      preview: preview,
    );
  }

  /// A button that opens [event]'s sheet, from an account of [provider]'s,
  /// at [size] and text size [scale], light or [dark].
  Future<void> pump(
    WidgetTester tester,
    CalendarEvent Function(Account a) event, {
    Size size = phone,
    double scale = 1.0,
    bool dark = false,
    bool use24h = false,
    MailProvider provider = MailProvider.outlook,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = SampleMailEngine();
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
    final shown = event(account);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(
          FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      meetingClockProvider.overrideWithValue(() => clock),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: use24h,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: TextButton(
                key: const ValueKey('open-sheet'),
                onPressed: () =>
                    showEventDetails(context, ref, shown, account),
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

  /// What links open, kept instead of opened.
  List<String> catchLaunches(WidgetTester tester) {
    final opened = <String>[];
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      launcher,
      (call) async {
        opened.add('${(call.arguments as Map)['url']}');
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, null));
    return opened;
  }

  /// How [key]'s button is painted: filled in the theme's main colour (the
  /// one that matters now), in its quieter one (the answer given), or
  /// outlined like the rest.
  String look(WidgetTester tester, String key) {
    final button = find.byKey(ValueKey(key));
    expect(button, findsOneWidget, reason: key);
    final fill = tester
        .widget<Material>(
            find.descendant(of: button, matching: find.byType(Material)).first)
        .color;
    final scheme = Theme.of(tester.element(button)).colorScheme;
    if (fill == scheme.primary) return 'filled';
    if (fill == scheme.secondaryContainer) return 'tonal';
    if (fill == null || fill.a == 0) return 'outlined';
    return 'painted $fill';
  }

  /// Whether a tap at [point] reaches [button].
  bool reaches(WidgetTester tester, Finder button, Offset point) {
    final target = tester.renderObject(button);
    final result = HitTestResult();
    tester.binding.hitTestInView(result, point, tester.view.viewId);
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is! RenderObject) continue;
      for (RenderObject? o = hit; o != null; o = o.parent) {
        if (identical(o, target)) return true;
      }
    }
    return false;
  }

  /// [button] answers a tap over 48 dp of height.
  void tallEnough(WidgetTester tester, Finder button) {
    final middle = tester.getCenter(button);
    for (final dy in [-23.0, 23.0]) {
      expect(reaches(tester, button, middle + Offset(0, dy)), isTrue,
          reason: '${button.describeMatch(Plurality.one)}: a tap ${dy.abs()} '
              'from its middle does not reach it');
    }
  }

  /// The paragraph drawing [text]'s words.
  RenderParagraph paragraphOf(WidgetTester tester, Finder text) =>
      tester.renderObject<RenderParagraph>(find
          .descendant(
              of: text, matching: find.byType(RichText), matchRoot: true)
          .first);

  /// Whether [p] shows all of its words, on as many lines as it needs.
  bool whole(RenderParagraph p) =>
      !p.didExceedMaxLines &&
      p.getMaxIntrinsicWidth(double.infinity) <= p.size.width + 0.5;

  /// The contrast between two colours, as WCAG works it out.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// The answers counted under the people's heading, as shown.
  String? countsOf(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('event-answers'))).data;

  /// The ⋮ menu's entries, in order, by their words.
  List<String> menu(WidgetTester tester) => [
        for (final item in tester.widgetList<PopupMenuItem<String>>(
            find.byType(PopupMenuItem<String>)))
          (item.child! as Text).data!,
      ];

  group('the one button that fits the moment is filled (#93)', () {
    testWidgets('Join, from a quarter of an hour before the meeting until it '
        'ends, keeping up while the sheet is open; outlined like the rest '
        'before and after', (tester) async {
      clock = at(9, 44);
      await pump(tester,
          (a) => invited(a, response: EventResponse.accepted));
      expect(look(tester, 'event-join'), 'outlined');

      clock = at(9, 45);
      await tester.pump(const Duration(seconds: 30));
      expect(look(tester, 'event-join'), 'filled');

      clock = at(10, 59);
      await tester.pump(const Duration(seconds: 30));
      expect(look(tester, 'event-join'), 'filled');

      clock = at(11);
      await tester.pump(const Duration(seconds: 30));
      expect(look(tester, 'event-join'), 'outlined',
          reason: 'over: an online meeting still has Join');
      expect(look(tester, 'event-accept'), 'tonal',
          reason: 'the answer given is marked as it was');
    });

    testWidgets('near, on a meeting not answered: Join is the one filled, '
        'and the answers are outlined', (tester) async {
      clock = at(9, 50);
      await pump(tester, (a) => invited(a));
      expect(look(tester, 'event-join'), 'filled');
      for (final key in ['event-accept', 'event-tentative', 'event-decline']) {
        expect(look(tester, key), 'outlined', reason: key);
      }
      tallEnough(tester, find.byKey(const ValueKey('event-join')));
    });

    testWidgets('next week, on a meeting not answered: Accept is the one '
        'filled, and Join is outlined', (tester) async {
      await pump(tester, (a) => invited(a, start: at(10, 0, 7)));
      expect(look(tester, 'event-accept'), 'filled');
      expect(look(tester, 'event-tentative'), 'outlined');
      expect(look(tester, 'event-decline'), 'outlined');
      expect(look(tester, 'event-join'), 'outlined');
      tallEnough(tester, find.byKey(const ValueKey('event-accept')));
      // What a screen reader is told is the button's, as before.
      final told = tester
          .getSemantics(find.byKey(const ValueKey('event-accept')))
          .getSemanticsData();
      expect(told.label, 'Accept');
      expect(told.hasAction(SemanticsAction.tap), isTrue);
    });

    testWidgets('answered, and not near: none is filled; the answer given '
        'stays marked', (tester) async {
      await pump(tester,
          (a) => invited(a,
              start: at(10, 0, 7), response: EventResponse.tentative));
      expect(look(tester, 'event-accept'), 'outlined');
      expect(look(tester, 'event-tentative'), 'tonal');
      expect(look(tester, 'event-decline'), 'outlined');
      expect(look(tester, 'event-join'), 'outlined');
    });

    testWidgets('a meeting of yours next week fills nothing: Join and Edit '
        'are outlined', (tester) async {
      await pump(tester, (a) => organised(a));
      expect(look(tester, 'event-join'), 'outlined');
      expect(look(tester, 'event-edit'), 'outlined');
    });

    testWidgets('a meeting not online has no Join, and Accept filled',
        (tester) async {
      await pump(tester,
          (a) => invited(a, start: at(10, 0, 7), joinUrl: null));
      expect(find.byKey(const ValueKey('event-join')), findsNothing);
      expect(look(tester, 'event-accept'), 'filled');
    });

    for (final (size, scale) in [(narrowPhone, 1.3), (phone, 1.0)]) {
      testWidgets('the buttons wrap within the sheet, each on one line, '
          '${size.width.round()} wide at text size $scale', (tester) async {
        clock = at(9, 50);
        await pump(tester, (a) => invited(a, webLink: outlook),
            size: size, scale: scale);
        expect(tester.takeException(), isNull);
        for (final key in [
          'event-accept',
          'event-tentative',
          'event-decline',
          'event-join',
        ]) {
          final button = find.byKey(ValueKey(key));
          final rect = tester.getRect(button);
          expect(rect.left, greaterThanOrEqualTo(20 - 0.5), reason: key);
          expect(rect.right, lessThanOrEqualTo(size.width - 8 + 0.5),
              reason: '$key runs past the edge');
          final label = find
              .descendant(of: button, matching: find.byType(Text))
              .first;
          final p = paragraphOf(tester, label);
          expect(whole(p), isTrue, reason: '"${p.text.toPlainText()}" is cut');
          expect(p.size.height, lessThan(2 * p.preferredLineHeight - 0.5),
              reason: '"${p.text.toPlainText()}" takes two lines');
        }
      });
    }
  });

  group('Open in Outlook under ⋮ (#93)', () {
    testWidgets("is the menu's last entry, not a button on the sheet, and "
        'opens the meeting there; the rest of the menu is as it was',
        (tester) async {
      final opened = catchLaunches(tester);
      await pump(tester,
          (a) => invited(a, start: at(10, 0, 7), webLink: outlook));
      expect(find.text('Open in Outlook'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      expect(menu(tester), [
        'Email everyone',
        'Forward',
        'Propose a new time',
        'Duplicate',
        'Decline and remove',
        'Open in Outlook',
      ]);
      tallEnough(tester, find.byKey(const ValueKey('event-web')));

      await tester.tap(find.byKey(const ValueKey('event-web')));
      await tester.pumpAndSettle();
      expect(opened, [outlook]);
      expect(find.byKey(const ValueKey('event-when')), findsOneWidget,
          reason: 'the sheet stays, as it did for the button');
    });

    testWidgets("on a Google account it is Open in Google Calendar, after "
        "a meeting of yours' entries", (tester) async {
      await pump(
          tester,
          (a) => CalendarEvent(
                id: 'm',
                accountId: a.id,
                title: 'Lunch',
                start: at(12, 0, 7),
                end: at(13, 0, 7),
                organizer: const MailAddress(email: 'ron@gmail.example'),
                isOrganizer: true,
                response: EventResponse.organizer,
                webLink: 'https://www.google.com/calendar/event?eid=x',
              ),
          provider: MailProvider.gmail);
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      expect(menu(tester),
          ['Invite people', 'Duplicate', 'Delete', 'Open in Google Calendar']);
    });

    testWidgets('a calendar the account only reads keeps it, alone under ⋮; '
        'one with no link has no ⋮, as before', (tester) async {
      await pump(tester,
          (a) => invited(a,
              start: at(10, 0, 7), webLink: outlook, readOnly: true));
      expect(find.byKey(const ValueKey('event-accept')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      expect(menu(tester), ['Open in Outlook']);
    });

    testWidgets('a calendar the account only reads, with no link: no ⋮',
        (tester) async {
      await pump(tester,
          (a) => invited(a, start: at(10, 0, 7), readOnly: true));
      expect(find.byKey(const ValueKey('event-more')), findsNothing);
    });
  });

  group('how long until it starts (#93)', () {
    CalendarEvent call({
      DateTime? start,
      bool allDay = false,
      bool cancelled = false,
    }) {
      final from = start ?? at(10);
      return CalendarEvent(
        id: 'm',
        accountId: 'a',
        title: 'Supplier call',
        start: from,
        end: allDay
            ? from.add(const Duration(days: 1))
            : from.add(const Duration(hours: 1)),
        allDay: allDay,
        cancelled: cancelled,
      );
    }

    test('in hours and minutes, in minutes as the bar over the mail says '
        'them, now while it is on, each with a capital on its line of its '
        'own; nothing once over, on another day, for a whole day or one '
        'cancelled', () {
      String? shown(CalendarEvent e, DateTime now) =>
          timeToStart(e, now)?.shown;
      String? spoken(CalendarEvent e, DateTime now) =>
          timeToStart(e, now)?.spoken;
      final e = call();
      expect(shown(e, at(7, 50)), 'In 2 h 10 min');
      expect(spoken(e, at(7, 50)), 'Starts in 2 hours 10 minutes');
      expect(shown(e, at(8)), 'In 2 h');
      expect(spoken(e, at(8)), 'Starts in 2 hours');
      expect(shown(e, at(8, 59)), 'In 1 h 1 min');
      expect(spoken(e, at(8, 59)), 'Starts in 1 hour 1 minute');
      expect(shown(e, at(9, 48)), 'In 12 min');
      expect(spoken(e, at(9, 48)), 'Starts in 12 minutes');
      // Part of a minute counts as one, as the bar counts it.
      expect(shown(e, at(9, 59).add(const Duration(seconds: 30))), 'In 1 min');
      expect(spoken(e, at(9, 59).add(const Duration(seconds: 30))),
          'Starts in 1 minute');
      expect(shown(e, at(9, 47).add(const Duration(seconds: 1))), 'In 13 min');
      expect(shown(e, at(0, 1)), 'In 9 h 59 min');
      expect(shown(e, at(10)), 'Now');
      expect(spoken(e, at(10)), 'On now');
      expect(shown(e, at(10, 59)), 'Now');
      expect(timeToStart(e, at(11)), isNull, reason: 'over');
      expect(timeToStart(e, at(10, 0, -1)), isNull, reason: 'the day before');
      expect(timeToStart(call(start: at(0, 30, 1)), at(23, 50)), isNull,
          reason: 'tomorrow, however soon');
      expect(timeToStart(call(start: DateTime(2026, 11, 17), allDay: true),
              at(9)),
          isNull);
      expect(timeToStart(call(cancelled: true), at(9, 48)), isNull);
      // Begun last night and on still: now.
      final overnight = CalendarEvent(
        id: 'n',
        accountId: 'a',
        title: 'Night shift',
        start: at(22, 0, -1),
        end: at(6),
      );
      expect(shown(overnight, at(5)), 'Now');
    });

    testWidgets('under the day and time, keeping up with the clock while the '
        'sheet is open, gone once over; a screen reader hears it in words',
        (tester) async {
      clock = at(9, 48);
      await pump(tester, (a) => invited(a));
      final starts = find.byKey(const ValueKey('event-starts'));
      final when = find.byKey(const ValueKey('event-when'));
      expect(tester.widget<Text>(starts).data, 'In 12 min');
      expect(tester.getRect(starts).top,
          moreOrLessEquals(tester.getRect(when).bottom, epsilon: 0.5));
      expect(tester.getRect(starts).left, tester.getRect(when).left);
      expect(tester.getSemantics(starts).label, 'Starts in 12 minutes');

      clock = at(9, 49);
      await tester.pump(const Duration(seconds: 30));
      expect(tester.widget<Text>(starts).data, 'In 11 min');

      clock = at(10, 1);
      await tester.pump(const Duration(seconds: 30));
      expect(tester.widget<Text>(starts).data, 'Now');

      clock = at(11);
      await tester.pump(const Duration(seconds: 30));
      expect(starts, findsNothing);
    });

    testWidgets('nothing for a meeting on another day', (tester) async {
      await pump(tester, (a) => invited(a, start: at(10, 0, 1)));
      expect(find.byKey(const ValueKey('event-starts')), findsNothing);
    });

    for (final dark in [false, true]) {
      for (final (size, scale, use24h) in [
        (narrowPhone, 1.3, false),
        (phone, 1.0, true),
      ]) {
        testWidgets('whole and readable, ${dark ? 'dark' : 'light'}, '
            '${size.width.round()} wide at text size $scale on a '
            '${use24h ? 24 : 12}-hour clock', (tester) async {
          clock = at(7, 50);
          await pump(tester, (a) => invited(a),
              size: size, scale: scale, dark: dark, use24h: use24h);
          final starts = find.byKey(const ValueKey('event-starts'));
          final p = paragraphOf(tester, starts);
          expect(p.text.toPlainText(), 'In 2 h 10 min');
          expect(whole(p), isTrue);
          final ink = p.text.style!.color!;
          final sheet = tester
              .widget<Material>(find
                  .descendant(
                      of: find.byType(BottomSheet),
                      matching: find.byType(Material))
                  .first)
              .color!;
          expect(contrast(ink, sheet), greaterThanOrEqualTo(4.5));
        });
      }
    }
  });

  /// [n] more people, Guest 1 to Guest [n], answering in turn as [answers]
  /// say.
  List<EventAttendee> guests(int n, List<EventResponse> answers) => [
        for (var i = 1; i <= n; i++)
          EventAttendee(
            MailAddress(email: 'guest$i@hadco.example', name: 'Guest $i'),
            response: answers[(i - 1) % answers.length],
          ),
      ];
  const yes = EventResponse.accepted;
  const no = EventResponse.declined;
  const waiting = EventResponse.notResponded;

  Finder sheetList() => find
      .descendant(
          of: find.byType(BottomSheet), matching: find.byType(Scrollable))
      .first;

  group('the notes before the people; a long list folds (#93)', () {
    final toggle = find.byKey(const ValueKey('event-people'));

    testWidgets('the notes come after the buttons, before the organiser, the '
        'people and Mail about this meeting', (tester) async {
      await pump(
          tester,
          (a) => invited(a,
              start: at(10, 0, 7), preview: 'Agenda: the numbers for Q3.'),
          size: const Size(412, 1600));
      double top(Finder f) => tester.getRect(f).top;
      final order = [
        tester.getRect(find.byKey(const ValueKey('event-join'))).bottom,
        top(find.byKey(const ValueKey('event-notes'))),
        top(find.text('Organiser')),
        top(find.text('2 people')),
        top(find.text('Dana Levi').last),
        top(find.byKey(const ValueKey('event-mail-about'))),
      ];
      expect(order, [...order]..sort(), reason: 'in that order down');
    });

    testWidgets('more than six start folded to their heading and counts, '
        'with an arrow; a tap opens them and another folds them; a screen '
        'reader hears a button that opens and closes', (tester) async {
      await pump(
          tester,
          (a) => invited(a,
              start: at(10, 0, 7),
              response: yes,
              more: guests(10, [yes, yes, yes, waiting, yes, no, yes, waiting,
                  yes, waiting])));
      expect(find.text('Guest 1'), findsNothing);
      expect(find.text('Dana Levi'), findsOneWidget, reason: 'the organiser');
      expect(find.descendant(of: toggle, matching: find.text('12 people')),
          findsOneWidget);
      final counts = find.descendant(
          of: toggle, matching: find.byKey(const ValueKey('event-answers')));
      expect(tester.widget<Text>(counts).data,
          '8 accepted · 1 declined · 3 not answered',
          reason: 'everyone listed, as their marks show them: the organiser '
              'as accepted');
      expect(
          find.descendant(of: toggle, matching: find.byIcon(Icons.expand_more)),
          findsOneWidget);
      expect(
          tester.getSemantics(toggle),
          isSemantics(
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
            hasTapAction: true,
          ));
      expect(tester.getSemantics(toggle).label,
          allOf(contains('12 people'), contains('8 accepted')));
      tallEnough(tester, toggle);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('Guest 1'), findsOneWidget);
      expect(
          find.descendant(of: toggle, matching: find.byIcon(Icons.expand_less)),
          findsOneWidget);
      expect(tester.getSemantics(toggle), isSemantics(isExpanded: true));

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('Guest 1'), findsNothing);
    });

    testWidgets('opened, it stays so while the sheet is open, scrolled out of '
        'sight and back; the sheet opened again starts folded', (tester) async {
      await pump(
          tester,
          (a) => invited(a,
              start: at(10, 0, 7),
              more: guests(10, [yes]),
              preview: [for (var i = 1; i <= 30; i++) 'Point $i.'].join('\n')),
          size: const Size(412, 600));
      final more = find.byKey(const ValueKey('linked-text-more'));
      await tester.dragUntilVisible(more, sheetList(), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(toggle, sheetList(), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      final list = tester.state<ScrollableState>(sheetList());
      list.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Guest 10', skipOffstage: false), findsOneWidget,
          reason: 'kept while out of sight');
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Guest 10'), findsOneWidget);

      Navigator.of(tester.element(toggle)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-sheet')));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(toggle, sheetList(), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('Guest 1'), findsNothing);
    });

    testWidgets('six or fewer are listed as before, with no counts on '
        "someone else's meeting", (tester) async {
      await pump(tester,
          (a) => invited(a, start: at(10, 0, 7), more: guests(4, [yes])));
      expect(find.text('6 people'), findsOneWidget);
      expect(find.text('Guest 4'), findsOneWidget);
      expect(toggle, findsNothing);
      expect(find.byKey(const ValueKey('event-answers')), findsNothing);
    });

    testWidgets("on a meeting Ron organised, Email the … who have not "
        'answered stays beside the counts, folded', (tester) async {
      await pump(
          tester,
          (a) => organised(a,
              people: guests(11, [yes, yes, no, waiting, yes, yes, yes,
                  waiting, yes, yes, waiting])));
      expect(
          find.descendant(
              of: toggle, matching: find.text('11 people invited')),
          findsOneWidget);
      expect(countsOf(tester),
          '7 accepted · 1 declined · 3 not answered');
      expect(find.text('Guest 1'), findsNothing);
      final nudge = find.byKey(const ValueKey('event-nudge'));
      expect(
          find.descendant(
              of: nudge,
              matching: find.text('Email the 3 who have not answered')),
          findsOneWidget);
      expect(tester.getRect(nudge).top,
          greaterThanOrEqualTo(tester.getRect(toggle).bottom - 0.5));
      tallEnough(tester, nudge);
    });

    for (final dark in [false, true]) {
      testWidgets('folded, whole on a phone 360 wide at text size 1.3, '
          "${dark ? 'dark' : 'light'}", (tester) async {
        await pump(
            tester,
            (a) => organised(a,
                people: guests(
                    11, [yes, EventResponse.tentative, no, waiting])),
            size: narrowPhone,
            scale: 1.3,
            dark: dark);
        await tester.dragUntilVisible(
            find.byKey(const ValueKey('event-nudge')), sheetList(),
            const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final arrow = find.descendant(
            of: toggle, matching: find.byIcon(Icons.expand_more));
        expect(tester.getRect(arrow).right,
            lessThanOrEqualTo(narrowPhone.width - 8 + 0.5));
        for (final text in [
          find.descendant(of: toggle, matching: find.text('11 people invited')),
          find.byKey(const ValueKey('event-answers')),
          find.descendant(
              of: find.byKey(const ValueKey('event-nudge')),
              matching: find.byType(Text)),
        ]) {
          final p = paragraphOf(tester, text);
          expect(p.didExceedMaxLines, isFalse,
              reason: '"${p.text.toPlainText()}" is cut');
          expect(tester.getRect(text).right,
              lessThanOrEqualTo(narrowPhone.width - 8 + 0.5),
              reason: '"${p.text.toPlainText()}" runs past the edge');
        }
      });
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('Mail about this meeting and Email the … who have not '
          "answered line up with the people's marks, at text size $scale",
          (tester) async {
        await pump(
            tester, (a) => organised(a, people: guests(3, [yes, waiting])),
            size: const Size(412, 1600), scale: scale);
        final heading = tester.getRect(find.text('3 people invited'));
        final mark =
            tester.getRect(find.byIcon(Icons.check_circle_outline).first);
        expect(mark.left, moreOrLessEquals(heading.left, epsilon: 0.5),
            reason: "the people's marks begin where the words do");
        for (final key in ['event-mail-about', 'event-nudge']) {
          final button = find.byKey(ValueKey(key));
          final icon = find.descendant(of: button, matching: find.byType(Icon));
          expect(tester.getRect(icon).left,
              moreOrLessEquals(mark.left, epsilon: 0.5),
              reason: key);
        }
        // Moved, and a tap still reaches each over 48 dp: the nudge too,
        // which had no more than its own 40.
        for (final key in ['event-mail-about', 'event-nudge']) {
          tallEnough(tester, find.byKey(ValueKey(key)));
        }
      });
    }
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets("the notes' Show more begins where the notes do, at text size "
        '$scale', (tester) async {
      await pump(
          tester,
          (a) => invited(a,
              start: at(10, 0, 7),
              preview: [for (var i = 1; i <= 20; i++) 'Point $i.'].join('\n')),
          size: const Size(412, 1600),
          scale: scale);
      final more = find.byKey(const ValueKey('linked-text-more'));
      final words =
          find.descendant(of: more, matching: find.text('Show more'));
      expect(tester.getRect(words).left,
          moreOrLessEquals(
              tester.getRect(find.byKey(const ValueKey('linked-text'))).left,
              epsilon: 0.5));
      tallEnough(tester, more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.descendant(of: more, matching: find.text('Show less')),
          findsOneWidget);
    });
  }

  group('answers at a glance; one word, Maybe (#93)', () {
    /// One of Ron's, with an answer of each kind.
    CalendarEvent everyAnswer(Account a) => organised(a, people: [
          const EventAttendee(dana, response: yes),
          EventAttendee(
              const MailAddress(email: 'noa@hadco.example', name: 'Noa'),
              response: EventResponse.tentative),
          const EventAttendee(
              MailAddress(email: 'amit@hadco.example', name: 'Amit'),
              response: no),
          const EventAttendee(
              MailAddress(email: 'yael@hadco.example', name: 'Yael'),
              response: waiting),
        ]);

    /// The colour [icon]'s mark is painted in.
    Color markOf(WidgetTester tester, IconData icon) => tester
        .widget<RichText>(find
            .descendant(of: find.byIcon(icon), matching: find.byType(RichText))
            .first)
        .text
        .style!
        .color!;

    Color sheetOf(WidgetTester tester) => tester
        .widget<Material>(find
            .descendant(
                of: find.byType(BottomSheet), matching: find.byType(Material))
            .first)
        .color!;

    for (final dark in [false, true]) {
      testWidgets("each answer's mark has its colour, green, amber, red and "
          "the usual grey, each 3 to 1 against the sheet, "
          "${dark ? 'dark' : 'light'}", (tester) async {
        await pump(tester, everyAnswer, dark: dark);
        final scheme =
            Theme.of(tester.element(find.byType(BottomSheet))).colorScheme;
        final sheet = sheetOf(tester);
        final accepted = markOf(tester, Icons.check_circle_outline);
        final maybe = markOf(tester, Icons.help_outline);
        final declined = markOf(tester, Icons.cancel_outlined);
        final waiting = markOf(tester, Icons.radio_button_unchecked);
        expect(waiting, scheme.onSurfaceVariant,
            reason: 'not answered keeps the grey it had');
        expect({accepted, maybe, declined, waiting}, hasLength(4));
        // Green, amber and red, by their hue.
        expect(HSVColor.fromColor(accepted).hue, inInclusiveRange(90, 150));
        expect(HSVColor.fromColor(maybe).hue, inInclusiveRange(25, 50));
        final red = HSVColor.fromColor(declined).hue;
        expect(red < 15 || red > 345, isTrue, reason: 'hue $red');
        for (final (name, colour) in [
          ('accepted', accepted),
          ('maybe', maybe),
          ('declined', declined),
          ('not answered', waiting),
        ]) {
          expect(contrast(colour, sheet), greaterThanOrEqualTo(3),
              reason: '$name is hard to see');
        }
        // Ron, the organiser, has the accepted mark, as before.
        expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(2));
      });
    }

    testWidgets('a screen reader hears each answer with the name',
        (tester) async {
      await pump(tester, everyAnswer, size: const Size(412, 1600));
      String heard(String name) => tester
          .getSemantics(find.ancestor(
              of: find.text(name), matching: find.byType(ListTile)))
          .label;
      expect(heard('Ron'), startsWith('Ron, accepted'));
      expect(heard('Dana Levi'), startsWith('Dana Levi, accepted'));
      expect(heard('Noa'), startsWith('Noa, maybe'));
      expect(heard('Amit'), startsWith('Amit, declined'));
      expect(heard('Yael'), startsWith('Yael, not answered'));
      expect(heard('Dana Levi'), contains('dana.levi@hadco.example'),
          reason: 'and the address under it, as before');
    });

    testWidgets('the counts say maybe', (tester) async {
      await pump(tester, everyAnswer);
      expect(countsOf(tester),
          '1 accepted · 1 maybe · 1 declined · 1 not answered');
    });
  });

  // A copy of someone else's meeting that carries nobody's answer: every
  // attendee "none", Ron too, and his own answer only as the event's. A
  // calendar that keeps the answers on the organiser's copy alone gives
  // this. Hadco's does not (the next group is what it gives), so these
  // hold the other case: with nothing known, nothing is counted or said.
  group("answers not known on Ron's copy of someone else's meeting (#93)",
      () {
    final toggle = find.byKey(const ValueKey('event-people'));

    /// Dana's meeting next week as Graph gives Ron's copy of it: Ron's own
    /// answer [mine], and [people] attendees besides Ron, each "none".
    CalendarEvent fromGraph(
      Account a, {
      String mine = 'accepted',
      int people = 11,
    }) =>
        GraphCalendarApi.eventFrom({
          'id': 'm',
          'subject': 'Plant 2 safety review',
          'start': {'dateTime': '2026-11-24T08:00:00', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-11-24T09:00:00', 'timeZone': 'UTC'},
          'isOrganizer': false,
          'responseStatus': {'response': mine},
          'organizer': {
            'emailAddress': {'name': 'Dana Levi', 'address': dana.email},
          },
          'attendees': [
            {
              'type': 'required',
              'status': {'response': 'none'},
              'emailAddress': {'name': 'Ron', 'address': ron.email},
            },
            for (var i = 1; i <= people; i++)
              {
                'type': 'required',
                'status': {'response': 'none'},
                'emailAddress': {
                  'name': 'Guest $i',
                  'address': 'guest$i@hadco.example',
                },
              },
          ],
        }, a.id)!;

    String heard(WidgetTester tester, String name) => tester
        .getSemantics(
            find.ancestor(of: find.text(name), matching: find.byType(ListTile)))
        .label;

    testWidgets('with any answer not known, no counts, the count alone; '
        "Ron's own row has his answer, each other mark is grey, and a screen "
        'reader hears the name alone', (tester) async {
      await pump(tester, fromGraph, size: const Size(412, 1600));
      expect(find.descendant(of: toggle, matching: find.text('12 people')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('event-answers')), findsNothing,
          reason: 'not "11 not answered", nor "1 accepted", which reads as '
              'one of twelve and is Ron');
      expect(tester.getSemantics(toggle).label, '12 people');

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(heard(tester, 'Ron'), startsWith('Ron, accepted'));
      expect(heard(tester, 'Guest 1'), isNot(contains('answered')));
      expect(heard(tester, 'Guest 1'), startsWith('Guest 1\n'));
      final scheme =
          Theme.of(tester.element(find.byType(BottomSheet))).colorScheme;
      Color markIn(String name) => tester
          .widget<RichText>(find
              .descendant(
                  of: find.ancestor(
                      of: find.text(name), matching: find.byType(ListTile)),
                  matching: find.byType(RichText))
              .first)
          .text
          .style!
          .color!;
      expect(markIn('Guest 1'), scheme.onSurfaceVariant);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget,
          reason: "Ron's own row shows his answer");
    });

    testWidgets('with nothing known, the heading is the count alone',
        (tester) async {
      await pump(tester, (a) => fromGraph(a, mine: 'none'));
      expect(find.descendant(of: toggle, matching: find.text('12 people')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('event-answers')), findsNothing);
      expect(tester.getSemantics(toggle).label, '12 people');
    });

    testWidgets('six or fewer: Ron\'s row has his answer, the rest the name '
        'alone', (tester) async {
      await pump(
          tester, (a) => fromGraph(a, mine: 'tentativelyAccepted', people: 3),
          size: const Size(412, 1600));
      expect(toggle, findsNothing);
      expect(heard(tester, 'Ron'), startsWith('Ron, maybe'));
      expect(heard(tester, 'Guest 2'), startsWith('Guest 2\n'));
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets("on a meeting Ron organised, none is not answered, as before",
        (tester) async {
      await pump(tester,
          (a) => organised(a, people: guests(7, [EventResponse.none])),
          size: const Size(412, 1600));
      expect(countsOf(tester),
          '7 not answered');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(heard(tester, 'Guest 1'), startsWith('Guest 1, not answered'));
    });

    testWidgets("Google gives each attendee's answer on Ron's copy: one "
        'not given yet is not answered', (tester) async {
      await pump(
          tester,
          (a) => GoogleCalendarApi.eventFrom({
                'id': 'g',
                'summary': 'Plant 2 safety review',
                'start': {'dateTime': '2026-11-24T08:00:00Z'},
                'end': {'dateTime': '2026-11-24T09:00:00Z'},
                'organizer': {'email': 'dana@gmail.example'},
                'attendees': [
                  {
                    'email': 'dana@gmail.example',
                    'organizer': true,
                    'responseStatus': 'accepted',
                  },
                  {
                    'email': 'ron@gmail.example',
                    'self': true,
                    'responseStatus': 'accepted',
                  },
                  for (var i = 1; i <= 10; i++)
                    {
                      'email': 'guest$i@gmail.example',
                      'displayName': 'Guest $i',
                      'responseStatus': 'needsAction',
                    },
                ],
              }, a.id)!,
          provider: MailProvider.gmail,
          size: const Size(412, 1600));
      expect(countsOf(tester),
          '2 accepted · 10 not answered');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(heard(tester, 'Guest 1'), startsWith('Guest 1, not answered'));
    });
  });

  // Seen on the tablet (2026-11-16), on a Hadco meeting someone else
  // organised, which the group above had guessed at: Ron's copy does carry
  // the other people's answers (eight of the eleven had accepted). The
  // organiser's own entry comes as "none", its address in other letters
  // than the organiser's, and so does one who has not answered. 3.17.0 drew
  // the organiser as not answered, with no Organiser beside the address,
  // and gave no counts at all.
  group("someone else's meeting as Exchange Online gives Ron's copy of it",
      () {
    final toggle = find.byKey(const ValueKey('event-people'));

    Map<String, Object?> person(String name, String address, String answer) =>
        {
          'type': 'required',
          'status': {'response': answer},
          'emailAddress': {'name': name, 'address': address},
        };

    /// Dana's meeting next week: Dana's own entry "none", Ron and
    /// [accepted] more accepted, [declined] declined, [silent] "none".
    CalendarEvent live(
      Account a, {
      int accepted = 7,
      int declined = 0,
      int silent = 2,
      String mine = 'accepted',
    }) =>
        GraphCalendarApi.eventFrom({
          'id': 'm',
          'subject': 'Weekly sales',
          'start': {'dateTime': '2026-11-24T08:00:00', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-11-24T09:00:00', 'timeZone': 'UTC'},
          'isOrganizer': false,
          'responseStatus': {'response': mine},
          'organizer': {
            'emailAddress': {
              'name': 'Dana Levi',
              'address': 'Dana.Levi@Hadco.Example',
            },
          },
          'attendees': [
            person('Dana Levi', dana.email, 'none'),
            for (var i = 1; i <= accepted; i++)
              person('Guest $i', 'guest$i@hadco.example', 'accepted'),
            person('Ron', 'Ron@Hadco.example', mine),
            for (var i = 1; i <= declined; i++)
              person('Sorry $i', 'sorry$i@hadco.example', 'declined'),
            for (var i = 1; i <= silent; i++)
              person('Quiet $i', 'quiet$i@hadco.example', 'none'),
          ],
        }, a.id)!;

    ListTile rowOf(WidgetTester tester, String name) => tester.widget(
        find.ancestor(of: find.text(name), matching: find.byType(ListTile)));

    String heard(WidgetTester tester, String name) => tester
        .getSemantics(
            find.ancestor(of: find.text(name), matching: find.byType(ListTile)))
        .label;

    test("the organiser's own entry is the organiser's, whatever letters "
        'its address is in', () {
      final e = GraphCalendarApi.eventFrom({
        'id': 'm',
        'subject': 'Weekly sales',
        'start': {'dateTime': '2026-11-24T08:00:00', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-11-24T09:00:00', 'timeZone': 'UTC'},
        'organizer': {
          'emailAddress': {'name': 'Dana', 'address': 'Dana.Levi@Hadco.Example'},
        },
        'attendees': [
          person('Dana Levi', ' dana.levi@hadco.example', 'none'),
          person('Guest', 'guest@hadco.example', 'none'),
          person('Other Dana', 'dana.levi@elsewhere.example', 'accepted'),
        ],
      }, 'acct')!;
      expect([for (final a in e.attendees) a.response], [
        EventResponse.organizer,
        EventResponse.none,
        EventResponse.accepted,
      ]);
    });

    testWidgets('the organiser is drawn as the organiser: the accepted mark, '
        'Organiser beside the address, and said so', (tester) async {
      await pump(tester, live, size: const Size(412, 1800));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final row = rowOf(tester, 'Dana Levi');
      expect((row.subtitle! as Text).data, contains('Organiser'));
      expect((row.leading! as Icon).icon, Icons.check_circle_outline);
      expect(heard(tester, 'Dana Levi'), startsWith('Dana Levi, accepted'));
    });

    testWidgets('the answers are counted, the organiser with those who '
        'accepted, and one given as none is not answered', (tester) async {
      await pump(tester, live, size: const Size(412, 1800));
      expect(find.descendant(of: toggle, matching: find.text('11 people')),
          findsOneWidget);
      expect(countsOf(tester), '9 accepted · 2 not answered');

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(9));
      expect(heard(tester, 'Quiet 1'), startsWith('Quiet 1, not answered'));
      expect(heard(tester, 'Guest 3'), startsWith('Guest 3, accepted'));
    });

    testWidgets('a declined one is counted too, and the counts add up to '
        'the heading', (tester) async {
      await pump(tester,
          (a) => live(a, accepted: 4, declined: 2, silent: 3, mine: 'none'),
          size: const Size(412, 1800));
      // Dana, four guests; two declined; three quiet and Ron, who has not
      // answered either.
      expect(find.descendant(of: toggle, matching: find.text('11 people')),
          findsOneWidget);
      expect(countsOf(tester), '5 accepted · 2 declined · 4 not answered');
    });

    testWidgets('where nobody but Ron and the organiser has an answer, '
        'nothing is counted: nothing says the copy carries any',
        (tester) async {
      await pump(tester, (a) => live(a, accepted: 0, silent: 9),
          size: const Size(412, 1800));
      expect(find.descendant(of: toggle, matching: find.text('11 people')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('event-answers')), findsNothing);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(heard(tester, 'Quiet 1'), startsWith('Quiet 1\n'),
          reason: 'not known, so not said to be not answered');
      // The organiser is still the organiser.
      expect((rowOf(tester, 'Dana Levi').subtitle! as Text).data,
          contains('Organiser'));
    });

    testWidgets('six or fewer are listed with no counts, as before, each '
        'with the answer the copy has', (tester) async {
      await pump(tester, (a) => live(a, accepted: 2, silent: 1),
          size: const Size(412, 1800));
      expect(toggle, findsNothing);
      expect(find.byKey(const ValueKey('event-answers')), findsNothing);
      expect(heard(tester, 'Quiet 1'), startsWith('Quiet 1, not answered'));
      expect(heard(tester, 'Dana Levi'), startsWith('Dana Levi, accepted'));
    });
  });

  group('the keys through the sheet (#93)', () {
    /// The key of what has the focus, the nearest one round it.
    String? focused() {
      final at = FocusManager.instance.primaryFocus?.context;
      if (at == null) return null;
      String? key;
      void look(Element e) {
        final k = e.widget.key;
        if (key == null && k is ValueKey<String>) key = k.value;
      }

      look(at as Element);
      at.visitAncestorElements((e) {
        look(e);
        return key == null;
      });
      return key;
    }

    testWidgets('Tab goes down the sheet as it is drawn, and Enter answers '
        'from the button with the focus', (tester) async {
      await pump(tester,
          (a) => invited(a,
              start: at(10, 0, 7),
              location: 'Café Noir, 12 Main St',
              webLink: outlook,
              preview: [for (var i = 1; i <= 20; i++) 'Point $i.'].join('\n')));
      final seen = <String>[];
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final key = focused();
        if (key == null || seen.contains(key)) break;
        seen.add(key);
      }
      expect(seen, [
        'event-more',
        'place-link',
        'event-accept',
        'event-tentative',
        'event-decline',
        'event-join',
        // The notes' words, which can be selected, then Show more.
        'event-notes',
        'linked-text-more',
        'event-mail-about',
      ]);

      // Back to Accept, and Enter asks how the answer goes.
      for (var i = 0; i < 12 && focused() != 'event-accept'; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Send the response now'), findsOneWidget);
    });

    testWidgets('Tab reaches a long list of people, folded, after the notes, '
        'and Enter opens it', (tester) async {
      await pump(tester,
          (a) => invited(a, start: at(10, 0, 7), more: guests(10, [yes])),
          size: const Size(412, 1600));
      final seen = <String>[];
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final key = focused();
        if (key == null || seen.contains(key)) break;
        seen.add(key);
      }
      expect(seen, [
        'event-more',
        'event-accept',
        'event-tentative',
        'event-decline',
        'event-join',
        'event-people',
        'event-mail-about',
      ]);
      for (var i = 0; i < 12 && focused() != 'event-people'; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Guest 1'), findsOneWidget);
    });
  });
}
