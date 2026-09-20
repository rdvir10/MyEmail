import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Delete from the open message's own toolbar.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
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

  Finder inPane(Finder f) =>
      find.descendant(of: find.byType(ReadingPane), matching: f);

  bool inList(ProviderContainer c, String id) {
    final folder = c.read(effectiveSelectedFolderIdProvider)!;
    return c.read(messagesProvider(folder)).value!.any((m) => m.id == id);
  }

  testWidgets('on a tablet, Delete takes the message out and empties the pane',
      (tester) async {
    final c = await pump(tester, const Size(1400, 900));
    final id = c.read(selectedMessageIdProvider)!;
    expect(inPane(find.byTooltip('Flag')), findsOneWidget,
        reason: 'room for both here');

    await tester.tap(inPane(find.byTooltip('Delete')));
    await tester.pumpAndSettle();

    expect(inList(c, id), isFalse);
    // The list lands on another message, as it does whenever the selection
    // goes; what must not happen is the deleted one staying on show.
    for (final pane in tester.widgetList<ReadingPane>(find.byType(ReadingPane))) {
      expect(pane.message.id, isNot(id));
    }
  });

  group('on a phone', () {
    Future<(ProviderContainer, String)> openFirst(WidgetTester tester) async {
      final c = await pump(tester, const Size(400, 900));
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
      return (c, first.message.id);
    }

    testWidgets('Delete stands where the flag was, and closes the screen',
        (tester) async {
      final (c, id) = await openFirst(tester);
      expect(inPane(find.byTooltip('Flag')), findsNothing);
      expect(inPane(find.byTooltip('Remove flag')), findsNothing);

      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(MessageScreen), findsNothing);
      expect(inList(c, id), isFalse);
    });

    testWidgets('the flag moved into the three-dot menu', (tester) async {
      final (c, id) = await openFirst(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      bool flagged() => c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.id == id)
          .isFlagged;
      final before = flagged();

      await tester.tap(inPane(find.byTooltip('More')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(before ? 'Remove flag' : 'Flag'));
      await tester.pumpAndSettle();

      expect(flagged(), !before);
    });
  });
}
