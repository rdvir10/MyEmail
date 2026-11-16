import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/account_calendars.dart' show CalendarInfo;
import 'package:myemail/domain/account_colours.dart' show newAccountColours;
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/my_day_pane.dart';
import 'package:myemail/ui/calendar/next_meeting_bar.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart'
    show NewMeetingScreen;

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// What is around the calendar's grid, as it looks: the title bar, the
/// Agenda's rows, the meeting's sheet, the lists and the buttons (calendar
/// ideas #88, #90, #91 and #100), at a phone's and a tablet's size, at text
/// sizes 1.0 and 1.3, on either clock, light and dark. Drawn with the app's
/// own theme, whose compact density sets the buttons' sizes, in Roboto,
/// whose widths decide what fits.
void main() {
  setUpAll(() async {
    FakeWebViewPlatform.install();
    await loadRoboto();
  });

  const phone = Size(412, 915);
  const narrowPhone = Size(360, 780);
  const tablet = Size(1280, 800);

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime at(int hour, [int minute = 0, int days = 0]) {
    final t = today();
    return DateTime(t.year, t.month, t.day + days, hour, minute);
  }

  /// The calendar, at [size] and text size [scale], in [view], with Hadco's
  /// [events] and, with [gmail], a second account so that Calendars shown
  /// is offered. [clock] is the time as what is said about meetings sees
  /// it.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Widget Function(Account hadco)? home,
    Size size = phone,
    double scale = 1.0,
    bool use24h = true,
    bool dark = false,
    bool bold = false,
    String view = 'agenda',
    bool gmail = false,
    DateTime Function()? clock,
    List<CalendarEvent> Function(Account hadco)? events,
    Future<void> Function(SampleMailEngine engine)? prepare,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = SampleMailEngine();
    final token = OAuthToken(
      accessToken: 'a',
      refreshToken: 'r',
      expiresAt: DateTime.utc(2030),
    );
    final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
          displayName: 'Hadco',
          emailAddress: 'ron@hadco.example',
          provider: MailProvider.outlook,
          token: token,
        )))!;
    if (gmail) {
      await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Gmail',
            emailAddress: 'ron@gmail.example',
            provider: MailProvider.gmail,
            token: token,
          ));
    }
    engine.events[hadco.id] = events?.call(hadco) ?? const [];
    if (prepare != null) await tester.runAsync(() => prepare(engine));
    final ui = MemoryUiStateStore();
    await ui.writeString(UiStateKeys.calendarView, view);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(
          FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      if (clock != null) meetingClockProvider.overrideWithValue(clock),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: home?.call(hadco) ?? const CalendarScreen(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: use24h,
            textScaler: TextScaler.linear(scale),
            boldText: bold,
          ),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  const dana = MailAddress(email: 'dana@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');

  /// A meeting of Dana's on Hadco's calendar, Ron invited.
  CalendarEvent invited(
    Account hadco,
    String id,
    String title,
    DateTime start,
    DateTime end, {
    String location = '',
    String? joinUrl,
    EventResponse response = EventResponse.notResponded,
    EventShowAs showAs = EventShowAs.busy,
    bool allDay = false,
    String? webLink,
    String preview = '',
  }) =>
      CalendarEvent(
        id: id,
        accountId: hadco.id,
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        location: location,
        joinUrl: joinUrl,
        webLink: webLink,
        organizer: dana,
        attendees: [
          const EventAttendee(dana, response: EventResponse.organizer),
          EventAttendee(ron, response: response),
        ],
        response: response,
        showAs: showAs,
        preview: preview,
      );

  /// A button that opens [event]'s sheet, from [hadco].
  Widget sheetHost(Account hadco, CalendarEvent event) => Scaffold(
        body: Consumer(
          builder: (context, ref, _) => Center(
            child: TextButton(
              key: const ValueKey('open-sheet'),
              onPressed: () => showEventDetails(context, ref, event, hadco),
              child: const Text('Open'),
            ),
          ),
        ),
      );

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();
  }

  /// Whether a tap at [point] reaches [button]: the pointer's path goes
  /// through it.
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

  /// [button] answers a tap over 48 dp of height: 23 dp above and below
  /// its middle, at its middle across, reach it. The button itself stays
  /// as the app's compact look draws it.
  void tallEnough(WidgetTester tester, Finder button, {Finder? across}) {
    expect(button, findsOneWidget);
    final middle = tester.getCenter(button);
    final x = across == null ? middle.dx : tester.getCenter(across).dx;
    for (final dy in [-23.0, 23.0]) {
      expect(reaches(tester, button, Offset(x, middle.dy + dy)), isTrue,
          reason: '${button.describeMatch(Plurality.one)}: a tap ${dy.abs()} '
              '${dy < 0 ? 'above' : 'below'} its middle does not reach it');
    }
  }

  /// The paragraph drawing [text]'s words.
  RenderParagraph paragraphOf(WidgetTester tester, Finder text) =>
      tester.renderObject<RenderParagraph>(find
          .descendant(of: text, matching: find.byType(RichText), matchRoot: true)
          .first);

  /// Whether [p] shows all of its words: no line cut, none left out, and
  /// as wide as its words need.
  bool whole(RenderParagraph p) =>
      !p.didExceedMaxLines &&
      p.getMaxIntrinsicWidth(double.infinity) <= p.size.width + 0.5;

  group("the calendar's title (#88)", () {
    final title = find.byKey(const ValueKey('calendar-title'));

    String shown(WidgetTester tester) =>
        paragraphOf(tester, find.descendant(of: title, matching: find.byType(Text)))
            .text
            .toPlainText();

    /// The calendar opened on [day] as the app opens it, pushed over the
    /// mail: its bar has the back arrow, and the title the room it leaves.
    Future<void> openOn(
      WidgetTester tester,
      DateTime day, {
      Size size = phone,
      double scale = 1.0,
      String view = 'agenda',
      bool gmail = false,
    }) async {
      await pump(tester,
          size: size,
          scale: scale,
          view: view,
          gmail: gmail,
          home: (_) => const Scaffold(body: SizedBox.expand()));
      unawaited(CalendarScreen.open(tester.element(find.byType(Scaffold)),
          day: day));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
    }

    Future<void> showView(WidgetTester tester, String view) async {
      await tester.tap(find.byKey(ValueKey('calendar-view-$view')));
      await tester.pumpAndSettle();
    }

    // What each page may be called, longest first: the page's month or
    // months, with the year where it fits.
    const november = ['November 2026', 'Nov 2026', 'Nov'];
    const december = ['December 2026', 'Dec 2026', 'Dec'];
    const novemberToDecember = [
      'Nov – Dec 2026',
      'Nov–Dec 2026',
      'Nov – Dec',
      'Nov–Dec',
      'Nov',
    ];
    // Over two years: both years, or none rather than one of them.
    const decemberToJanuary = [
      'Dec 2026 – Jan 2027',
      'Dec – Jan',
      'Dec–Jan',
      'Dec',
    ];
    // A day in the middle of a month, a month's last but one, and a
    // year's: three days from either run into the next month.
    final days = {
      'mid-month': (
        DateTime(2026, 11, 17),
        {'agenda': november, 'day': november, 'week': november,
            'month': november},
      ),
      "a month's end": (
        DateTime(2026, 11, 30),
        {'agenda': november, 'day': november, 'week': novemberToDecember,
            'month': november},
      ),
      "a year's end": (
        DateTime(2026, 12, 30),
        {'agenda': december, 'day': december, 'week': decemberToJanuary,
            'month': december},
      ),
    };

    for (final MapEntry(key: name, value: (day, names)) in days.entries) {
      for (final size in [phone, narrowPhone]) {
        for (final scale in [1.0, 1.3]) {
          testWidgets('on a phone ${size.width.round()} wide at text size '
              '$scale, $name: every view names its month or months whole, '
              'with the back arrow beside it, and is a tap high',
              (tester) async {
            await openOn(tester, day, size: size, scale: scale);
            for (final view in ['agenda', 'day', 'week', 'month']) {
              await showView(tester, view);
              final words = shown(tester);
              expect(names[view], contains(words),
                  reason: '$view: "$words" is not one of its names');
              expect(words, isNot(contains('…')), reason: view);
              expect(whole(paragraphOf(tester,
                  find.descendant(of: title, matching: find.byType(Text)))),
                  isTrue,
                  reason: '$view: "$words" is cut');
              expect(tester.getSize(title).height,
                  greaterThanOrEqualTo(kMinInteractiveDimension));
              // At the usual size every phone says the year of a month,
              // and both months of a page over two.
              if (scale == 1.0) {
                expect(words, anyOf(contains('2026'), contains('–')),
                    reason: '$view: "$words"');
              }
              // A wider phone has the room for the year with both months
              // of one year.
              if (scale == 1.0 &&
                  size == phone &&
                  names[view] != decemberToJanuary) {
                expect(words, contains(RegExp('20(26|27)')),
                    reason: '$view: "$words"');
              }
            }
          });
        }
      }
    }

    testWidgets('a screen reader hears the whole month and year, however '
        'short the title is', (tester) async {
      await openOn(tester, DateTime(2026, 11, 30),
          size: narrowPhone, scale: 1.3, view: 'week');
      expect(shown(tester), isNot('Nov – Dec 2026'));
      expect(find.bySemanticsLabel('Nov – Dec 2026'), findsOneWidget);
    });

    testWidgets('with Bold text on, the title is measured bold: whole at '
        'every phone width', (tester) async {
      await pump(tester,
          size: narrowPhone,
          bold: true,
          home: (_) => const Scaffold(body: SizedBox.expand()));
      unawaited(CalendarScreen.open(tester.element(find.byType(Scaffold)),
          day: DateTime(2026, 11, 30)));
      await tester.pumpAndSettle();
      for (final view in ['agenda', 'week']) {
        await showView(tester, view);
        for (var width = 360.0; width <= 412; width += 2) {
          tester.view.physicalSize = Size(width, narrowPhone.height);
          await tester.pumpAndSettle();
          final words = shown(tester);
          expect(whole(paragraphOf(tester,
              find.descendant(of: title, matching: find.byType(Text)))),
              isTrue,
              reason: '$view at $width: "$words" is cut');
        }
      }
    });

    testWidgets('the tablet keeps its bar: the whole month, ‹ ›, Search, '
        'Today, Calendars shown and More',
        (tester) async {
      await openOn(tester, DateTime(2026, 11, 17),
          size: tablet, view: 'month', gmail: true);
      expect(shown(tester), 'November 2026');
      for (final key in [
        'calendar-previous',
        'calendar-next',
        'calendar-search',
        'calendar-today',
        'calendar-accounts',
        'calendar-menu',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('on a phone the bar keeps Search, Today and More; ‹ ›, and '
        'Calendars shown, worded the same, are under More', (tester) async {
      await openOn(tester, DateTime(2026, 11, 17), view: 'day', gmail: true);
      expect(find.byKey(const ValueKey('calendar-search')), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-today')), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-previous')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-next')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-accounts')), findsNothing);

      String day(DateTime d) => '${d.year}-${d.month}-${d.day}';
      final t = DateTime(2026, 11, 17);
      final tomorrow = DateTime(t.year, t.month, t.day + 1);

      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Day before'), findsOneWidget);
      await tester.tap(find.text('Day after'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('day-head:${day(tomorrow)}')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Day before'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('day-head:${day(t)}')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Calendars shown'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Calendars shown'), findsOneWidget,
          reason: 'its sheet');
    });

    testWidgets("on a phone, More's ‹ › go a week in Agenda, as the buttons "
        'did', (tester) async {
      final t = DateTime(2026, 11, 30);
      await openOn(tester, t);
      String day(DateTime d) => '${d.year}-${d.month}-${d.day}';
      await tester.tap(find.byKey(const ValueKey('calendar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Week after'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(ValueKey(
              'agenda-day:${day(DateTime(t.year, t.month, t.day + 7))}')),
          findsOneWidget);
    });
  });

  group("Who is free follows the phone's clock (#88)", () {
    /// New meeting at nine tomorrow, its Who is free open on the day's
    /// hours.
    Future<void> openWhoIsFree(
      WidgetTester tester, {
      Size size = phone,
      double scale = 1.0,
      required bool use24h,
    }) async {
      await pump(tester,
          size: size,
          scale: scale,
          use24h: use24h,
          home: (hadco) => NewMeetingScreen(
                accountId: hadco.id,
                start: at(9, 0, 1),
              ));
      await tester.tap(find.byKey(const ValueKey('who-is-free')));
      await tester.pumpAndSettle();
    }

    final scale = find.byKey(const ValueKey('assistant-hours'));

    List<String> labels(WidgetTester tester) => [
          for (final t in tester.widgetList<Text>(
              find.descendant(of: scale, matching: find.byType(Text))))
            t.data!,
        ];

    /// Each hour's label whole, inside the scale, and clear of the next.
    void fits(WidgetTester tester) {
      final box = tester.getRect(scale);
      final texts =
          find.descendant(of: scale, matching: find.byType(Text)).evaluate();
      expect(texts.length, greaterThanOrEqualTo(3));
      Rect? before;
      for (final e in texts) {
        final p = e.findRenderObject()! as RenderParagraph;
        final rect = tester.getRect(find.byWidget(e.widget));
        expect(whole(p), isTrue, reason: '${p.text.toPlainText()} is cut');
        expect(rect.top >= box.top - 0.5 && rect.bottom <= box.bottom + 0.5,
            isTrue,
            reason: '${p.text.toPlainText()} is taller than its line');
        expect(rect.left >= box.left - 0.5 && rect.right <= box.right + 0.5,
            isTrue,
            reason: '${p.text.toPlainText()} is outside the scale');
        if (before != null) {
          expect(rect.left - before.right, greaterThanOrEqualTo(4),
              reason: '${p.text.toPlainText()} runs into the one before');
        }
        before = rect;
      }
    }

    testWidgets('on a 12-hour clock its hours are "8 AM" to "8 PM", as the '
        'times over them are', (tester) async {
      await openWhoIsFree(tester, use24h: false);
      expect(find.byKey(const ValueKey('assistant-time')), findsOneWidget);
      expect(labels(tester),
          ['8 AM', '10 AM', '12 PM', '2 PM', '4 PM', '6 PM', '8 PM']);
      fits(tester);
    });

    testWidgets('on a 24-hour clock they stay "08:00" to "20:00"',
        (tester) async {
      await openWhoIsFree(tester, use24h: true);
      expect(labels(tester),
          ['08:00', '10:00', '12:00', '14:00', '16:00', '18:00', '20:00']);
      fits(tester);
    });

    for (final use24h in [false, true]) {
      testWidgets('on the narrow phone at text size 1.3 they fit, fewer of '
          'them, on a ${use24h ? 24 : 12}-hour clock', (tester) async {
        await openWhoIsFree(tester,
            size: narrowPhone, scale: 1.3, use24h: use24h);
        expect(labels(tester).first, use24h ? '08:00' : '8 AM');
        expect(labels(tester).last, use24h ? '20:00' : '8 PM');
        fits(tester);
      });
    }
  });

  group('the Agenda and the buttons at large text and in the dark (#90)', () {
    const supplier = 'Supplier call – Northwind Metals: Q1 pricing, lead '
        'times and the delivery schedule';
    const design = 'Design review – bracket redesign for Line 3';

    List<CalendarEvent> day(Account hadco) => [
          invited(hadco, 'count', 'Inventory count – Warehouse B', at(0),
              at(0, 0, 1),
              allDay: true,
              showAs: EventShowAs.free,
              response: EventResponse.accepted),
          invited(hadco, 'supplier', supplier, at(10), at(11),
              location: 'Room 4 (2nd floor), Hadco HQ',
              joinUrl: 'https://teams.microsoft.com/l/x'),
          invited(hadco, 'lunch', 'Lunch with Tom', at(12), at(13),
              location: 'Café Noir, 12 Main St',
              response: EventResponse.accepted),
          invited(hadco, 'yael', '1:1 with Yael', at(16, 30), at(17),
              response: EventResponse.accepted),
          // Waiting for an answer whatever the time the test runs at.
          invited(hadco, 'design', design, at(11, 0, 1), at(12, 0, 1),
              location: 'Room 4 (2nd floor), Hadco HQ'),
        ];

    Finder row(String id) => find.byKey(ValueKey('agenda-event:$id'));
    Finder bar(String id) => find.byKey(ValueKey('agenda-bar:$id'));
    Finder inRow(String id, String text) =>
        find.descendant(of: row(id), matching: find.text(text));

    // The design review's answers in the waiting list: it waits at any
    // hour, tomorrow, where today's supplier call waits only until it ends
    // at eleven.
    Finder waitingRow(String id) => find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('waiting-event:') &&
        (w.key! as ValueKey<String>).value.endsWith('|$id'));
    Finder answer(String key) => find.descendant(
        of: waitingRow('design'), matching: find.byKey(ValueKey(key)));

    /// The colour [id]'s bar is painted in.
    Color barColour(WidgetTester tester, String id) {
      final w = tester.widget(bar(id));
      final decoration = switch (w) {
        Container(:final decoration) => decoration,
        DecoratedBox(:final decoration) => decoration,
        _ => null,
      };
      return (decoration! as BoxDecoration).color!;
    }

    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    for (final (size, scale) in [(phone, 1.0), (narrowPhone, 1.3)]) {
      testWidgets('on a 12-hour clock at text size $scale, '
          '${size.width.round()} wide: each time on one line, clear of the '
          'colour bar; the bar as tall as its row; "Not answered" whole',
          (tester) async {
        await pump(tester,
            size: size, scale: scale, use24h: false, events: day);
        for (final (id, times) in [
          ('supplier', ['10:00 AM', '11:00 AM']),
          ('lunch', ['12:00 PM', '1:00 PM']),
          ('count', ['All day']),
        ]) {
          final barRect = tester.getRect(bar(id));
          for (final time in times) {
            final text = inRow(id, time);
            expect(text, findsOneWidget, reason: time);
            expect(whole(paragraphOf(tester, text)), isTrue,
                reason: '$time wraps or is cut');
            expect(barRect.left - tester.getRect(text).right,
                greaterThanOrEqualTo(4),
                reason: '$time touches the colour bar');
          }
          // The row's words, inside its padding: the bar is as tall.
          final content = tester.getRect(row(id)).deflate(8);
          expect(barRect.top, moreOrLessEquals(content.top, epsilon: 0.5));
          expect(barRect.height,
              moreOrLessEquals(math.max(40, content.height), epsilon: 0.5),
              reason: "$id's bar is not as tall as its row");
        }
        final answer = find.descendant(
            of: row('supplier'), matching: find.textContaining('Not answered'));
        expect(answer, findsOneWidget);
        final p = paragraphOf(tester, answer);
        expect(whole(p), isTrue, reason: '"${p.text.toPlainText()}" is cut');
      });
    }

    testWidgets('on a 24-hour clock at the usual size the times keep their '
        '64 dp column', (tester) async {
      await pump(tester, events: day);
      final title = tester.getRect(inRow('lunch', 'Lunch with Tom'));
      expect(title.left, 16 + 64 + 4 + 12);
      expect(tester.getRect(bar('lunch')).left, 16 + 64);
    });

    for (final dark in [false, true]) {
      testWidgets("a free all-day event's bar in the "
          "${dark ? 'dark' : 'light'} theme, in each of the eight colours "
          'new accounts are given', (tester) async {
        final ids = <String>[];
        await pump(tester, dark: dark, prepare: (engine) async {
          for (var i = 0; i < newAccountColours.length; i++) {
            final a = await engine.addOAuthAccount(
              displayName: 'Account $i',
              emailAddress: 'ron$i@example.com',
              provider: MailProvider.outlook,
              token: OAuthToken(
                accessToken: 'a',
                refreshToken: 'r',
                expiresAt: DateTime.utc(2030),
              ),
            );
            ids.add('free-$i');
            engine.events[a.id] = [
              CalendarEvent(
                id: 'free-$i',
                accountId: a.id,
                title: 'Free $i',
                start: at(0),
                end: at(0, 0, 1),
                allDay: true,
                showAs: EventShowAs.free,
              ),
            ];
          }
        });
        final page = Theme.of(tester.element(row(ids.first)))
            .scaffoldBackgroundColor;
        final seen = <int>{};
        for (final id in ids) {
          final painted = barColour(tester, id);
          if (dark) {
            // Seen against the page, as a part of the screen must be.
            expect(contrast(Color.alphaBlend(painted, page), page),
                greaterThanOrEqualTo(3),
                reason: '$id is hard to see');
          } else {
            // As it always was: the colour, faint.
            expect(painted.a, moreOrLessEquals(110 / 255, epsilon: 0.01),
                reason: id);
            seen.add(painted.toARGB32() | 0xFF000000);
          }
        }
        if (!dark) expect(seen, {...newAccountColours});
      });
    }

    testWidgets("the waiting list's buttons start under the title, as the "
        'times grow', (tester) async {
      await pump(tester,
          size: narrowPhone, scale: 1.3, use24h: false, events: day);
      await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
      await tester.pumpAndSettle();
      final accept = answer('waiting-accept');
      expect(accept, findsOneWidget);
      expect(tester.getRect(accept).left,
          moreOrLessEquals(tester.getRect(find.text(design)).left,
              epsilon: 0.5));
    });

    for (final (size, scale) in [
      (narrowPhone, 1.0),
      (phone, 1.3),
      (narrowPhone, 1.3),
      (narrowPhone, 2.0),
    ]) {
      testWidgets("the waiting list's answers stay whole and on the screen, "
          '${size.width.round()} wide at text size $scale on a 12-hour clock',
          (tester) async {
        await pump(tester,
            size: size, scale: scale, use24h: false, events: day);
        await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final title = tester.getRect(find.text(design));
        for (final key in [
          'waiting-accept',
          'waiting-tentative',
          'waiting-decline',
        ]) {
          final button = answer(key);
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          final rect = tester.getRect(button);
          expect(rect.left, greaterThanOrEqualTo(title.left - 0.5),
              reason: key);
          expect(rect.right, lessThanOrEqualTo(size.width - 16 + 0.5),
              reason: '$key runs past the edge');
          final label =
              find.descendant(of: button, matching: find.byType(Text));
          final p = paragraphOf(tester, label);
          expect(whole(p), isTrue,
              reason: '"${p.text.toPlainText()}" is cut');
          expect(p.size.height,
              lessThan(2 * p.preferredLineHeight - 0.5),
              reason: '"${p.text.toPlainText()}" takes two lines');
        }
      });
    }

    group("the calendar's buttons answer a tap over 48 dp", () {
      testWidgets("an invitation's sheet: Accept, Maybe, Decline, Join, "
          'Running late, Open in Outlook, Mail about this meeting and Show '
          'more', (tester) async {
        final now = DateTime.now();
        await pump(tester,
            home: (hadco) => sheetHost(
                hadco,
                invited(hadco, 'call', 'Supplier call',
                    now.subtract(const Duration(minutes: 10)),
                    now.add(const Duration(minutes: 50)),
                    joinUrl: 'https://teams.microsoft.com/l/x',
                    webLink: 'https://outlook.office.com/calendar/item/x',
                    preview: [
                      for (var i = 1; i <= 20; i++) 'Point $i of the agenda.',
                    ].join('\n'))));
        await openSheet(tester);
        for (final key in [
          'event-accept',
          'event-tentative',
          'event-decline',
          'event-join',
          'event-late',
          'event-web',
          'event-mail-about',
          'linked-text-more',
        ]) {
          await tester.ensureVisible(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
          tallEnough(tester, find.byKey(ValueKey(key)));
        }
        await tester.ensureVisible(find.byKey(const ValueKey('event-accept')));
        await tester.pumpAndSettle();
        // What a screen reader is told: the button, over the whole area.
        final told = tester
            .getSemantics(find.byKey(const ValueKey('event-accept')))
            .getSemanticsData();
        expect(told.label, 'Accept');
        expect(told.hasAction(SemanticsAction.tap), isTrue);
        expect(told.rect.height, greaterThanOrEqualTo(48));
      });

      testWidgets('a meeting of yours: Edit', (tester) async {
        await pump(tester,
            home: (hadco) => sheetHost(
                hadco,
                CalendarEvent(
                  id: 'mine',
                  accountId: hadco.id,
                  title: 'Q4 planning',
                  start: at(15, 0, 1),
                  end: at(16, 0, 1),
                  organizer: ron,
                  attendees: const [
                    EventAttendee(ron, response: EventResponse.organizer),
                    EventAttendee(dana, response: EventResponse.accepted),
                  ],
                  response: EventResponse.organizer,
                )));
        await openSheet(tester);
        tallEnough(tester, find.byKey(const ValueKey('event-edit')));
      });

      testWidgets("the view switcher, and the waiting list's answers",
          (tester) async {
        await pump(tester, events: day);
        for (final view in ['agenda', 'day', 'week', 'month']) {
          tallEnough(
              tester,
              find.ancestor(
                  of: find.byKey(ValueKey('calendar-view-$view')),
                  matching: find.byType(TextButton)));
        }
        await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
        await tester.pumpAndSettle();
        for (final key in [
          'waiting-accept',
          'waiting-tentative',
          'waiting-decline',
        ]) {
          tallEnough(tester, answer(key));
        }
      });

      testWidgets("Open day, under a phone's month", (tester) async {
        await pump(tester, view: 'month', events: day);
        // Not today, which is picked already: a second tap opens Day.
        final t = today();
        final other = DateTime(t.year, t.month, t.day == 10 ? 11 : 10);
        await tester.tap(find.byKey(
            ValueKey('month-day:${other.year}-${other.month}-${other.day}')));
        await tester.pumpAndSettle();
        tallEnough(tester, find.byKey(const ValueKey('month-open-day')));
      });

      testWidgets('Who is free, on New meeting', (tester) async {
        await pump(tester,
            home: (hadco) =>
                NewMeetingScreen(accountId: hadco.id, start: at(9, 0, 1)));
        tallEnough(tester, find.byKey(const ValueKey('who-is-free')));
      });

      testWidgets("the next meeting's Join, over the mail, and the bar no "
          'taller', (tester) async {
        final clock = at(9, 50);
        await pump(tester,
            clock: () => clock,
            home: (_) => const Scaffold(
                  body: Column(children: [
                    NextMeetingBar(),
                    Expanded(child: SizedBox()),
                  ]),
                ),
            events: (hadco) => [
                  invited(hadco, 'next', 'Weekly sync', at(10), at(10, 30),
                      joinUrl: 'https://teams.microsoft.com/l/x',
                      response: EventResponse.accepted),
                ]);
        tallEnough(tester, find.byKey(const ValueKey('next-meeting-join')));
        expect(
            tester
                .getSize(find.byKey(const ValueKey('next-meeting-bar')))
                .height,
            48);
      });
    });
  });

  group('the Agenda shows where you are in the day (#91)', () {
    List<CalendarEvent> day(Account hadco) => [
          invited(hadco, 'count', 'Inventory count – Warehouse B', at(0),
              at(0, 0, 1),
              allDay: true,
              showAs: EventShowAs.free,
              response: EventResponse.accepted),
          invited(hadco, 'standup', 'Daily stand-up', at(9), at(9, 30),
              response: EventResponse.accepted),
          invited(hadco, 'quality', 'Quality review – Line 3', at(9, 30),
              at(10),
              response: EventResponse.accepted),
          invited(hadco, 'supplier', 'Supplier call', at(10), at(11),
              location: 'Room 4 (2nd floor), Hadco HQ'),
          invited(hadco, 'budget', 'Budget sign-off', at(10, 30),
              at(11, 15),
              response: EventResponse.tentative),
          invited(hadco, 'lunch', 'Lunch with Tom', at(12), at(13),
              response: EventResponse.accepted),
          invited(hadco, 'tomorrow', 'Design review', at(9, 0, 1),
              at(10, 0, 1),
              response: EventResponse.accepted),
        ];

    Finder row(String id) => find.byKey(ValueKey('agenda-event:$id'));
    bool dimmed(WidgetTester tester, String id) => find
        .ancestor(
            of: row(id),
            matching: find.byWidgetPredicate(
                (w) => w is Opacity && w.opacity < 1))
        .evaluate()
        .isNotEmpty;
    bool markedNow(String id) =>
        find.descendant(of: row(id), matching: find.text('Now')).evaluate()
            .isNotEmpty;

    testWidgets("today's finished meetings dimmed, the one on now says Now, "
        'and both keep up with the clock', (tester) async {
      var clock = at(10, 17);
      await pump(tester, clock: () => clock, events: day);

      expect(dimmed(tester, 'standup'), isTrue);
      expect(dimmed(tester, 'quality'), isTrue, reason: 'over at ten');
      for (final id in ['count', 'supplier', 'budget', 'lunch', 'tomorrow']) {
        expect(dimmed(tester, id), isFalse, reason: id);
      }
      expect(markedNow('supplier'), isTrue);
      for (final id in ['count', 'standup', 'budget', 'lunch', 'tomorrow']) {
        expect(markedNow(id), isFalse, reason: id);
      }
      // "Now" in the times, where the eye looks for the time.
      final now = find.descendant(of: row('supplier'), matching: find.text('Now'));
      expect(tester.getRect(now).right,
          lessThanOrEqualTo(tester.getRect(
              find.byKey(const ValueKey('agenda-bar:supplier'))).left));
      expect(whole(paragraphOf(tester, now)), isTrue);

      // Five past eleven: the call is over, the sign-off is on.
      clock = at(11, 5);
      await tester.pump(const Duration(seconds: 30));
      expect(dimmed(tester, 'supplier'), isTrue);
      expect(markedNow('supplier'), isFalse);
      expect(markedNow('budget'), isTrue);
      expect(dimmed(tester, 'count'), isFalse,
          reason: 'a whole day is neither over nor on now');
    });

    testWidgets('the waiting list draws the same row, and nothing there is '
        'dimmed or marked', (tester) async {
      final now = DateTime.now();
      await pump(tester,
          clock: DateTime.now,
          events: (hadco) => [
                invited(hadco, 'on', 'Supplier call',
                    now.subtract(const Duration(minutes: 10)),
                    now.add(const Duration(minutes: 50))),
              ]);
      expect(markedNow('on'), isTrue, reason: 'on now, in the Agenda');
      await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for your answer'), findsOneWidget);
      final waiting = find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('waiting-event:'));
      expect(waiting, findsOneWidget);
      expect(find.descendant(of: waiting, matching: find.text('Now')),
          findsNothing);
      expect(
          find.descendant(
              of: waiting,
              matching: find.byWidgetPredicate(
                  (w) => w is Opacity && w.opacity < 1)),
          findsNothing);
    });
  });

  group('four small slips outside the grid (#100)', () {
    testWidgets('search lists this morning under "Earlier today", between '
        'those to come and "Before today"', (tester) async {
      await pump(tester,
          clock: () => at(10, 17),
          events: (hadco) => [
                invited(hadco, 'quality', 'Quality review – Line 3', at(9, 30),
                    at(10),
                    location: 'Room 2', response: EventResponse.accepted),
                invited(hadco, 'supplier', 'Supplier call', at(10), at(11),
                    location: 'Room 4'),
                invited(hadco, 'design', 'Design review', at(11, 0, 1),
                    at(12, 0, 1),
                    location: 'Room 4'),
                invited(hadco, 'board', 'Engineering change board',
                    at(14, 0, -1), at(15, 0, -1),
                    location: 'Room 2', response: EventResponse.accepted),
              ]);
      await tester.tap(find.byKey(const ValueKey('calendar-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('calendar-search-box')), 'room');
      await tester.pumpAndSettle();
      double top(Finder f) => tester.getTopLeft(f).dy;
      Finder result(String id) =>
          find.byKey(ValueKey('calendar-search-result:$id'));
      final order = [
        top(result('supplier')),
        top(result('design')),
        top(find.text('Earlier today')),
        top(result('quality')),
        top(find.text('Before today')),
        top(result('board')),
      ];
      expect(order, [...order]..sort(), reason: 'in that order down the list');
    });

    testWidgets("a meeting you organised counts the people invited, as its "
        'answers do', (tester) async {
      EventAttendee person(String name, EventResponse r) => EventAttendee(
          MailAddress(email: '${name.toLowerCase()}@hadco.example', name: name),
          response: r);
      await pump(tester,
          home: (hadco) => sheetHost(
              hadco,
              CalendarEvent(
                id: 'q4',
                accountId: hadco.id,
                title: 'Q4 planning',
                start: at(15, 0, 1),
                end: at(16, 0, 1),
                organizer: ron,
                attendees: [
                  const EventAttendee(ron, response: EventResponse.organizer),
                  person('Dana', EventResponse.accepted),
                  person('Yossi', EventResponse.accepted),
                  person('Noa', EventResponse.tentative),
                  person('Amit', EventResponse.declined),
                  person('Yael', EventResponse.notResponded),
                ],
                response: EventResponse.organizer,
              )));
      await openSheet(tester);
      expect(find.text('5 people invited'), findsOneWidget);
      expect(find.text('6 people'), findsNothing);
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('event-answers')))
              .data,
          '2 accepted · 1 tentative · 1 declined · 1 not answered');
    });

    testWidgets('a meeting you organised from another of your addresses, '
        'with nobody else on it, says what is true, not "0 people invited"',
        (tester) async {
      const alias = MailAddress(email: 'ron.d@hadco.example', name: 'Ron');
      await pump(tester,
          home: (hadco) => sheetHost(
              hadco,
              CalendarEvent(
                id: 'alone',
                accountId: hadco.id,
                title: 'Focus time',
                start: at(15, 0, 1),
                end: at(16, 0, 1),
                organizer: alias,
                attendees: const [
                  EventAttendee(alias, response: EventResponse.organizer),
                ],
                response: EventResponse.organizer,
              )));
      await openSheet(tester);
      expect(find.textContaining('0 people'), findsNothing);
      expect(find.text('1 person'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-answers')), findsNothing,
          reason: 'no answers to count, and no empty line for them');
    });

    testWidgets("someone else's meeting still counts everyone on it",
        (tester) async {
      await pump(tester,
          home: (hadco) => sheetHost(
              hadco,
              invited(hadco, 'call', 'Supplier call', at(15, 0, 1),
                  at(16, 0, 1))));
      await openSheet(tester);
      expect(find.text('2 people'), findsOneWidget);
    });

    group('a Hebrew title reads from the right', () {
      const hebrew = 'פגישה עם רואה החשבון';
      const place = 'רחוב הרצל 12, תל אביב';

      /// [title]'s words laid out from the right: right to left, its box as
      /// wide as the room, its first letter at the right.
      void fromTheRight(WidgetTester tester, Finder title) {
        expect(title, findsOneWidget);
        final p = paragraphOf(tester, title);
        expect(p.textDirection, TextDirection.rtl);
        final start = p.getOffsetForCaret(
            const TextPosition(offset: 0), Rect.zero);
        expect(start.dx, moreOrLessEquals(p.size.width, epsilon: 1),
            reason: 'its first letter is not at the right');
      }

      List<CalendarEvent> events(Account hadco) => [
            invited(hadco, 'he', hebrew, at(9, 30, 1), at(10, 30, 1),
                location: place),
            invited(hadco, 'he-yes', 'ישיבת צוות', at(13, 0, 1),
                at(14, 0, 1),
                location: place, response: EventResponse.accepted),
            invited(hadco, 'en', 'Design review', at(11, 0, 1), at(12, 0, 1),
                response: EventResponse.accepted),
          ];

      testWidgets('in the Agenda, and the waiting list', (tester) async {
        await pump(tester, events: events);
        final row = find.byKey(const ValueKey('agenda-event:he'));
        fromTheRight(
            tester, find.descendant(of: row, matching: find.text(hebrew)));
        // A Hebrew place on its own line under it too, from the title's
        // side.
        fromTheRight(
            tester,
            find.descendant(
                of: find.byKey(const ValueKey('agenda-event:he-yes')),
                matching: find.text(place)));
        // An English title beside it as it was.
        final english = paragraphOf(tester, find.text('Design review'));
        expect(english.textDirection, TextDirection.ltr);
        expect(
            english.getOffsetForCaret(const TextPosition(offset: 0), Rect.zero)
                .dx,
            moreOrLessEquals(0, epsilon: 1),
            reason: 'an English title still starts at the left');

        await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
        await tester.pumpAndSettle();
        fromTheRight(tester, find.text(hebrew));
      });

      /// [row]'s lines on one side, the side its title reads from: its
      /// place starts where the title does, and the answer follows it on
      /// that line, or has a line of its own on that side; the answer whole
      /// and in the app's own left-to-right words.
      void oneSide(
        WidgetTester tester,
        Finder row, {
        required String title,
        required String place,
        required String answer,
        required bool fromTheRight,
      }) {
        Finder inRow(Finder f) => find.descendant(of: row, matching: f);
        final t = tester.getRect(inRow(find.text(title)));
        final p = tester.getRect(inRow(find.text(place)));
        final words = inRow(find.textContaining(answer));
        expect(words, findsOneWidget, reason: answer);
        final a = tester.getRect(words);
        final said = paragraphOf(tester, words);
        expect(whole(said), isTrue,
            reason: '"${said.text.toPlainText()}" is cut');
        expect(said.textDirection, TextDirection.ltr);
        final beside = (a.center.dy - p.center.dy).abs() < 2;
        if (fromTheRight) {
          expect(p.right, moreOrLessEquals(t.right, epsilon: 1),
              reason: '$place does not start at the right, under $title');
          if (beside) {
            expect(a.right, lessThanOrEqualTo(p.left + 0.5));
          } else {
            expect(a.right, moreOrLessEquals(t.right, epsilon: 1));
          }
        } else {
          expect(p.left, moreOrLessEquals(t.left, epsilon: 1),
              reason: '$place does not start at the left, under $title');
          if (beside) {
            expect(a.left, greaterThanOrEqualTo(p.right - 0.5));
          } else {
            expect(a.left, moreOrLessEquals(t.left, epsilon: 1));
          }
        }
      }

      const budget = 'סקירת תקציב';
      const far = 'רחוב הרצל 12, תל אביב, הקומה השלישית, חדר הישיבות הגדול';
      List<CalendarEvent> sides(Account hadco) => [
            ...events(hadco),
            invited(hadco, 'he-maybe', budget, at(15, 0, 1), at(16, 0, 1),
                location: 'Room 4', response: EventResponse.tentative),
            invited(hadco, 'en-he', 'Supplier visit', at(16, 0, 1),
                at(17, 0, 1),
                location: place),
            invited(hadco, 'he-far', 'ביקור ספק', at(17, 0, 1), at(18, 0, 1),
                location: far),
          ];

      for (final (size, scale) in [(phone, 1.0), (narrowPhone, 1.3)]) {
        testWidgets("a row's place and answer keep to its title's side, in "
            'the Agenda and the waiting list, ${size.width.round()} wide at '
            '$scale', (tester) async {
          await pump(tester, size: size, scale: scale, events: sides);
          Finder agenda(String id) => find.byKey(ValueKey('agenda-event:$id'));
          final shown = [
            (agenda('he'), hebrew, place, 'Not answered', true),
            (agenda('he-maybe'), budget, 'Room 4', 'Tentative', true),
            (agenda('en-he'), 'Supplier visit', place, 'Not answered', false),
            (agenda('he-far'), 'ביקור ספק', far, 'Not answered', true),
          ];
          for (final (row, title, where, answer, right) in shown) {
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            oneSide(tester, row,
                title: title,
                place: where,
                answer: answer,
                fromTheRight: right);
          }

          await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
          await tester.pumpAndSettle();
          Finder waiting(String id) => find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('waiting-event:') &&
              (w.key! as ValueKey<String>).value.endsWith('|$id'));
          for (final (id, title, where, right) in [
            ('he', hebrew, place, true),
            ('en-he', 'Supplier visit', place, false),
            ('he-far', 'ביקור ספק', far, true),
          ]) {
            await tester.ensureVisible(waiting(id));
            await tester.pumpAndSettle();
            oneSide(tester, waiting(id),
                title: title,
                place: where,
                answer: 'Not answered',
                fromTheRight: right);
          }
        });
      }

      testWidgets('in search', (tester) async {
        await pump(tester, events: events);
        await tester.tap(find.byKey(const ValueKey('calendar-search')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('calendar-search-box')), 'פגישה');
        await tester.pumpAndSettle();
        fromTheRight(
            tester,
            find.descendant(
                of: find.byKey(const ValueKey('calendar-search-result:he')),
                matching: find.text(hebrew)));
      });

      testWidgets('in My Day', (tester) async {
        await pump(tester,
            size: tablet,
            clock: () => at(8),
            home: (_) => const Scaffold(
                  body: Row(children: [
                    SizedBox(width: 320, child: MyDayPane()),
                    Expanded(child: SizedBox()),
                  ]),
                ),
            events: (hadco) => [
                  invited(hadco, 'he', hebrew, at(9, 30), at(10, 30)),
                ]);
        fromTheRight(
            tester,
            find.descendant(
                of: find.byKey(const ValueKey('my-day-event:he')),
                matching: find.text(hebrew)));
      });
    });

    testWidgets("Calendars shown: an account's calendars tick in line with "
        "the account's own box", (tester) async {
      late Account hadco;
      await pump(tester, size: tablet, view: 'week', prepare: (engine) async {
        hadco = (await engine.loadAccounts())
            .firstWhere((a) => a.emailAddress == 'ron@hadco.example');
        engine.calendarLists[hadco.id] = [
          CalendarInfo.main(hadco.id),
          CalendarInfo(
              accountId: hadco.id,
              id: 'BBB',
              name: 'Projects',
              colour: 0xFFE3008C),
        ];
        await engine.calendarsOf(hadco.id);
      });
      await tester.tap(find.byKey(const ValueKey('calendar-accounts')));
      await tester.pumpAndSettle();
      Rect box(String key) => tester.getRect(find.descendant(
          of: find.byKey(ValueKey('calendar-shown:$key')),
          matching: find.byType(Checkbox)));
      final account = box(hadco.id);
      for (final calendar in [
        CalendarInfo.main(hadco.id).key,
        '${hadco.id}|BBB',
      ]) {
        expect(box(calendar).left, account.left, reason: calendar);
        expect(box(calendar).right, account.right, reason: calendar);
      }
    });
  });
}
