import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
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

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    SampleMailEngine? engine,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine ?? SampleMailEngine()),
      ],
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

    testWidgets('a hit the open list also shows leaves the results when deleted',
        (tester) async {
      // The list's own delete went through and said so, and the row stayed
      // in the results; deleting it again hit a message already gone.
      final c = await pump(tester);
      final open = c.read(effectiveSelectedFolderIdProvider)!;
      final shown = {
        for (final m in c.read(messagesProvider(open)).value!) m.id,
      };
      final hits = await search(tester, 'the');
      final both = hits.map((t) => t.message).firstWhere(
            (m) => shown.contains(m.id),
          );
      c.read(selectedMessageIdsProvider.notifier).addAll([both.id]);
      await tester.pumpAndSettle();

      await tester.tap(inBar(find.byTooltip('Delete')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(
        c.read(searchResultsProvider).value!.any((m) => m.id == both.id),
        isFalse,
      );
    });

    testWidgets('marking several read goes on past one that fails, and says so',
        (tester) async {
      // It stopped at the first failure, said nothing, and left the ticks.
      final engine = _RefusesOne();
      final c = await pump(tester, engine: engine);
      final hits = (await search(tester, 'the'))
          .map((t) => t.message)
          .where((m) => !m.isRead)
          .take(3)
          .toList();
      expect(hits, hasLength(3));
      engine.refused = hits[1].id;
      c.read(selectedMessageIdsProvider.notifier).addAll(hits.map((m) => m.id));
      await tester.pumpAndSettle();

      await tester.tap(inBar(find.byTooltip('Mark read')));
      await tester.pumpAndSettle();

      expect(engine.markedRead, {hits[0].id, hits[2].id});
      expect(find.textContaining('Could not mark read 1 of 3'), findsOneWidget);
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

    testWidgets('the search box comes back with the search still in it',
        (tester) async {
      // The selection bar stands in for the box, which came back empty
      // after it, over a list still showing the hits for 'invoice'.
      final c = await pump(tester);
      final hits = await search(tester, 'invoice');
      await tester.longPress(
          find.byKey(ValueKey('search:${hits.first.message.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(SelectionBar), findsOneWidget);

      c.read(selectedMessageIdsProvider.notifier).clear();
      await tester.pumpAndSettle();

      expect(find.byType(SelectionBar), findsNothing);
      final box = tester.widget<TextField>(find.byType(TextField).last);
      expect(box.controller!.text, 'invoice');
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

    testWidgets('a hit from a folder that is not open opens in the pane',
        (tester) async {
      // On the tablet a tap selects rather than pushing a screen, and the
      // pane looked the selection up in the open folder's list alone: a hit
      // from Sent, Archive or further back left it empty.
      final c = await pump(tester);
      final hits = await search(tester, 'the');
      final listId = c.read(effectiveSelectedFolderIdProvider)!;
      final listed = {
        for (final m in c.read(messagesProvider(listId)).value ?? const [])
          m.id,
      };
      final elsewhere = hits
          .map((t) => t.message)
          .where((m) => !listed.contains(m.id) && !m.isRead)
          .firstOrNull;
      expect(elsewhere, isNotNull,
          reason: 'the sample data needs an unread hit outside the open list');

      await tester.tap(find.byKey(ValueKey('search:${elsewhere!.id}')));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageProvider)?.id, elsewhere.id);
      final stored = await c.read(mailEngineProvider).cachedMessage(elsewhere.id);
      expect(stored?.isRead, isTrue,
          reason: 'opened, so read, like any other message');
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

/// The sample engine, refusing to change one message.
class _RefusesOne extends SampleMailEngine {
  String? refused;
  final markedRead = <String>{};

  @override
  Future<void> setRead(String messageId, bool isRead) async {
    if (messageId == refused) throw StateError('the server said no');
    await super.setRead(messageId, isRead);
    if (isRead) markedRead.add(messageId);
  }
}
