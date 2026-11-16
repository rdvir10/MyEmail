import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/account_calendars.dart'
    show googleEventColours, outlookCategoryColours;
import 'package:myemail/domain/account_colours.dart'
    show accountPalette, newAccountColours;
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/free_busy.dart' show defaultWorkWeek;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/block_look.dart'
    show DashedOutline, inkOn;
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/meeting_ticker.dart' show MeetingTicker;

/// How Day, Week and Month look: what is on screen, measured, on a phone
/// and a tablet, at both text sizes Ron uses and on both clocks.
void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime at(int hour, [int minute = 0, int days = 0]) =>
      DateTime(today.year, today.month, today.day + days, hour, minute);
  String key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  CalendarEvent meeting(
    String id,
    DateTime start,
    DateTime end, {
    String? title,
    bool allDay = false,
    String location = '',
    String? joinUrl,
    EventResponse response = EventResponse.accepted,
    EventShowAs showAs = EventShowAs.busy,
    bool own = false,
    bool cancelled = false,
    int? colour,
  }) =>
      CalendarEvent(
        id: id,
        accountId: 'hadco',
        title: title ?? id,
        start: start,
        end: end,
        allDay: allDay,
        location: location,
        joinUrl: joinUrl,
        response: own ? EventResponse.organizer : response,
        isOrganizer: own,
        showAs: showAs,
        cancelled: cancelled,
        colour: colour,
      );

  /// The calendar in [view] on [day], [size] dp, its events [events], and
  /// its text and clock as the phone has them.
  Future<(ProviderContainer, SampleMailEngine)> pump(
    WidgetTester tester, {
    CalendarViewMode view = CalendarViewMode.day,
    WeekSpan? span,
    Size size = const Size(412, 915),
    double textScale = 1.0,
    bool use24h = false,
    Brightness brightness = Brightness.light,
    String? secondZone,
    bool showDeclined = false,
    DateTime? day,
    List<CalendarEvent> events = const [],
    List<Override> overrides = const [],
    double? hourHeight,
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
    engine.events[hadco.id] = [
      for (final e in events)
        CalendarEvent(
          id: e.id,
          accountId: hadco.id,
          title: e.title,
          start: e.start,
          end: e.end,
          allDay: e.allDay,
          location: e.location,
          joinUrl: e.joinUrl,
          response: e.response,
          isOrganizer: e.isOrganizer,
          showAs: e.showAs,
          colour: e.colour,
          cancelled: e.cancelled,
        ),
    ];
    final ui = MemoryUiStateStore();
    await ui.writeString(UiStateKeys.calendarView, view.name);
    if (hourHeight != null) {
      await ui.writeString(UiStateKeys.calendarHourHeight, '$hourHeight');
    }
    if (span != null) {
      await ui.writeString(UiStateKeys.calendarWeekSpan, span.name);
    }
    await ui.writeString(
        UiStateKeys.calendarPrefs,
        jsonEncode({
          'showDeclined': showDeclined,
          'secondZone': ?secondZone,
        }));
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(
          FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      ...overrides,
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode:
            brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: CalendarScreen(day: day ?? today),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: use24h,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (c, engine);
  }

  Rect rectOf(RenderBox box) => box.localToGlobal(Offset.zero) & box.size;

  /// Where the hours start across the screen: the first day's left edge.
  double gutterOf(WidgetTester tester, DateTime first) {
    final head = find.byWidgetPredicate((w) =>
        w.key == ValueKey('day-head:${key(first)}') ||
        w.key == ValueKey('week-day:${key(first)}'));
    return tester.getRect(head).left;
  }

  /// The hours' labels down the side, as drawn: each one's words and box.
  List<(String, Rect)> hourLabels(WidgetTester tester, double gutter) {
    final clock = RegExp(r'^\d{1,2}(:\d\d)?( [AP]M)?$');
    return [
      for (final e in find.byType(Text).evaluate())
        if ((e.widget as Text).data case final words?
            when clock.hasMatch(words))
          if (rectOf(e.renderObject! as RenderBox) case final rect
              when rect.center.dx < gutter)
            (words, rect),
    ];
  }

  /// Every paragraph drawn inside [block].
  List<RenderParagraph> paragraphsIn(WidgetTester tester, Finder block) => [
        for (final e in find
            .descendant(of: block, matching: find.byType(RichText))
            .evaluate())
          e.renderObject! as RenderParagraph,
      ];

  /// Whether [p] breaks a line inside a word: "Suppli / er call".
  bool breaksMidWord(RenderParagraph p) {
    final text = p.text.toPlainText();
    final letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
    double lineOf(int i) =>
        p.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dy;
    for (var i = 1; i < text.length; i++) {
      final y = lineOf(i);
      if (y >= p.size.height - 0.5) break;
      if (y > lineOf(i - 1) + 0.5 &&
          letter.hasMatch(text[i - 1]) &&
          letter.hasMatch(text[i])) {
        return true;
      }
    }
    return false;
  }

  /// Each paragraph in [id]'s block whole: inside the block, no taller
  /// than its own box, and no word broken across two lines.
  void expectWhole(
    WidgetTester tester,
    String id, {
    bool mayBeEmpty = false,
  }) {
    final block = find.byKey(ValueKey('calendar-event:$id'));
    final box = tester.getRect(block);
    final paragraphs = paragraphsIn(tester, block);
    if (!mayBeEmpty) {
      expect(paragraphs, isNotEmpty, reason: '$id shows nothing');
    }
    for (final p in paragraphs) {
      final words = p.text.toPlainText();
      final rect = rectOf(p);
      expect(rect.top, greaterThanOrEqualTo(box.top - 0.01),
          reason: '"$words" above $id');
      expect(rect.bottom, lessThanOrEqualTo(box.bottom + 0.01),
          reason: '"$words" cut at the foot of $id');
      expect(p.getMinIntrinsicHeight(p.size.width),
          lessThanOrEqualTo(p.size.height + 0.01),
          reason: '"$words" has a line cut through in $id');
      expect(breaksMidWord(p), isFalse,
          reason: '"$words" breaks a word in $id');
      // The start time is cut short only where the block is too narrow
      // for the whole of it.
      if (RegExp(r'^\d{1,2}:\d\d( [AP]M)?$').hasMatch(words) &&
          p.getMaxIntrinsicWidth(double.infinity) <= box.width - 8) {
        expect(p.didExceedMaxLines, isFalse,
            reason: 'the time in $id cut short with room for all of it');
        expect(p.size.width,
            greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity)),
            reason: 'the time in $id laid out narrower than its block');
      }
    }
  }

  group('the hours down the side (#88)', () {
    for (final use24h in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        for (final zone in [null, 'Asia/Kolkata']) {
          final clock = use24h ? '24-hour' : '12-hour';
          final second = zone == null ? '' : ', beside a second zone';
          testWidgets('show whole on a $clock clock at text size $scale'
              '$second', (tester) async {
            await pump(tester,
                use24h: use24h,
                textScale: scale,
                secondZone: zone,
                events: [
                  meeting('count', today, at(0, 0, 1),
                      title: 'Inventory count', allDay: true),
                  meeting('call', at(10), at(11), title: 'Supplier call'),
                ]);
            final gutter = gutterOf(tester, today);
            final labels = hourLabels(tester, gutter);
            expect(labels.length, zone == null ? 23 : 46);
            for (final (words, rect) in labels) {
              expect(rect.left, greaterThanOrEqualTo(-0.01),
                  reason: '"$words" is cut on the left');
              expect(rect.right, lessThanOrEqualTo(gutter + 0.01),
                  reason: '"$words" runs into the first day');
            }
            // The phone's own hours: the short form on a 12-hour clock,
            // as the phone's calendar writes them.
            final own = [
              for (final (words, rect) in labels)
                if (zone == null || rect.right > gutter / 2) words,
            ];
            expect(own, contains(use24h ? '10:00' : '10 AM'));
            expect(own, contains(use24h ? '12:00' : '12 PM'));
            if (zone != null) {
              // Each zone's hour beside the other, not over it.
              final byTop = <double, List<Rect>>{};
              for (final (_, rect) in labels) {
                byTop.putIfAbsent(rect.top, () => []).add(rect);
              }
              for (final pair in byTop.values) {
                expect(pair, hasLength(2));
                pair.sort((a, b) => a.left.compareTo(b.left));
                expect(pair[0].right, lessThanOrEqualTo(pair[1].left));
              }
            }

            // Each on its hour's line: 10 o'clock beside the top of the
            // meeting at ten.
            final ten = labels
                .firstWhere((l) => own.contains(l.$1) &&
                    l.$1 == (use24h ? '10:00' : '10 AM'))
                .$2;
            final call = tester
                .getRect(find.byKey(const ValueKey('calendar-event:call')));
            expect(ten.center.dy, closeTo(call.top, 1.5));

            // "All day" on one line, in the same column.
            final allDay = find.text('All day');
            final words = tester.renderObject<RenderParagraph>(allDay);
            expect(words.getMaxIntrinsicWidth(double.infinity),
                lessThanOrEqualTo(words.size.width + 0.01),
                reason: '"All day" wraps');
            expect(tester.getRect(allDay).right,
                lessThanOrEqualTo(gutter + 0.01));
            expect(tester.getRect(allDay).left, greaterThanOrEqualTo(0));
          });
        }
      }
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('the hour at the top of the opened day shows whole, below '
          'the all-day row, at text size $scale', (tester) async {
        // A day of its own, not today, and the hours put where a day
        // opens, an hour on the hour at the top, whatever the clock says.
        final day = DateTime(2026, 11, 18);
        final (c, _) = await pump(tester,
            textScale: scale,
            day: day,
            events: [
              meeting('count', day, DateTime(2026, 11, 19),
                  title: 'Inventory count', allDay: true),
            ]);
        final scroll = tester.state<ScrollableState>(find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable)));
        scroll.position.jumpTo(9 * c.read(calendarHourHeightProvider));
        await tester.pumpAndSettle();
        final hours = tester.getRect(find.byType(SingleChildScrollView));
        final gutter = gutterOf(tester, day);
        final top = [
          for (final (_, rect) in hourLabels(tester, gutter))
            if (rect.bottom > hours.top) rect,
        ]..sort((a, b) => a.top.compareTo(b.top));
        expect(top.first.top, greaterThanOrEqualTo(hours.top - 0.01),
            reason: 'the first label is half under the all-day row');
        expect(top.first.top, lessThan(hours.top + 8),
            reason: 'the 9 o\'clock line is at the top');
      });
    }

    testWidgets('Week on a phone at 1.3: every label whole, on its line',
        (tester) async {
      await pump(tester,
          view: CalendarViewMode.week,
          span: WeekSpan.threeDays,
          textScale: 1.3,
          events: [
            meeting('call', at(12), at(13), title: 'Lunch'),
          ]);
      final gutter = gutterOf(tester, today);
      final labels = hourLabels(tester, gutter);
      expect(labels, hasLength(23));
      for (final (words, rect) in labels) {
        expect(rect.left, greaterThanOrEqualTo(-0.01), reason: words);
        expect(rect.right, lessThanOrEqualTo(gutter + 0.01), reason: words);
      }
      final noon = labels.firstWhere((l) => l.$1 == '12 PM').$2;
      final lunch =
          tester.getRect(find.byKey(const ValueKey('calendar-event:call')));
      expect(noon.center.dy, closeTo(lunch.top, 1.5));
    });
  });

  group('short meetings and narrow columns (#89)', () {
    // Tomorrow, which opens at half past eight, the whole morning on
    // screen.
    DateTime on(int hour, [int minute = 0]) => at(hour, minute, 1);
    final tomorrow = on(0);
    final busy = [
      meeting('standup', on(9), on(9, 30), title: 'Daily stand-up'),
      meeting('call', on(10), on(11),
          title: 'Supplier call – Northwind Metals', location: 'Room 4'),
      meeting('budget', on(10, 30), on(11, 15),
          title: 'Budget sign-off with Finance',
          joinUrl: 'https://teams.microsoft.com/l/x',
          response: EventResponse.tentative),
      meeting('check', on(11, 30), on(11, 45), title: 'Quick check-in'),
      meeting('labels', on(11, 45), on(12, 15), title: 'Shipping labels'),
      meeting('lunch', on(12, 30), on(13, 30),
          title: 'Lunch with Tom', location: 'Café Noir'),
      meeting('tour', on(14), on(17),
          title: 'Plant tour with Globex visitors', location: 'Plant 2'),
    ];

    for (final scale in [1.0, 1.3]) {
      for (final (name, view, size) in [
        ('three days on a phone', CalendarViewMode.week, const Size(412, 915)),
        ('three days on a small phone', CalendarViewMode.week,
            const Size(360, 780)),
        ('Day on a tablet', CalendarViewMode.day, const Size(1280, 800)),
      ]) {
        testWidgets('every line whole and no word broken: $name at text '
            'size $scale', (tester) async {
          await pump(tester,
              view: view,
              span: WeekSpan.threeDays,
              size: size,
              textScale: scale,
              day: tomorrow,
              events: busy);
          for (final e in busy) {
            expectWhole(tester, e.id);
          }
        });
      }
    }

    test('a short meeting laid out as long as it is drawn', () {
      final check = meeting('check', on(11, 30), on(11, 45));
      final after = meeting('after', on(11, 45), on(12, 15));
      Map<String, (int, int)> laid([Duration? shortest]) => {
            for (final s in shortest == null
                ? layOutDay([check, after])
                : layOutDay([check, after], shortest: shortest))
              s.event.id: (s.column, s.columns),
          };
      expect(laid(), {'check': (0, 1), 'after': (0, 1)},
          reason: 'one after the other, as before');
      expect(laid(const Duration(minutes: 26)),
          {'check': (0, 2), 'after': (1, 2)},
          reason: 'drawn 26 minutes long, the next sits beside it');
      // The last quarter hour, drawn 26 minutes long ending at midnight,
      // beside a meeting ending 20 minutes before it.
      final late = meeting('late', on(23), on(23, 40));
      final last = meeting('last', on(23, 45), on(24));
      expect({
        for (final s in layOutDay([late, last],
            shortest: const Duration(minutes: 26), dayEnd: on(24)))
          s.event.id: (s.column, s.columns),
      }, {'late': (0, 2), 'last': (1, 2)});
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('a quarter-hour meeting is tall enough to read and to tap, '
          'and the one after it is not hidden, at text size $scale',
          (tester) async {
        final (c, _) = await pump(tester,
            textScale: scale, day: tomorrow, events: busy);
        Rect rect(String id) =>
            tester.getRect(find.byKey(ValueKey('calendar-event:$id')));
        expect(rect('check').height, greaterThanOrEqualTo(24),
            reason: 'at least 24 dp to tap');
        expect(find.text('Quick check-in'), findsOneWidget);
        expectWhole(tester, 'check');
        expect(rect('check').overlaps(rect('labels')), isFalse,
            reason: 'the meeting after it is not drawn under it');
        // At the shortest hours a pinch allows, half an hour's height at
        // most, so an ordinary day lays out as it always did; still not
        // under the next, and nothing cut.
        c
            .read(calendarHourHeightProvider.notifier)
            .set(CalendarHourHeight.smallest);
        await tester.pumpAndSettle();
        expect(rect('check').height,
            closeTo(CalendarHourHeight.smallest / 2, 0.01));
        expect(rect('check').overlaps(rect('labels')), isFalse);
        expectWhole(tester, 'check', mayBeEmpty: true);
        expectWhole(tester, 'labels', mayBeEmpty: true);
      });
    }

    for (final hour in [24.0, 40.0, 56.0]) {
      testWidgets('an ordinary day lays out as it always did at $hour dp an '
          'hour: half hours one under the other, full width', (tester) async {
        await pump(tester, day: tomorrow, hourHeight: hour, events: [
          meeting('a', on(9), on(9, 30), title: 'Daily stand-up'),
          meeting('b', on(9, 30), on(10), title: 'Quality review'),
          meeting('c', on(10), on(11), title: 'Supplier call'),
          meeting('d', on(11), on(11, 30), title: 'Budget'),
        ]);
        Rect rect(String id) =>
            tester.getRect(find.byKey(ValueKey('calendar-event:$id')));
        final column = tester
            .getRect(find.byKey(ValueKey('day-head:${key(tomorrow)}')));
        for (final id in ['a', 'b', 'c', 'd']) {
          expect(rect(id).width, closeTo(column.width - 2, 0.5),
              reason: '$id is drawn at part of the width');
        }
        for (final (first, next) in [('a', 'b'), ('b', 'c'), ('c', 'd')]) {
          expect(rect(first).bottom, lessThanOrEqualTo(rect(next).top + 0.01),
              reason: '$first runs into $next');
        }
        expect(rect('a').height, closeTo(hour / 2, 0.01));
      });
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('a short meeting just before midnight stays inside the day, '
          'at text size $scale', (tester) async {
        await pump(tester, textScale: scale, day: tomorrow, events: [
          meeting('before', on(23), on(23, 40), title: 'Late call'),
          meeting('last', on(23, 45), on(24), title: 'Last check'),
        ]);
        await tester.drag(
            find.byType(SingleChildScrollView), const Offset(0, -3000));
        await tester.pumpAndSettle();
        final block = find.byKey(const ValueKey('calendar-event:last'));
        final day = tester.getRect(
            find.ancestor(of: block, matching: find.byType(Stack)).first);
        expect(tester.getRect(block).bottom,
            lessThanOrEqualTo(day.bottom + 0.01),
            reason: 'drawn past the end of the hours');
        expectWhole(tester, 'last');
        // Lifted to end at midnight, and so beside the one before it.
        expect(
            tester
                .getRect(find.byKey(const ValueKey('calendar-event:before')))
                .overlaps(tester.getRect(block)),
            isFalse);
      });
    }

    testWidgets('no line is left empty while the place or the time waits, '
        'after a title cut on a word too long for the block',
        (tester) async {
      // Three side by side in a phone's day: each a third of the width.
      await pump(tester, day: tomorrow, events: [
        for (final id in ['a', 'b', 'c'])
          meeting(id, on(10), on(11),
              title: 'Teleconference about pricing',
              location: 'Room 4 west wing'),
      ]);
      for (final id in ['a', 'b', 'c']) {
        expectWhole(tester, id);
        final block =
            tester.getRect(find.byKey(ValueKey('calendar-event:$id')));
        final paragraphs = paragraphsIn(
            tester, find.byKey(ValueKey('calendar-event:$id')));
        final line = tester
                .renderObject<RenderParagraph>(find
                    .descendant(
                        of: find.byKey(ValueKey('calendar-event:$id')),
                        matching: find.byType(RichText))
                    .first)
                .size
                .height;
        final lowest = paragraphs.map((p) => rectOf(p).bottom).reduce(math.max);
        expect(block.bottom - 2 - lowest, lessThan(line - 0.01),
            reason: 'a line left empty in $id: '
                '${[for (final p in paragraphs) p.text.toPlainText()]}');
      }
    });

    testWidgets('under the title, the place or Online, then the start time',
        (tester) async {
      await pump(tester,
          size: const Size(1280, 800), day: tomorrow, events: busy);
      List<String> lines(String id) => [
            for (final p in paragraphsIn(
                tester, find.byKey(ValueKey('calendar-event:$id'))))
              p.text.toPlainText(),
          ];
      expect(lines('lunch'), ['Lunch with Tom', 'Café Noir', '12:30 PM']);
      expect(lines('tour').take(2),
          ['Plant tour with Globex visitors', 'Plant 2']);
      // Half an hour: the title alone.
      expect(lines('standup'), ['Daily stand-up']);
      // Online, with no place.
      expect(lines('budget'), contains('Online'));
    });

    testWidgets('the screen reader hears the title and the start time',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, day: tomorrow, events: busy);
      for (final (id, title, time) in [
        ('standup', 'Daily stand-up', '9:00 AM'),
        ('check', 'Quick check-in', '11:30 AM'),
        ('lunch', 'Lunch with Tom', '12:30 PM'),
      ]) {
        final label = tester
            .getSemantics(find.byKey(ValueKey('calendar-event:$id')))
            .label;
        expect(label, contains(title));
        expect(label, contains(time));
      }
      semantics.dispose();
    });

    for (final (what, grip, sent) in [
      ('held by its middle, moves', 0.3, 'update check start=12:30 end=12:45'),
      ('held by its foot, stretches', 0.9,
          'update check start=11:30 end=12:45'),
    ]) {
      testWidgets('a quarter-hour meeting drawn taller than its time, $what '
          'an hour', (tester) async {
        final (c, engine) = await pump(tester,
            use24h: true,
            day: tomorrow,
            events: [
              meeting('check', on(11, 30), on(11, 45),
                  title: 'Quick check-in', own: true),
            ]);
        final block = find.byKey(const ValueKey('calendar-event:check'));
        final rect = tester.getRect(block);
        final hour = c.read(calendarHourHeightProvider);
        final drag = await tester.startGesture(
            rect.topLeft + Offset(10, rect.height * grip));
        await tester.pump(const Duration(milliseconds: 700));
        await drag.moveBy(Offset(0, hour / 2));
        await tester.pump();
        await drag.moveBy(Offset(0, hour / 2));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
        expect(engine.calendarActions, [sent]);
      });
    }
  });

  group('text on a meeting keeps its contrast (#90)', () {
    // The eight colours new accounts are given, and Google's eleven.
    final colours = [...newAccountColours, ...googleEventColours.values];

    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    /// The colour painted behind [finder]: the nearest shape or box above
    /// it that fills itself.
    Color fillOf(WidgetTester tester, Finder finder) {
      RenderObject? node = tester.renderObject(finder);
      while (node != null) {
        if (node is RenderPhysicalShape) return node.color;
        if (node is RenderDecoratedBox &&
            node.decoration is BoxDecoration &&
            (node.decoration as BoxDecoration).color != null) {
          return (node.decoration as BoxDecoration).color!;
        }
        node = node.parent;
      }
      fail('nothing painted behind $finder');
    }

    /// Whether [finder]'s edge is drawn dashed.
    bool dashed(WidgetTester tester, Finder finder) => find
        .ancestor(
          of: finder,
          matching: find.byWidgetPredicate((w) =>
              w is CustomPaint && w.foregroundPainter is DashedOutline),
        )
        .evaluate()
        .isNotEmpty;

    final states = [
      ('accepted', EventResponse.accepted, EventShowAs.busy),
      ('tentative', EventResponse.tentative, EventShowAs.tentative),
      ('not answered', EventResponse.notResponded, EventShowAs.busy),
      ('free', EventResponse.accepted, EventShowAs.free),
      ('declined', EventResponse.declined, EventShowAs.busy),
    ];

    test('white words on a solid meeting wherever white reads, black only '
        'where it does not', () {
      for (final c in {
        ...accountPalette,
        ...newAccountColours,
        ...googleEventColours.values,
        ...outlookCategoryColours.values,
      }) {
        final colour = Color(c);
        final white = contrast(Colors.white, colour);
        final name = c.toRadixString(16);
        expect(inkOn(colour), white >= 4.5 ? Colors.white : Colors.black,
            reason: name);
        expect(contrast(inkOn(colour), colour), greaterThanOrEqualTo(4.5),
            reason: name);
      }
    });

    testWidgets("Outlook's Blue category keeps its white words",
        (tester) async {
      await pump(tester, day: at(0, 0, 1), events: [
        meeting('blue', at(10, 0, 1), at(11, 0, 1),
            title: 'Category blue', colour: 0xFF0078D4),
      ]);
      final words = find.descendant(
          of: find.byKey(const ValueKey('calendar-event:blue')),
          matching: find.text('Category blue'));
      expect(tester.renderObject<RenderParagraph>(words).text.style!.color,
          Colors.white);
    });

    for (final brightness in Brightness.values) {
      for (final (state, response, showAs) in states) {
        testWidgets('4.5 to 1 on every colour: $state, ${brightness.name} '
            'theme, Day', (tester) async {
          final day = at(0, 0, 1);
          await pump(tester,
              brightness: brightness,
              showDeclined: true,
              day: day,
              events: [
                for (var i = 0; i < colours.length; i++)
                  meeting('m$i', at(i, 0, 1), at(i + 1, 0, 1),
                      title: 'Meeting $i',
                      response: response,
                      showAs: showAs,
                      colour: colours[i]),
              ]);
          final scheme = Theme.of(
                  tester.element(find.byType(CalendarScreen)))
              .colorScheme;
          for (var i = 0; i < colours.length; i++) {
            final block = find.byKey(ValueKey('calendar-event:m$i'));
            final words = find.descendant(
                of: block, matching: find.text('Meeting $i'));
            final fill = fillOf(tester, words);
            final ink = tester.renderObject<RenderParagraph>(words).text
                .style!.color!;
            final name = colours[i].toRadixString(16);
            expect(fill.a, 1.0, reason: '$name: the grid shows through');
            expect(contrast(ink, fill), greaterThanOrEqualTo(4.5),
                reason: '$name $state');
            if (state != 'accepted') {
              expect(ink, scheme.onSurface,
                  reason: "a faint block's text is the page's");
            } else if (i < newAccountColours.length) {
              // An accepted meeting on an account colour, as before.
              expect(fill, Color(colours[i]));
              expect(ink, Colors.white);
            }
            expect(dashed(tester, words),
                state == 'tentative' || state == 'not answered',
                reason: '$name $state: dashed only for an open answer');
            final decoration = tester
                .renderObject<RenderParagraph>(words)
                .text
                .style
                ?.decoration;
            expect(decoration == TextDecoration.lineThrough,
                state == 'declined');
          }
        });

        testWidgets('4.5 to 1 on every colour: $state, ${brightness.name} '
            'theme, the month', (tester) async {
          final first = DateTime(today.year, today.month, 1);
          await pump(tester,
              view: CalendarViewMode.month,
              size: const Size(1280, 800),
              brightness: brightness,
              showDeclined: true,
              day: first,
              events: [
                for (var i = 0; i < colours.length; i++)
                  meeting('m$i', first.add(Duration(days: i, hours: 10)),
                      first.add(Duration(days: i, hours: 11)),
                      title: 'Meeting $i',
                      response: response,
                      showAs: showAs,
                      colour: colours[i]),
              ]);
          final scheme = Theme.of(
                  tester.element(find.byType(CalendarScreen)))
              .colorScheme;
          for (var i = 0; i < colours.length; i++) {
            final line = find.byKey(ValueKey('month-event:m$i'));
            final words = find.descendant(
                of: line, matching: find.byType(RichText));
            final fill = fillOf(tester, words);
            final ink = tester.renderObject<RenderParagraph>(words).text
                .style!.color!;
            final name = colours[i].toRadixString(16);
            expect(fill.a, 1.0, reason: '$name: the box shows through');
            expect(contrast(ink, fill), greaterThanOrEqualTo(4.5),
                reason: '$name $state');
            if (state != 'accepted') expect(ink, scheme.onSurface);
            expect(dashed(tester, words),
                state == 'tentative' || state == 'not answered');
          }
        });
      }
    }
  });

  group('the line at the present time (#91)', () {
    /// The red line across today, as drawn: the box filled in the theme's
    /// error colour.
    Finder lineIn(WidgetTester tester) {
      final red = Theme.of(tester.element(find.byType(CalendarScreen)))
          .colorScheme
          .error;
      return find.byWidgetPredicate((w) => w is ColoredBox && w.color == red);
    }

    /// Which of [stack]'s children holds [node]: the order they are drawn.
    int drawnAt(RenderStack stack, RenderObject node) {
      final children = <RenderObject>[];
      stack.visitChildren(children.add);
      RenderObject? at = node;
      while (at != null && at.parent != stack) {
        at = at.parent;
      }
      return children.indexOf(at!);
    }

    for (final view in [CalendarViewMode.day, CalendarViewMode.week]) {
      testWidgets('moves with the clock, under the meetings, with a mark on '
          'the hours: ${view.name}', (tester) async {
        var clock = at(10, 17);
        final (c, _) = await pump(tester,
            view: view,
            span: WeekSpan.threeDays,
            overrides: [meetingClockProvider.overrideWithValue(() => clock)],
            events: [
              meeting('call', at(10), at(11), title: 'Supplier call'),
            ]);
        final hour = c.read(calendarHourHeightProvider);
        final call = find.byKey(const ValueKey('calendar-event:call'));
        final line = lineIn(tester);
        expect(line, findsOneWidget, reason: 'across today alone');
        final first = tester.getRect(line);
        expect(first.top - tester.getRect(call).top,
            closeTo(17 / 60 * hour, 1.0));
        // The hour column's mark, at the same height, where the hours meet
        // the first day.
        final mark = tester.getRect(find.byKey(const ValueKey('now-mark')));
        expect(mark.center.dy, closeTo(first.center.dy, 1.0));
        expect(mark.center.dx, closeTo(gutterOf(tester, today), 1.0));
        // Drawn under the meeting, so it does not cross its title; the
        // mark over everything.
        final stack = tester.renderObject(find.ancestor(
          of: call,
          matching: find.byType(Stack),
        ).first) as RenderStack;
        expect(drawnAt(stack, tester.renderObject(line)),
            lessThan(drawnAt(stack, tester.renderObject(call))));

        // Half an hour on, at the next tick, without building the day
        // again.
        final block = tester.widget(call);
        clock = at(10, 47);
        await tester.pump(MeetingTicker.tick);
        expect(tester.getRect(line).top - first.top,
            closeTo(hour / 2, 0.5));
        expect(
            tester
                .getRect(find.byKey(const ValueKey('now-mark')))
                .center
                .dy,
            closeTo(tester.getRect(line).center.dy, 1.0));
        expect(identical(tester.widget(call), block), isTrue,
            reason: 'the meetings were built again for the line');
      });
    }

    testWidgets('not on a page without today, and stops with the screen',
        (tester) async {
      final clock = at(10, 17);
      await pump(tester,
          day: at(0, 0, 3),
          overrides: [meetingClockProvider.overrideWithValue(() => clock)]);
      expect(lineIn(tester), findsNothing);
      expect(find.byKey(const ValueKey('now-mark')), findsNothing);
      // The screen gone: nothing left ticking (the test fails on a timer
      // still waiting once the screen is taken down).
      await tester.pumpWidget(const SizedBox());
      await tester.pump(MeetingTicker.tick);
    });

    for (final (view, tickers) in [
      (CalendarViewMode.day, 1),
      (CalendarViewMode.week, 1),
      (CalendarViewMode.month, 0),
    ]) {
      testWidgets('one tick for the whole grid, the shared meeting tick, in '
          '${view.name}', (tester) async {
        // The pages either side are kept built, off screen: the line and
        // its mark on all of them move with the one tick, and none of
        // them ticks on its own; the month has no line and no tick.
        await pump(tester,
            view: view,
            span: WeekSpan.threeDays,
            events: [
              meeting('call', at(10), at(11), title: 'Supplier call'),
            ]);
        expect(find.byType(MeetingTicker, skipOffstage: false),
            findsNWidgets(tickers));
      });
    }
  });

  group('three slips in the grid (#100)', () {
    const hebrew = 'פגישה עם רואה החשבון';
    const street = 'רחוב הרצל 12, תל אביב';

    /// Where in [p] the first [count] characters are drawn: the left and
    /// right of their boxes, across the paragraph.
    (double, double) span(RenderParagraph p, int from, int to) {
      final boxes = p.getBoxesForSelection(
          TextSelection(baseOffset: from, extentOffset: to));
      return (
        boxes.map((b) => b.left).reduce(math.min),
        boxes.map((b) => b.right).reduce(math.max),
      );
    }

    testWidgets('a Hebrew title and place read from the right in a block, '
        'an English one from the left', (tester) async {
      await pump(tester,
          size: const Size(1280, 800),
          day: at(0, 0, 1),
          events: [
            meeting('he', at(9, 30, 1), at(10, 30, 1),
                title: hebrew, location: street),
            meeting('en', at(12, 0, 1), at(13, 0, 1),
                title: 'Lunch with Tom', location: 'Café Noir'),
            meeting('day', at(0, 0, 1), at(0, 0, 2),
                title: hebrew, allDay: true),
            meeting('he-online', at(14, 0, 1), at(15, 0, 1),
                title: hebrew, joinUrl: 'https://teams.microsoft.com/l/x'),
            meeting('he-room', at(15, 0, 1), at(16, 0, 1),
                title: hebrew, location: 'Room 4'),
            meeting('en-he', at(16, 0, 1), at(17, 0, 1),
                title: 'Accountant', location: street),
          ]);
      RenderParagraph line(String id, String words) =>
          tester.renderObject<RenderParagraph>(find.descendant(
            of: find.byKey(ValueKey('calendar-event:$id')),
            matching: find.text(words),
          ));
      for (final (id, words) in [
        ('he', hebrew),
        ('he', street),
        ('day', hebrew),
      ]) {
        final p = line(id, words);
        expect(p.textDirection, TextDirection.rtl, reason: words);
        final (left, right) = span(p, 0, 1);
        expect(right, greaterThan(p.size.width - 2),
            reason: '"$words" starts at the right');
        expect(left, greaterThan(p.size.width / 2));
      }
      final p = line('en', 'Lunch with Tom');
      expect(p.textDirection, TextDirection.ltr);
      expect(span(p, 0, 1).$1, lessThan(2));

      // A block's lines share one side, the title's: "Online" and an
      // English place on the right under a Hebrew title, in their own
      // order; a Hebrew place on the left under an English one.
      for (final (id, words) in [
        ('he-online', 'Online'),
        ('he-room', 'Room 4'),
      ]) {
        final p = line(id, words);
        final (left, right) = span(p, 0, words.length);
        expect(right, greaterThan(p.size.width - 2),
            reason: '"$words" on the right, under its title');
        expect(left, greaterThan(p.size.width / 2), reason: words);
        expect(span(p, 0, 1).$1, lessThan(span(p, 1, 2).$1),
            reason: '"$words" in its own order');
      }
      final place = line('en-he', street);
      expect(place.textDirection, TextDirection.rtl);
      expect(span(place, 0, street.length).$1, lessThan(2),
          reason: 'on the left, under its title');
    });

    testWidgets('a Hebrew month line reads from the right and still starts '
        'with its time', (tester) async {
      final day = DateTime(today.year, today.month, 10);
      await pump(tester,
          view: CalendarViewMode.month,
          size: const Size(1280, 800),
          day: day,
          events: [
            meeting('he', day.add(const Duration(hours: 9, minutes: 30)),
                day.add(const Duration(hours: 10, minutes: 30)),
                title: hebrew),
            meeting('en', day.add(const Duration(hours: 12)),
                day.add(const Duration(hours: 13)),
                title: 'Lunch with Tom'),
          ]);
      RenderParagraph line(String id) =>
          tester.renderObject<RenderParagraph>(find.descendant(
            of: find.byKey(ValueKey('month-event:$id')),
            matching: find.byType(RichText),
          ));
      final he = line('he');
      final text = he.text.toPlainText();
      final time = text.indexOf('9:30 AM');
      expect(he.textDirection, TextDirection.rtl);
      // The time, whole and in order, at the right; the title after it,
      // to its left.
      final (timeLeft, timeRight) = span(he, time, time + '9:30 AM'.length);
      expect(timeRight, greaterThan(he.size.width - 2));
      final at9 = span(he, time, time + 1);
      final atM = span(he, time + 6, time + 7);
      expect(at9.$1, lessThan(atM.$1), reason: '"9:30 AM", not "AM 9:30"');
      final title = text.indexOf(hebrew);
      expect(span(he, title, title + 1).$2, lessThanOrEqualTo(timeLeft));
      final en = line('en');
      expect(en.textDirection, TextDirection.ltr);
      expect(span(en, 0, 1).$1, lessThan(2));
    });

    for (final scale in [1.0, 1.3]) {
      for (final size in [const Size(800, 1280), const Size(1280, 800)]) {
        testWidgets('a day of twelve meetings fits its month box: '
            '${size.width.toInt()} wide at text size $scale', (tester) async {
          final day = DateTime(today.year, today.month, 10);
          await pump(tester,
              view: CalendarViewMode.month,
              size: size,
              textScale: scale,
              day: day,
              events: [
                for (var i = 0; i < 12; i++)
                  meeting('m$i', day.add(Duration(hours: 7 + i)),
                      day.add(Duration(hours: 8 + i)),
                      title: 'Meeting $i'),
              ]);
          // Laid out without running over (a test fails on Flutter's own
          // "overflowed by" report), each line inside the box.
          final box = tester.getRect(
              find.byKey(ValueKey('month-day:${key(day)}')));
          final lines = find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('month-event:'));
          expect(lines, findsWidgets);
          for (final e in lines.evaluate()) {
            final rect = rectOf(e.renderObject! as RenderBox);
            expect(rect.bottom, lessThanOrEqualTo(box.bottom + 0.01));
          }
          final more = find.textContaining('more');
          expect(more, findsOneWidget);
          expect(tester.getRect(more).bottom,
              lessThanOrEqualTo(box.bottom + 0.01));
          expect(
              tester.widget<Text>(more).data,
              '+${12 - lines.evaluate().length} more');
        });
      }
    }

    // Dragged into the room over or under midnight, a meeting stops at
    // midnight, on its day, with the ghost showing where.
    for (final (what, start, end, grip, hours, sent) in [
      ('held by its middle, moved down', at(23, 0, 1), at(23, 30, 1), 0.3,
          2, 'update late start=23:30 end=00:00'),
      ('held by its foot, stretched down', at(23, 0, 1), at(23, 30, 1), 0.9,
          2, 'update late start=23:00 end=00:00'),
      ('held by its middle, moved up', at(0, 30, 1), at(1, 0, 1), 0.3, -2,
          'update late start=00:00 end=00:30'),
    ]) {
      testWidgets('a meeting $what past midnight stays on its day',
          (tester) async {
        final (c, engine) = await pump(tester,
            use24h: true,
            day: at(0, 0, 1),
            events: [
              meeting('late', start, end, title: 'Late call', own: true),
            ]);
        // To the end of the day, or to its start.
        await tester.drag(find.byType(SingleChildScrollView),
            Offset(0, hours > 0 ? -3000 : 3000));
        await tester.pumpAndSettle();
        final block = find.byKey(const ValueKey('calendar-event:late'));
        final rect = tester.getRect(block);
        final hour = c.read(calendarHourHeightProvider);
        final drag = await tester
            .startGesture(rect.topLeft + Offset(10, rect.height * grip));
        await tester.pump(const Duration(milliseconds: 700));
        for (var i = 0; i < hours.abs() * 2; i++) {
          await drag.moveBy(Offset(0, hours.sign * hour / 2));
          await tester.pump();
        }
        expect(find.byKey(const ValueKey('calendar-drag-ghost')),
            findsOneWidget,
            reason: 'the ghost shows where it goes');
        await drag.up();
        await tester.pumpAndSettle();
        expect(engine.calendarActions, [sent]);
      });
    }

    // A meeting across midnight moves as it did, its start kept on the
    // day of the column it was taken in; an ordinary one stops on a
    // quarter hour from where it was, short of midnight.
    for (final (what, start, end, toEnd, hours, sent) in [
      ('across midnight, taken on its first day and moved down',
          at(22, 0, 1), at(2, 0, 2), true, 3,
          'update late start=23:45 end=03:45'),
      ('across midnight, taken on its second day and moved down',
          at(23, 0, 0), at(1, 0, 1), false, 3,
          'update late start=02:00 end=04:00'),
      ('at an odd minute, moved down past midnight', at(23, 7, 1),
          at(23, 37, 1), true, 2, 'update late start=23:22 end=23:52'),
    ]) {
      testWidgets('a meeting $what', (tester) async {
        final (c, engine) = await pump(tester,
            use24h: true,
            day: at(0, 0, 1),
            events: [
              meeting('late', start, end, title: 'Late call', own: true),
            ]);
        await tester.drag(find.byType(SingleChildScrollView),
            Offset(0, toEnd ? -3000 : 3000));
        await tester.pumpAndSettle();
        final rect =
            tester.getRect(find.byKey(const ValueKey('calendar-event:late')));
        final hour = c.read(calendarHourHeightProvider);
        final drag = await tester
            .startGesture(rect.topLeft + Offset(10, rect.height * 0.3));
        await tester.pump(const Duration(milliseconds: 700));
        for (var i = 0; i < hours * 2; i++) {
          await drag.moveBy(Offset(0, hour / 2));
          await tester.pump();
        }
        await drag.up();
        await tester.pumpAndSettle();
        expect(engine.calendarActions, [sent]);
      });
    }

    for (final (name, view, size) in [
      ('Day on a phone', CalendarViewMode.day, const Size(412, 915)),
      ('Week on a tablet', CalendarViewMode.week, const Size(1280, 800)),
    ]) {
      testWidgets('$name scrolls the last hours clear of the + button',
          (tester) async {
        // The page's last day, late in the evening.
        final first = at(0, 0, 1);
        final last = calendarPage(
          view,
          WeekSpan.sevenDays,
          defaultWorkWeek,
          first,
          0,
        ).days.last;
        await pump(tester,
            view: view,
            size: size,
            day: first,
            events: [
              meeting('late', DateTime(last.year, last.month, last.day, 23),
                  DateTime(last.year, last.month, last.day, 23, 59),
                  title: 'Late call'),
            ]);
        await tester.drag(
            find.byType(SingleChildScrollView), const Offset(0, -3000));
        await tester.pumpAndSettle();
        final late = tester
            .getRect(find.byKey(const ValueKey('calendar-event:late')));
        final button = tester.getRect(find.byType(FloatingActionButton));
        expect(late.overlaps(button), isFalse,
            reason: 'the last hour sits under the + button');
        expect(late.bottom, lessThanOrEqualTo(button.top));
      });
    }

    for (final size in [const Size(1280, 800), const Size(800, 1280)]) {
      testWidgets('the month on a tablet ${size.width.toInt()} wide keeps '
          'its last day clear of the + button', (tester) async {
        final last = calendarPage(CalendarViewMode.month,
                WeekSpan.sevenDays, defaultWorkWeek, today, 0)
            .days
            .last;
        final (c, _) = await pump(tester,
            view: CalendarViewMode.month,
            size: size,
            day: today,
            events: [
              for (var i = 0; i < 3; i++)
                meeting(
                    'm$i',
                    DateTime(last.year, last.month, last.day, 9 + i),
                    DateTime(last.year, last.month, last.day, 10 + i),
                    title: 'Meeting $i with the suppliers'),
            ]);
        final button = tester.getRect(find.byType(FloatingActionButton));
        final box = find.byKey(ValueKey('month-day:${key(last)}'));
        expect(tester.getRect(box).overlaps(button), isTrue,
            reason: 'the button is over the last box, as it always was');
        final lines = find.descendant(
            of: box,
            matching: find.byWidgetPredicate((w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>)
                    .value
                    .startsWith('month-event:')));
        final more = find.descendant(
            of: box, matching: find.textContaining('more'));
        expect(lines.evaluate().length + more.evaluate().length,
            greaterThan(0));
        for (final e in [...lines.evaluate(), ...more.evaluate()]) {
          expect(rectOf(e.renderObject! as RenderBox).overlaps(button),
              isFalse,
              reason: 'a line of the last day under the + button');
        }
        // The day still opens from what shows of its box.
        await tester.tapAt(tester.getRect(box).topLeft + const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(c.read(calendarViewProvider), CalendarViewMode.day);
      });
    }
  });
}
