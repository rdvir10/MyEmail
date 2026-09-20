import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/search_providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/selection_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Search hits can be ticked and acted on like any other rows, and any
/// rows can be forwarded whole.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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

  Future<List<MessageTile>> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField).last, query);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    return tester.widgetList<MessageTile>(find.byType(MessageTile)).toList();
  }

  Finder inBar(Finder f) =>
      find.descendant(of: find.byType(SelectionBar), matching: f);

  group('in search results', () {
    testWidgets('a long press ticks a hit and the bar appears', (tester) async {
      final c = await pump(tester);
      final hits = await search(tester, 'invoice');
      expect(hits.length, greaterThan(1));

      await tester.longPress(find.byKey(ValueKey('search:${hits.first.message.id}')));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider), {hits.first.message.id});
      expect(find.byType(SelectionBar), findsOneWidget);
      expect(find.byType(Checkbox), findsWidgets);
    });

    testWidgets('Select all takes every hit, not a screenful', (tester) async {
      final c = await pump(tester);
      final hits = await search(tester, 'the');
      await tester.longPress(find.byKey(ValueKey('search:${hits.first.message.id}')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Select all results'));
      await tester.pumpAndSettle();

      expect(
        c.read(selectedMessageIdsProvider),
        c.read(searchResultsProvider).value!.map((m) => m.id).toSet(),
      );
    });

    testWidgets('Delete takes the ticked hits out of their folders',
        (tester) async {
      final c = await pump(tester);
      final hits = await search(tester, 'invoice');
      final gone = hits.take(2).map((t) => t.message).toList();
      c.read(selectedMessageIdsProvider.notifier).addAll(gone.map((m) => m.id));
      await tester.pumpAndSettle();

      await tester.tap(inBar(find.byTooltip('Delete')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      final again = c.read(searchResultsProvider).value!;
      for (final m in gone) {
        expect(again.any((x) => x.id == m.id), isFalse, reason: m.subject);
      }
      expect(c.read(selectedMessageIdsProvider), isEmpty);
    });

    testWidgets('Forward as attachment starts a message carrying them whole',
        (tester) async {
      final c = await pump(tester);
      final hits = await search(tester, 'invoice');
      final two = hits.take(2).map((t) => t.message).toList();
      c.read(selectedMessageIdsProvider.notifier).addAll(two.map((m) => m.id));
      await tester.pumpAndSettle();

      await tester.tap(inBar(find.byTooltip('Forward as attachment')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('FW: 2 messages'), findsOneWidget);
      expect(find.textContaining('.eml'), findsNWidgets(2));
    });

    testWidgets('clearing the search lets the ticks go', (tester) async {
      final c = await pump(tester);
      final hits = await search(tester, 'invoice');
      c.read(selectedMessageIdsProvider.notifier).addAll([hits.first.message.id]);
      await tester.pumpAndSettle();

      // The bar stands where the search box was while anything is ticked,
      // so the query cannot be retyped from the screen; it can still change
      // underneath (a scope change, a cleared box on another pane).
      c.read(searchQueryProvider.notifier).set('');
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider), isEmpty,
          reason: 'a tick on a hit that is no longer shown is a trap');
    });
  });

  group('in a folder', () {
    testWidgets('the right-click menu forwards one message as a file',
        (tester) async {
      await pump(tester);
      final m = tester.widget<MessageTile>(find.byType(MessageTile).first).message;

      await tester.tap(find.byKey(ValueKey('tile:${m.id}')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Forward as attachment'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('FW: ${m.subject}'), findsOneWidget);
      expect(find.textContaining('.eml'), findsOneWidget);
    });
  });
}
