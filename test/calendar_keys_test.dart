import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_keys.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/calendar_search_screen.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';
import 'package:myemail/ui/shell/app_shortcuts.dart';

import 'fakes/fake_webview.dart';

/// Keys in the calendar (calendar idea #75): Today, the arrows, the views,
/// a date, New meeting, search, the help and Back, from one table, and
/// never while something is being typed. The mail's own keys are in
/// shortcuts_test, as they were.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime plus(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  String day(DateTime d) => '${d.year}-${d.month}-${d.day}';

  const months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];

  /// The calendar opened over a page, as the mail opens it, so Back has
  /// somewhere to go: Hadco's calendar, in [view], with [events] on it.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    CalendarViewMode view = CalendarViewMode.day,
    List<CalendarEvent> Function(Account hadco)? events,
    Size size = const Size(1000, 1400),
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
    if (events != null) engine.events[hadco.id] = events(hadco);
    final ui = MemoryUiStateStore();
    await ui.writeString(UiStateKeys.calendarView, view.name);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => CalendarScreen.open(context),
              child: const Text('the mail'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('the mail'));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Finder dayShown(DateTime d) => find.byKey(ValueKey('day-head:${day(d)}'));

  CalendarEvent meeting(Account hadco, String id, String title, DateTime at) =>
      CalendarEvent(
        id: id,
        accountId: hadco.id,
        title: title,
        start: at,
        end: at.add(const Duration(hours: 1)),
        response: EventResponse.none,
      );

  group('the table', () {
    /// How the help writes a key the calendar answers to.
    String named(ShortcutActivator key) => switch (key) {
          SingleActivator(:final trigger) => switch (trigger) {
              LogicalKeyboardKey.arrowLeft => '←',
              LogicalKeyboardKey.arrowRight => '→',
              LogicalKeyboardKey.escape => 'Esc',
              LogicalKeyboardKey.f1 => 'F1',
              _ => trigger.keyLabel,
            },
          CharacterActivator(:final character) => character,
          _ => '$key',
        };

    test('the help names every key the calendar answers to, each once', () {
      final does = <String, CalendarCommand>{};
      for (final line in calendarKeys) {
        expect(line.does, isNotEmpty);
        for (final (key, command) in line.bindings) {
          expect(line.keys.split(RegExp(r'\s+')), contains(named(key)),
              reason: line.does);
          expect(does.putIfAbsent(named(key), () => command), command,
              reason: 'no key does two things');
        }
      }
      expect(
        {for (final l in calendarKeys) for (final (_, c) in l.bindings) c},
        CalendarCommand.values.toSet(),
        reason: 'every command has its key',
      );
    });

    test('the F1 list of the mail has the calendar among its parts', () {
      expect(shortcutHelp['In the calendar'], same(calendarKeys));
    });
  });

  group('in the calendar', () {
    testWidgets('the arrows go on and back a day in Day, and T comes back to '
        'today', (tester) async {
      await pump(tester);
      final t = today();
      expect(dayShown(t), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(dayShown(plus(t, 1)), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(dayShown(plus(t, 2)), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyT);
      expect(dayShown(t), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(dayShown(plus(t, -1)), findsOneWidget);
    });

    testWidgets('in Week they go a week, and in Month a month', (tester) async {
      await pump(tester, view: CalendarViewMode.week);
      final t = today();
      expect(find.byKey(ValueKey('week-day:${day(t)}')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.byKey(ValueKey('week-day:${day(t)}')), findsNothing);
      expect(find.byKey(ValueKey('week-day:${day(plus(t, 7))}')),
          findsOneWidget);

      await press(tester, LogicalKeyboardKey.keyM);
      await press(tester, LogicalKeyboardKey.keyT);
      final next = DateTime(t.year, t.month + 1);
      expect(find.text('${months[t.month - 1]} ${t.year}'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('${months[next.month - 1]} ${next.year}'),
          findsOneWidget);
    });

    testWidgets('in Agenda they go back and on a week, as ‹ and › do there',
        (tester) async {
      await pump(tester, view: CalendarViewMode.agenda);
      final t = today();
      expect(find.byKey(ValueKey('agenda-day:${day(t)}')), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.byKey(ValueKey('agenda-day:${day(plus(t, 7))}')),
          findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.byKey(ValueKey('agenda-day:${day(plus(t, -7))}')),
          findsOneWidget);
    });

    testWidgets('D, W, M and A choose the view', (tester) async {
      final c = await pump(tester, view: CalendarViewMode.agenda);

      await press(tester, LogicalKeyboardKey.keyD);
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
      await press(tester, LogicalKeyboardKey.keyW);
      expect(c.read(calendarViewProvider), CalendarViewMode.week);
      await press(tester, LogicalKeyboardKey.keyM);
      expect(c.read(calendarViewProvider), CalendarViewMode.month);
      await press(tester, LogicalKeyboardKey.keyA);
      expect(c.read(calendarViewProvider), CalendarViewMode.agenda);
    });

    testWidgets('G opens the month to pick a date from, and Esc closes it, '
        'the calendar staying', (tester) async {
      await pump(tester);

      await press(tester, LogicalKeyboardKey.keyG);
      expect(find.byKey(const ValueKey('pick-next')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byKey(const ValueKey('pick-next')), findsNothing);
      expect(find.byType(CalendarScreen), findsOneWidget);

      // The keys are the calendar's again.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(dayShown(plus(today(), 1)), findsOneWidget);
    });

    testWidgets('N is a new meeting, and / the search; back from each, the '
        'keys still work', (tester) async {
      final c = await pump(tester, view: CalendarViewMode.agenda);

      await press(tester, LogicalKeyboardKey.keyN);
      expect(find.byType(NewMeetingScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NewMeetingScreen), findsNothing);

      await press(tester, LogicalKeyboardKey.slash);
      expect(find.byType(CalendarSearchScreen), findsOneWidget);
      // A letter typed in the search is not the calendar's D.
      await press(tester, LogicalKeyboardKey.keyD);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CalendarSearchScreen), findsNothing);
      expect(c.read(calendarViewProvider), CalendarViewMode.agenda);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.byKey(ValueKey('agenda-day:${day(plus(today(), 7))}')),
          findsOneWidget);
    });

    testWidgets("Esc closes a meeting's sheet first, then goes back to the "
        'mail', (tester) async {
      final t = today();
      await pump(tester,
          view: CalendarViewMode.agenda,
          events: (hadco) => [
                meeting(hadco, 'review', 'Project review',
                    DateTime(t.year, t.month, t.day + 1, 14)),
              ]);
      await tester.tap(find.byKey(const ValueKey('agenda-event:review')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(CalendarScreen), findsOneWidget);

      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.text('the mail'), findsOneWidget);
    });

    testWidgets('Tab reaches the meetings and Enter opens the one with the '
        'focus; the keys still work once that meeting has gone by',
        (tester) async {
      final t = today();
      await pump(tester,
          view: CalendarViewMode.agenda,
          events: (hadco) => [
                meeting(hadco, 'review', 'Project review',
                    DateTime(t.year, t.month, t.day + 1, 14)),
              ]);
      final row = find.byKey(const ValueKey('agenda-event:review'));
      bool focused() {
        final at = FocusManager.instance.primaryFocus?.context;
        if (at == null) return false;
        final target = tester.element(row);
        var inside = at == target;
        at.visitAncestorElements((e) => !(inside = inside || e == target));
        return inside;
      }

      for (var i = 0; i < 40 && !focused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focused(), isTrue);

      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Project review'),
        ),
        findsOneWidget,
      );
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(BottomSheet), findsNothing);

      // A week on: the row with the focus is gone with the week before.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.byKey(ValueKey('agenda-day:${day(plus(t, 7))}')),
          findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyT);
      expect(find.byKey(ValueKey('agenda-day:${day(t)}')), findsOneWidget);
    });

    // The pages either side of the one shown stay built, off screen, for a
    // swipe. A focus left on one of them, or walked onto one, would have
    // Enter open what Ron cannot see.
    testWidgets('a key held down turns one page, and its repeats walk no '
        'focus: Enter after it opens nothing', (tester) async {
      final t = today();
      final c = await pump(tester,
          view: CalendarViewMode.week,
          events: (hadco) => [
                meeting(hadco, 'review', 'Project review',
                    DateTime(t.year, t.month, t.day, 14)),
              ]);
      final before = FocusManager.instance.primaryFocus;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('week-day:${day(plus(t, 7))}')),
          findsOneWidget, reason: 'one page on');
      expect(find.byKey(ValueKey('week-day:${day(plus(t, 14))}')),
          findsNothing);
      expect(FocusManager.instance.primaryFocus, same(before));
      await press(tester, LogicalKeyboardKey.enter);
      expect(c.read(calendarViewProvider), CalendarViewMode.week);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a meeting with the focus in Day, then the page turned by a '
        'key or a swipe: the focus is the calendar\'s again, and Enter opens '
        'nothing off screen', (tester) async {
      final t = today();
      await pump(tester,
          events: (hadco) => [
                meeting(hadco, 'review', 'Project review',
                    DateTime(t.year, t.month, t.day, 14)),
              ]);
      final block = find.byKey(const ValueKey('calendar-event:review'),
          skipOffstage: false);
      bool focused() {
        final at = FocusManager.instance.primaryFocus?.context;
        if (at == null || block.evaluate().isEmpty) return false;
        final target = tester.element(block.first);
        var inside = at == target;
        at.visitAncestorElements((e) => !(inside = inside || e == target));
        return inside;
      }

      Future<void> tabToIt() async {
        for (var i = 0; i < 60 && !focused(); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(focused(), isTrue);
      }

      await tabToIt();
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(dayShown(plus(t, 1)), findsOneWidget);
      expect(focused(), isFalse);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(BottomSheet), findsNothing);

      await press(tester, LogicalKeyboardKey.keyT);
      await tabToIt();
      await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
      await tester.pumpAndSettle();
      expect(dayShown(plus(t, 1)), findsOneWidget);
      expect(focused(), isFalse);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(BottomSheet), findsNothing);

      // On the page shown, a meeting still opens with Enter.
      await press(tester, LogicalKeyboardKey.keyT);
      await tabToIt();
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets("F1 lists the calendar's keys", (tester) async {
      await pump(tester);

      await press(tester, LogicalKeyboardKey.f1);

      expect(find.text('Keys in the calendar'), findsOneWidget);
      for (final line in calendarKeys) {
        expect(find.text(line.does), findsOneWidget, reason: line.does);
      }
      expect(find.text('Reply all'), findsNothing, reason: "the mail's");
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('Keys in the calendar'), findsNothing);
      expect(find.byType(CalendarScreen), findsOneWidget);
    });

    testWidgets('on a phone with a keyboard, the same keys', (tester) async {
      final c = await pump(tester,
          view: CalendarViewMode.month, size: const Size(400, 800));
      final t = today();
      final next = DateTime(t.year, t.month + 1);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('${months[next.month - 1]} ${next.year}'),
          findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyT);
      expect(find.text('${months[t.month - 1]} ${t.year}'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyD);
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
      expect(dayShown(t), findsOneWidget);
    });
  });

  group('never while typing', () {
    testWidgets('a text field with the focus, a key held down, or Ctrl or '
        'Alt with a letter: none of them is the calendar\'s', (tester) async {
      final done = <CalendarCommand>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CalendarKeys(
            onToday: () => done.add(CalendarCommand.today),
            onTurn: (d) => done
                .add(d < 0 ? CalendarCommand.previous : CalendarCommand.next),
            onView: (_) => done.add(CalendarCommand.day),
            onGoToDate: () => done.add(CalendarCommand.goToDate),
            onSearch: () => done.add(CalendarCommand.search),
            onNewMeeting: () => done.add(CalendarCommand.newMeeting),
            child: const Column(children: [TextField()]),
          ),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      expect(done, [CalendarCommand.today], reason: 'with nothing typed');

      await tester.showKeyboard(find.byType(TextField));
      for (final key in [
        LogicalKeyboardKey.keyT,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.slash,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(done, [CalendarCommand.today], reason: 'typing');

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(done, [CalendarCommand.today], reason: 'not with Ctrl or Alt');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(done, [CalendarCommand.today, CalendarCommand.next],
          reason: 'one turn for a key held down');
    });
  });
}
