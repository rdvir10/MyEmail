import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/windows/window_opener.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/window_handoff.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/window_providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/window_host.dart';

import 'fakes/fake_webview.dart';

/// A second window: opening one, and being one.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late FakeWindowOpener windows;

  Future<ProviderContainer> pump(WidgetTester tester, {Widget? home}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      windowOpenerProvider.overrideWithValue(windows),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: home ?? const AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> ctrlN(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  group('where there are windows', () {
    setUp(() => windows = FakeWindowOpener());

    testWidgets('a message being written can be moved to one',
        (tester) async {
      await pump(tester);
      await ctrlN(tester);
      await tester.enterText(find.byType(TextField).last, 'Moving house');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open in new window'));
      await tester.pumpAndSettle();

      final request = windows.opened.single as ComposeWindow;
      expect(request.draft.subject, 'Moving house');
      expect(find.byType(ComposeScreen), findsNothing,
          reason: 'moved, not lost: this copy closes without asking');
    });

    testWidgets('with the setting on, writing starts in one', (tester) async {
      final c = await pump(tester);
      c.read(composeInWindowProvider.notifier).set(true);
      await tester.pumpAndSettle();

      await ctrlN(tester);

      expect(windows.opened.single, isA<ComposeWindow>());
      expect(find.byType(ComposeScreen), findsNothing);
    });

    testWidgets('the open message can be sent to one from its menu',
        (tester) async {
      final c = await pump(tester);
      final id = c.read(selectedMessageIdProvider)!;

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in new window'));
      await tester.pumpAndSettle();

      expect((windows.opened.single as MessageWindow).message.id, id);
    });

    testWidgets('and any message from a right click', (tester) async {
      await pump(tester);
      final second = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .elementAt(1)
          .message;

      await tester.tap(
        find.byKey(ValueKey('tile:${second.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(PopupMenuItem<String>, 'Open in new window'),
      );
      await tester.pumpAndSettle();

      expect((windows.opened.single as MessageWindow).message.id, second.id);
    });
  });

  group('when the system swallows the launch', () {
    setUp(() => windows = FakeWindowOpener(opens: false));

    testWidgets('what was being written stays put', (tester) async {
      await pump(tester);
      await ctrlN(tester);
      await tester.enterText(find.byType(TextField).last, 'Not lost');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open in new window'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('Could not open a window. Still here.'), findsOneWidget);
    });

    testWidgets('the setting falls back to writing here', (tester) async {
      final c = await pump(tester);
      c.read(composeInWindowProvider.notifier).set(true);
      await tester.pumpAndSettle();

      await ctrlN(tester);

      expect(windows.opened, hasLength(1), reason: 'it was tried');
      expect(find.byType(ComposeScreen), findsOneWidget);
    });
  });

  group('where there are none', () {
    setUp(() => windows = FakeWindowOpener(supported: false));

    testWidgets('nothing offers one', (tester) async {
      final c = await pump(tester);
      c.read(composeInWindowProvider.notifier).set(true);
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Open in new window'), findsNothing);
      await tester.tapAt(const Offset(5, 5)); // close the menu
      await tester.pumpAndSettle();

      await ctrlN(tester);
      expect(find.byType(ComposeScreen), findsOneWidget,
          reason: 'the setting cannot send it anywhere');
      expect(find.byTooltip('Open in new window'), findsNothing);
      expect(windows.opened, isEmpty);
    });
  });

  group('being a window', () {
    setUp(() => windows = FakeWindowOpener());

    testWidgets('shows the message it was opened for, on its own',
        (tester) async {
      final c = await pump(tester);
      final message = c.read(selectedMessageProvider)!;

      await pump(tester, home: WindowHost(request: MessageWindow(message)));

      expect(find.byType(MessageScreen), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      expect(find.text(message.subject), findsWidgets);
    });

    testWidgets('does not change the folder the app opens on',
        (tester) async {
      // Opening a message in a window saved its folder as the selection,
      // so the next cold start opened on that account's Inbox instead of
      // the unified one.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryUiStateStore();
      ProviderContainer containerOn(UiStateStore store) {
        final c = ProviderContainer(overrides: [
          uiStateStoreProvider.overrideWithValue(store),
          windowOpenerProvider.overrideWithValue(windows),
        ]);
        addTearDown(c.dispose);
        return c;
      }

      final app = containerOn(store);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: app,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      final message = app.read(selectedMessageProvider)!;
      app.read(selectedFolderIdProvider.notifier).select(kUnifiedInboxId);
      await tester.pumpAndSettle();
      expect(store.readString(UiStateKeys.selected), kUnifiedInboxId);
      expect(message.folderId, isNot(kUnifiedInboxId));

      final window = containerOn(store);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: window,
        child: MaterialApp(home: WindowHost(request: MessageWindow(message))),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(MessageScreen), findsOneWidget);
      expect(window.read(effectiveSelectedFolderIdProvider), message.folderId,
          reason: 'the window still acts through the message folder');
      expect(store.readString(UiStateKeys.selected), kUnifiedInboxId);
    });

    testWidgets('shows the message being written', (tester) async {
      final c = await pump(tester);
      final accounts = await c.read(accountsProvider.future);
      final draft = Draft(
        accountId: accounts.first.id,
        kind: ComposeKind.newMessage,
        subject: 'From the other window',
      );

      await pump(tester, home: WindowHost(request: ComposeWindow(draft)));

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('From the other window'), findsOneWidget);
    });
  });
}
