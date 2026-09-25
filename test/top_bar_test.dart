import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/search_providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/search_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';
import 'helpers/open_search.dart';

/// The bar above the list: which folder, whose, how many unread, and a
/// magnifier where the search box used to take a row of the screen.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(412, 915),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Finder inAppBar(Finder f) =>
      find.descendant(of: find.byType(AppBar), matching: f);

  group('on a phone the bar says', () {
    testWidgets('whose folder it is, under its name', (tester) async {
      final c = await pump(tester);
      c
          .read(selectedFolderIdProvider.notifier)
          .select('acct-side:INBOX');
      await tester.pumpAndSettle();

      expect(inAppBar(find.text('Inbox')), findsOneWidget);
      expect(inAppBar(find.text('projects@example.com')), findsOneWidget);
    });

    testWidgets('and that the unified Inbox is everyone\'s', (tester) async {
      final c = await pump(tester);
      c.read(selectedFolderIdProvider.notifier).select(kUnifiedInboxId);
      await tester.pumpAndSettle();

      expect(inAppBar(find.text('All accounts')), findsOneWidget);
    });

    testWidgets('how many are unread, as a number', (tester) async {
      final c = await pump(tester);
      c.read(selectedFolderIdProvider.notifier).select(kUnifiedInboxId);
      await tester.pumpAndSettle();
      final unread = c.read(folderIndexProvider)[kUnifiedInboxId]!.unreadCount;
      expect(unread, greaterThan(0), reason: 'the sample has unread mail');

      expect(inAppBar(find.text('$unread')), findsOneWidget);
      expect(find.byTooltip('$unread unread'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('is a magnifier, not a box, until it is asked for',
        (tester) async {
      await pump(tester);

      expect(find.byType(MessageSearchBar), findsNothing);
      expect(inAppBar(find.byTooltip('Search')), findsOneWidget);
    });

    testWidgets('asked for, the box comes out ready to type in',
        (tester) async {
      await pump(tester);
      await tester.tap(inAppBar(find.byTooltip('Search')));
      await tester.pumpAndSettle();

      expect(find.byType(MessageSearchBar), findsOneWidget);
      expect(tester.widget<TextField>(searchField).focusNode?.hasFocus, isTrue);
    });

    testWidgets('closed, it goes away and takes the search with it',
        (tester) async {
      final c = await pump(tester);
      final before = find.byType(MessageTile).evaluate().length;
      await openSearch(tester);
      await tester.enterText(searchField, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();

      expect(find.byType(MessageSearchBar), findsNothing);
      expect(c.read(searchQueryProvider), isEmpty);
      expect(find.byType(MessageTile).evaluate().length, before,
          reason: 'back to the folder, not the hits');
    });

    testWidgets('on a tablet the list has the magnifier too', (tester) async {
      await pump(tester, size: const Size(1400, 900));

      expect(find.byType(MessageSearchBar), findsNothing);
      // The ribbon's Search and the one above the list.
      expect(find.byTooltip('Search'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Search').last);
      await tester.pumpAndSettle();
      expect(find.byType(MessageSearchBar), findsOneWidget);
    });
  });
}
