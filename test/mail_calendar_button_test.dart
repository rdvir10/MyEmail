import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/meeting_ticker.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/folder_bar_layout.dart';
import 'package:myemail/ui/shell/folder_heading.dart';
import 'package:myemail/ui/shell/ribbon.dart';

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// The calendar one tap from the mail where there is no ribbon (calendar
/// idea #98): a button with today's date beside Search, on the phone's top
/// bar and over a tablet's list held upright. Drawn with the app's own
/// theme and in Roboto, whose widths decide what fits on a phone 360 wide.
void main() {
  setUpAll(() async {
    FakeWebViewPlatform.install();
    await loadRoboto();
  });

  const phone = Size(412, 915);
  const narrowPhone = Size(360, 780);
  const tabletUpright = Size(800, 1280);
  const tabletLyingDown = Size(1280, 800);

  /// The time as the app's meetings see it, moved by a test.
  late DateTime clock;

  setUp(() => clock = DateTime(2026, 11, 17, 10, 17));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = phone,
    double scale = 1.0,
    bool dark = false,
    bool folders = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ui = MemoryUiStateStore();
    // The folder pane beside the list, where there is room for one.
    if (!folders) await ui.writeString(UiStateKeys.folderPane, 'hidden');
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      meetingClockProvider.overrideWithValue(() => clock),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: const AppShell(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  final button = find.byKey(const ValueKey('mail-calendar'));
  final bar = find.byType(AppBar);
  Finder inBar(Finder f) => find.descendant(of: bar, matching: f);

  /// The day of the month the button shows.
  String dayShown(WidgetTester tester) => tester
      .widget<Text>(find.descendant(of: button, matching: find.byType(Text)))
      .data!;

  group('on the phone', () {
    testWidgets("beside Search, with today's date, named Calendar",
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      expect(inBar(button), findsOneWidget);
      expect(dayShown(tester), '17');
      // After Search, before the menu: the unread count keeps its place
      // beside the folder's name.
      final search = tester.getCenter(inBar(find.byTooltip('Search')));
      final menu = tester.getCenter(inBar(find.byTooltip('View and sort')));
      final at = tester.getCenter(button);
      expect(at.dx, greaterThan(search.dx));
      expect(at.dx, lessThan(menu.dx));
      expect(at.dy, closeTo(search.dy, 1));
      expect(find.byTooltip('Calendar'), findsOneWidget);
      // Named Calendar, not "17, Calendar": the number is part of the
      // picture.
      final said = tester.getSemantics(button).getSemanticsData();
      expect(said.tooltip, 'Calendar');
      expect(said.label, isNot(contains('17')));
      expect(said.flagsCollection.isButton, isTrue);
      semantics.dispose();
    });

    testWidgets('a tap opens the calendar on today, and Back is the mail '
        'where it was', (tester) async {
      final c = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider);
      final list = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((s) => s.position.maxScrollExtent > 100);
      list.position.jumpTo(100);
      await tester.pumpAndSettle();

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
      final opened = tester.widget<CalendarScreen>(find.byType(CalendarScreen));
      expect(opened.day, isNull, reason: 'today, as the folder list opens it');
      expect(opened.event, isNull);

      // Android's Back.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsNothing);
      expect(c.read(effectiveSelectedFolderIdProvider), folder);
      expect(list.position.pixels, 100);
    });

    testWidgets('with no account that has a calendar, it opens the calendar '
        'as the folder list does', (tester) async {
      // The sample's accounts sign in with app passwords: mail only.
      await pump(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
    });

    testWidgets('the folder list keeps its Calendar', (tester) async {
      await pump(tester);
      final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      scaffold.openDrawer();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(FolderTreePanel),
          matching: find.byKey(const ValueKey('open-calendar')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the date turns over at midnight with the app left open, '
        'and is right on coming back to it', (tester) async {
      clock = DateTime(2026, 11, 17, 23, 59, 40);
      await pump(tester);
      expect(dayShown(tester), '17');

      clock = DateTime(2026, 11, 18, 0, 0, 10);
      await tester.pump(MeetingTicker.tick);
      expect(dayShown(tester), '18');

      // Away overnight, and back the next morning: right at once, before
      // the next look at the time.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      clock = DateTime(2026, 11, 19, 7, 30);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(dayShown(tester), '19');
      await tester.pumpAndSettle();
    });

    for (final dark in [false, true]) {
      testWidgets('the date is drawn in the icons\' own colour '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        await pump(tester, dark: dark);
        final number = tester.widget<Text>(
            find.descendant(of: button, matching: find.byType(Text)));
        final search =
            find.descendant(of: bar, matching: find.byIcon(Icons.search));
        final ink = IconTheme.of(tester.element(search)).color;
        expect(ink, isNotNull);
        expect(number.style?.color, ink);
      });
    }

    // A name cut short ends in "…" at its own end: for a Hebrew one, on
    // its left. Before #98 the heading only shrank and was never cut.
    testWidgets('a Hebrew folder name reads from the right, and is cut at '
        'its own end', (tester) async {
      final c = await pump(tester, size: narrowPhone, scale: 1.3);
      final folder = c.read(folderIndexProvider).values.firstWhere(
          (f) => f.role == FolderRole.user && f.capabilities.canRename);
      final renamed = await tester.runAsync(() => c
          .read(foldersProvider.notifier)
          .rename(folder.id, 'ארכיון חשבוניות ספקים לשנת 2026'));
      c.read(selectedFolderIdProvider.notifier).select(renamed!.folder.id);
      await tester.pumpAndSettle();

      final lines = [
        for (final e in find
            .descendant(
                of: inBar(find.byType(FolderHeading)),
                matching: find.byType(RichText))
            .evaluate())
          e.renderObject! as RenderParagraph,
      ];
      final name = lines.first;
      expect(name.text.toPlainText(), startsWith('ארכיון'));
      expect(name.didExceedMaxLines, isTrue, reason: 'cut, as meant here');
      expect(name.textDirection, TextDirection.rtl);
      // Its account's address under it reads left to right as before.
      expect(lines.last.text.toPlainText(), contains('@'));
      expect(lines.last.textDirection, TextDirection.ltr);
      expect(tester.takeException(), isNull);
    });
  });

  group('the bar still fits', () {
    for (final size in [narrowPhone, phone]) {
      for (final scale in [1.0, 1.3]) {
        for (final inbox in [false, true]) {
          testWidgets(
              '${size.width.round()} wide, text at $scale, '
              '${inbox ? "an account's Inbox" : 'All Inboxes'}',
              (tester) async {
            final c = await pump(tester, size: size, scale: scale);
            if (inbox) {
              c.read(selectedFolderIdProvider.notifier).select(c
                  .read(folderIndexProvider)
                  .keys
                  .firstWhere((id) => id.endsWith(':INBOX')));
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);

            final heading = tester.getRect(inBar(find.byType(FolderHeading)));
            final unread = inBar(find.byType(FolderUnreadCount));
            final parts = [
              if (tester.getSize(unread).width > 0) tester.getRect(unread),
              tester.getRect(inBar(find.byTooltip('Search'))),
              tester.getRect(button),
              tester.getRect(inBar(find.byTooltip('View and sort'))),
            ];
            // Name, count, Search, Calendar and the menu, in that order,
            // none over another, all on the screen.
            expect(heading.left, greaterThanOrEqualTo(0));
            var right = heading.right;
            for (final part in parts) {
              expect(part.left, greaterThanOrEqualTo(right - 0.5));
              right = part.right;
            }
            expect(right, lessThanOrEqualTo(size.width));
            // The folder's name and whose it is, both still there, drawn
            // at no less than three quarters of their size: past that they
            // end in "…" rather than shrink further.
            final lines = [
              for (final e in find
                  .descendant(
                      of: inBar(find.byType(FolderHeading)),
                      matching: find.byType(RichText))
                  .evaluate())
                e.renderObject! as RenderParagraph,
            ];
            expect(lines, hasLength(2));
            final fitted = tester.renderObject<RenderFittedBox>(find.descendant(
                of: inBar(find.byType(FolderHeading)),
                matching: find.byType(FittedBox)));
            final drawnAt = fitted.size.width / fitted.child!.size.width;
            expect(drawnAt, greaterThanOrEqualTo(0.75 - 1e-6));
            for (final line in lines) {
              expect(line.size.width, greaterThan(0));
            }
            // On Ron's phone at the usual size, all of it, whole.
            if (size == phone && scale == 1.0) {
              expect(drawnAt, closeTo(1, 1e-6));
              expect(lines.any((l) => l.didExceedMaxLines), isFalse);
            }
          });
        }
      }
    }
  });

  /// The drawn size of the heading over a tablet's list, against its own.
  double headingOverList(WidgetTester tester) {
    final fitted = tester.renderObject<RenderFittedBox>(find.descendant(
        of: find.descendant(
            of: find.byType(FolderBarLayout),
            matching: find.byType(FolderHeading)),
        matching: find.byType(FittedBox)));
    return fitted.size.width / fitted.child!.size.width;
  }

  final overList =
      find.descendant(of: find.byType(FolderBarLayout), matching: button);
  final treeCalendar = find.descendant(
    of: find.byType(FolderTreePanel),
    matching: find.byKey(const ValueKey('open-calendar')),
  );

  group('on a tablet', () {
    testWidgets('held upright with the folders hidden, it is over the list '
        'beside Search', (tester) async {
      await pump(tester, size: tabletUpright, folders: false);
      expect(overList, findsOneWidget);
      expect(dayShown(tester), '17');
      final search = tester.getCenter(find.descendant(
          of: find.byType(FolderBarLayout),
          matching: find.byTooltip('Search')));
      expect(tester.getCenter(overList).dx, greaterThan(search.dx));
      expect(tester.getCenter(overList).dy, closeTo(search.dy, 1));
      expect(find.byType(Ribbon), findsNothing);

      await tester.tap(overList);
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsNothing);
    });

    testWidgets('held upright with the folders beside the list, their '
        'Calendar is the one', (tester) async {
      await pump(tester, size: tabletUpright);
      expect(overList, findsNothing);
      expect(treeCalendar, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets("lying down, the ribbon's Calendar is the one",
        (tester) async {
      await pump(tester, size: tabletLyingDown);
      expect(button, findsNothing);
      expect(
        find.descendant(
            of: find.byType(Ribbon), matching: find.text('Calendar')),
        findsOneWidget,
      );
    });
  });

  // A window 600 to 640 wide: the tablet split in two, a pop-up window.
  // With the folders beside it the list is under 300 wide, and the button
  // took the last of the folder's name: a sliver at 600, its row over by
  // 4.6. Their own Calendar is a tap away there, at the pane's foot.
  group('a narrow window', () {
    for (final width in [600.0, 640.0]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('${width.round()} wide, text at $scale, folders beside '
            'the list: no button over it, nothing over its edge',
            (tester) async {
          await pump(tester, size: Size(width, 1000), scale: scale);
          expect(tester.takeException(), isNull);
          expect(overList, findsNothing);
          expect(treeCalendar, findsOneWidget);
        });

        testWidgets('${width.round()} wide, text at $scale, folders hidden: '
            'the button, and the name whole', (tester) async {
          final c = await pump(tester,
              size: Size(width, 1000), scale: scale, folders: false);
          c.read(selectedFolderIdProvider.notifier).select(c
              .read(folderIndexProvider)
              .keys
              .firstWhere((id) => id.endsWith(':INBOX')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(overList, findsOneWidget);
          expect(headingOverList(tester), closeTo(1, 1e-6));
        });
      }
    }
  });
}
