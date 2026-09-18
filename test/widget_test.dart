import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

Widget _panelHarness() {
  return const ProviderScope(
    child: MaterialApp(home: Scaffold(body: FolderTreePanel())),
  );
}

Widget _appHarness() {
  return const ProviderScope(child: MaterialApp(home: AppShell()));
}

/// The default test surface is 800x600 logical pixels, which is below the
/// tablet breakpoint. Widen it to exercise the two-pane layout.
void _useWideScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  // A folder lands on a message, so the reading pane — and the web view it
  // renders the body in — is built by every layout test here.
  setUpAll(FakeWebViewPlatform.install);

  // The panel has a footer now (Quick Steps, Add account), so the default
  // 800x600 surface pushes tree rows out of the build window.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(800, 1400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('FolderTreePanel', () {
    testWidgets('renders accounts and system folders', (tester) async {
      await tester.pumpWidget(_panelHarness());
      await tester.pumpAndSettle();

      // Section headers render account names uppercased.
      expect(find.text('PERSONAL'), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);
      // System folders show Outlook's names, not Gmail's.
      expect(find.text('Inbox'), findsWidgets);
      expect(find.text('INBOX'), findsNothing);
      expect(find.text('Deleted'), findsWidgets);
      expect(find.text('Trash'), findsNothing);
      expect(find.text('Search folders'), findsOneWidget);
    });

    testWidgets('tapping the twisty expands a folder', (tester) async {
      await tester.pumpWidget(_panelHarness());
      await tester.pumpAndSettle();

      expect(find.text('Receipts'), findsNothing);

      final financeTile = find.ancestor(
        of: find.text('Finance'),
        matching: find.byType(InkWell),
      );
      final twisty = find.descendant(
        of: financeTile.first,
        matching: find.byType(IconButton),
      );
      await tester.tap(twisty.first);
      await tester.pumpAndSettle();

      expect(find.text('Receipts'), findsOneWidget);
    });

    testWidgets('search filters the tree and clears again', (tester) async {
      await tester.pumpWidget(_panelHarness());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'travel');
      await tester.pumpAndSettle();

      expect(find.text('Travel'), findsOneWidget);
      expect(find.text('Newsletters'), findsNothing);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Newsletters'), findsOneWidget);
    });

    testWidgets('a two-line search result does not overflow', (tester) async {
      await tester.pumpWidget(_panelHarness());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '2026');
      await tester.pumpAndSettle();

      expect(find.text('Finance › Receipts › 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the selected folder is announced to assistive tech',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_panelHarness());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();

      final tile = find.ancestor(
        of: find.text('Travel'),
        matching: find.byType(Semantics),
      );
      // The tile also carries the InkWell's tap and focus semantics; only the
      // selected flag is the point here.
      expect(
        tester.getSemantics(tile.first),
        isSemantics(isSelected: true),
      );
      handle.dispose();
    });
  });

  group('AppShell', () {
    testWidgets('phone layout: choosing a folder closes the drawer',
        (tester) async {
      // A real phone: 411dp wide, below the 600dp two-pane breakpoint. The
      // suite's default 800dp surface is a tablet in portrait now.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_appHarness());
      await tester.pumpAndSettle();

      // Default selection is the unified inbox with two accounts.
      expect(find.text('All Inboxes'), findsWidgets);
      expect(find.text('Search folders'), findsNothing,
          reason: 'drawer starts closed');

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Search folders'), findsOneWidget);

      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();

      expect(find.text('Search folders'), findsNothing,
          reason: 'drawer closes after a selection');
      expect(find.widgetWithText(AppBar, 'Travel'), findsOneWidget);
    });

    testWidgets('tablet layout: tree and content side by side', (tester) async {
      _useWideScreen(tester);
      await tester.pumpWidget(_appHarness());
      await tester.pumpAndSettle();

      expect(find.text('Search folders'), findsOneWidget,
          reason: 'tree is a permanent pane');
      expect(find.byTooltip('Open navigation menu'), findsNothing,
          reason: 'no drawer button on a wide screen');
      expect(find.byType(ReadingPane), findsOneWidget,
          reason: 'the reading pane is present, holding the message the '
              'list landed on');

      await tester.tap(find.text('Newsletters'));
      await tester.pumpAndSettle();
      expect(find.text('231 unread'), findsOneWidget,
          reason: 'folder title bar shows the unread count');
    });
  });
}
