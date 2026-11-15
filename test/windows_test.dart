import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/windows/window_opener.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/domain/quick_step.dart';
import 'package:myemail/domain/window_handoff.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/held_sends.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/quick_steps.dart';
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

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Widget? home,
    MailEngine? engine,
    UiStateStore? store,
    bool foldersFirst = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(store ?? MemoryUiStateStore()),
      windowOpenerProvider.overrideWithValue(windows),
      if (engine != null) mailEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(c.dispose);
    // A window's message counts as opened, for marking it read, only once
    // its folder is known (see ReadingPane), and the sample mailbox, slow
    // on purpose, has not said what its folders are by the first frames.
    if (foldersFirst) {
      c.listen(foldersProvider, (_, _) {});
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        // A scope of its own for each container. Pumped into the last one,
        // a second container is never told about frames, and what the open
        // message lets go of at the end waits on a timer the test leaves
        // running.
        key: ObjectKey(c),
        container: c,
        child: MaterialApp(home: home ?? const AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  /// Each time the window's copy of the app asked Android to end it.
  List<String> windowEndings(WidgetTester tester) {
    final ended = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') ended.add(call.method);
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return ended;
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

    testWidgets(
        'a second tap while the window opens moves it once, and leaves the '
        'mail under it', (tester) async {
      // The second tap read the message again and opened a second window,
      // and its close took the mail away, leaving a blank screen.
      final slow = _SlowOpener();
      windows = slow;
      await pump(tester);
      await ctrlN(tester);

      await tester.tap(find.byTooltip('Open in new window'));
      await tester.pump();
      await tester.tap(find.byTooltip('Open in new window'),
          warnIfMissed: false);
      await tester.pump();
      slow.answer.complete();
      await tester.pumpAndSettle();

      expect(windows.opened, hasLength(1));
      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.byType(AppShell), findsOneWidget);
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
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'More'));
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
        key: ObjectKey(app),
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
      // A scope of its own, as in pump().
      await tester.pumpWidget(UncontrolledProviderScope(
        key: ObjectKey(window),
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

  // A window starts knowing none of its folders, and its message counts as
  // opened, for marking it read, through its folder's list. Opened before
  // the folders were known, it never counted, under any setting.
  group('marked read in a window', () {
    setUp(() => windows = FakeWindowOpener());

    /// An unread message open in a window, under [when], its folders not
    /// yet known as it shows.
    Future<(_HeldEngine, MailMessage)> openUnread(
      WidgetTester tester,
      MarkReadWhen when,
    ) async {
      final c = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final message =
          c.read(sortedMessagesProvider(folder)).firstWhere((m) => !m.isRead);
      final engine = _HeldEngine()..answer();
      final store = MemoryUiStateStore()
        ..writeString(UiStateKeys.display,
            jsonEncode(DisplaySettings(markRead: when).toJson()));
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)),
          engine: engine,
          store: store);
      return (engine, message);
    }

    testWidgets('When it opens: once its folders are known', (tester) async {
      final (engine, message) = await openUnread(tester, MarkReadWhen.opened);
      expect(engine.marked.toSet(), {message.id});
    });

    testWidgets('After 5 seconds: five seconds after that, not before',
        (tester) async {
      final (engine, message) =
          await openUnread(tester, MarkReadWhen.afterDelay);
      expect(engine.marked, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(engine.marked.toSet(), {message.id});
    });

    testWidgets('Never: not at all, as before', (tester) async {
      final (engine, _) = await openUnread(tester, MarkReadWhen.never);
      await tester.pump(const Duration(seconds: 10));
      expect(engine.marked, isEmpty);
    });
  });

  // A window is a copy of the app of its own, and ending the window ends
  // it, with whatever it had asked of a server and not yet heard back
  // about. A delete still on its way went with it: the message stayed in
  // the Inbox, and nothing said so.
  group('ending a window', () {
    setUp(() => windows = FakeWindowOpener());

    Finder inPane(Finder f) =>
        find.descendant(of: find.byType(ReadingPane), matching: f);

    /// A message from the sample mailbox, [unread] or the one it opens on.
    Future<MailMessage> aMessage(WidgetTester tester,
        {bool unread = false}) async {
      final c = await pump(tester);
      // Into a typed local: returned straight from the read, the read
      // failed inside Riverpod.
      final MailMessage open = c.read(selectedMessageProvider)!;
      if (!unread) return open;
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      return c
          .read(sortedMessagesProvider(folder))
          .firstWhere((m) => !m.isRead);
    }

    testWidgets('waits for a delete to reach the server', (tester) async {
      final message = await aMessage(tester);
      final ended = windowEndings(tester);
      final engine = _HeldEngine();
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)), engine: engine);

      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(MessageScreen), findsNothing,
          reason: 'the message goes at once, as it does anywhere');
      expect(engine.deleted, [message.id]);
      expect(ended, isEmpty, reason: 'the server has not answered yet');
      expect(find.text('Telling the server…'), findsOneWidget);

      // Back would end it as surely as the window closing itself.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(ended, isEmpty);

      engine.answer();
      await tester.pump(const Duration(seconds: 1));
      expect(ended, hasLength(1), reason: 'and then it ends');
    });

    testWidgets('marks a message read on the way out, under When I move on, '
        'before it ends', (tester) async {
      // The mark is sent as the message is left, which in a window used to
      // be after the window had been told to end.
      final message = await aMessage(tester, unread: true);
      final ended = windowEndings(tester);
      final engine = _HeldEngine();
      final store = MemoryUiStateStore()
        ..writeString(
          UiStateKeys.display,
          jsonEncode(
              const DisplaySettings(markRead: MarkReadWhen.leaving).toJson()),
        );
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)),
          engine: engine,
          store: store,
          foldersFirst: true);
      expect(engine.marked, isEmpty, reason: 'not while it is open');

      await tester.pageBack();
      await tester.pump();

      expect(engine.marked, [message.id]);
      expect(ended, isEmpty);

      engine.answer();
      await tester.pump(const Duration(seconds: 1));
      expect(ended, hasLength(1));
    });

    testWidgets('does not wait for good on a server that never answers',
        (tester) async {
      final message = await aMessage(tester);
      final ended = windowEndings(tester);
      final engine = _HeldEngine();
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)), engine: engine);

      // From the keys this time: Ctrl+D, as the header's Delete.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(engine.deleted, [message.id]);

      await tester.pump(const Duration(seconds: 29));
      expect(ended, isEmpty);
      // Ended then without a word, it looked as though it had all gone.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('The server has not answered, so the change may not '
          'have been made.'), findsOneWidget);
      expect(find.text('Telling the server…'), findsNothing);
      expect(ended, isEmpty, reason: 'up long enough to be read');
      await tester.pump(const Duration(seconds: 5));
      expect(ended, hasLength(1));

      engine.answer();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a refusal is said on it before it ends', (tester) async {
      // It closed as after a delete that had gone, with the message still
      // in its folder and the bar saying why gone with the window.
      final message = await aMessage(tester);
      final ended = windowEndings(tester);
      final engine = _HeldEngine()..refuseDeletes = true;
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)), engine: engine);

      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      engine.answer();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(MessageScreen), findsNothing);
      expect(find.textContaining('Could not delete'), findsOneWidget,
          reason: 'said on the window, which is all there is by then');
      expect(ended, isEmpty, reason: 'up while that is read');

      // The bar's own five seconds, counted once it is all the way up,
      // and its way out.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 4));
      expect(ended, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Could not delete'), findsNothing);
      expect(ended, hasLength(1));
    });

    /// A delete in a window that goes only part way, and so says so with
    /// Undo for what went, and that Undo pressed on the window.
    Future<(List<String>, _HeldEngine)> undoAPartDelete(
      WidgetTester tester, {
      bool refuseUndo = false,
    }) async {
      final message = await aMessage(tester);
      final ended = windowEndings(tester);
      final engine = _HeldEngine()
        ..partlyRefuseDeletes = true
        ..refuseUndo = refuseUndo;
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)), engine: engine);
      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      engine.answer();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Deleted 1 of 1'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(engine.undone, hasLength(1));
      return (ended, engine);
    }

    testWidgets('waits for an Undo pressed on a refusal', (tester) async {
      // The bar going ended the window with the putting back still on its
      // way: some put back and some not, and nothing said.
      final (ended, engine) = await undoAPartDelete(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(ended, isEmpty, reason: 'the undo has not come back');
      expect(find.text('Telling the server…'), findsOneWidget);

      engine.answerUndo();
      await tester.pump(const Duration(seconds: 1));
      expect(ended, hasLength(1), reason: 'put back, and so done');
    });

    testWidgets('an Undo refused is said before it ends', (tester) async {
      final (ended, engine) = await undoAPartDelete(tester, refuseUndo: true);
      engine.answerUndo();
      await tester.pump(const Duration(seconds: 1));
      // Said once the bar it was pressed on has gone.
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Could not undo'), findsOneWidget);
      expect(ended, isEmpty, reason: 'up while that is read');

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(ended, hasLength(1));
    });

    testWidgets('waits for an invitation answer still on its way',
        (tester) async {
      // Back while the answer was being sent ended the window with it: the
      // organiser was never told, and nothing said so.
      final engine = _HeldEngine()..invitations = true;
      final message = (await tester.runAsync(() async {
        final inbox = (await engine.loadFolders('acct-personal'))
            .firstWhere((f) => f.role == FolderRole.inbox);
        return (await engine.loadMessages(inbox.id)).first;
      }))!;
      final ended = windowEndings(tester);
      await pump(tester,
          home: WindowHost(request: MessageWindow(message)), engine: engine);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      await tester.pump();
      expect(engine.answered, [message.id]);

      await tester.pageBack();
      await tester.pump();
      expect(ended, isEmpty, reason: 'the organiser has not been told yet');

      engine.answer();
      await tester.pump(const Duration(seconds: 1));
      expect(ended, hasLength(1));
    });

    testWidgets('waits for a Quick Step still on its way', (tester) async {
      // A step runs from the keys on a message's own screen and leaves the
      // screen where it is, so Back can come while it is still going.
      final message = await aMessage(tester);
      final ended = windowEndings(tester);
      final engine = _HeldEngine();
      final c = await pump(tester,
          home: WindowHost(request: MessageWindow(message)), engine: engine);
      c.read(quickStepsProvider.notifier).add(const QuickStep(
            id: 'bin',
            name: 'Bin it',
            actions: [QuickStepAction(QuickStepActionType.delete)],
          ));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(engine.deleted, [message.id]);

      await tester.pageBack();
      await tester.pump();
      expect(ended, isEmpty, reason: 'the step has not been answered yet');

      engine.answer();
      await tester.pump(const Duration(seconds: 1));
      expect(ended, hasLength(1));
    });

    testWidgets('closed with nothing on its way, it ends at once, as before',
        (tester) async {
      final message = await aMessage(tester);
      final ended = windowEndings(tester);
      await pump(tester, home: WindowHost(request: MessageWindow(message)));

      await tester.pageBack();
      await tester.pump();

      expect(ended, hasLength(1));
      expect(find.text('Telling the server…'), findsNothing);
    });

    testWidgets('a message written in one ends it once sent, as before',
        (tester) async {
      final c = await pump(tester);
      final accounts = await c.read(accountsProvider.future);
      final ended = windowEndings(tester);
      final engine = _HeldEngine();
      final draft = Draft(
        accountId: accounts.first.id,
        kind: ComposeKind.newMessage,
        to: const [MailAddress(email: 'dana@example.com')],
        subject: 'Numbers',
        htmlBody: '<p>Thursday.</p>',
      );
      await pump(tester,
          home: WindowHost(request: ComposeWindow(draft)), engine: engine);

      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      expect(engine.sent.single.subject, 'Numbers');
      expect(ended, hasLength(1));
      expect(find.text('Telling the server…'), findsNothing);
      // The folder counts read again after a send, as after any.
      await tester.pumpAndSettle();
    });
  });

  // Undo Send holds a message in this copy of the app's memory for its
  // seconds. A reply written on a message's window was held so, and Back on
  // the message within those seconds ended the window and the reply with
  // it, never sent and nothing said. No Undo Send in a window, as already
  // in a window of its own: it goes at once, and the screen waits for it.
  group('sending from a message window', () {
    setUp(() => windows = FakeWindowOpener());

    Finder inPane(Finder f) =>
        find.descendant(of: find.byType(ReadingPane), matching: f);

    /// Undo Send at five seconds, and no question about files.
    MemoryUiStateStore undoOnFive() => MemoryUiStateStore()
      ..writeString(
        UiStateKeys.display,
        jsonEncode(const DisplaySettings(
          undoSend: UndoSend.five,
          attachmentReminder: false,
        ).toJson()),
      );

    /// The message the sample mailbox opens on, open in a window, and a
    /// reply to it begun there.
    Future<(ProviderContainer, _HeldEngine)> replyInAWindow(
      WidgetTester tester, {
      bool refuse = false,
    }) async {
      final first = await pump(tester);
      final MailMessage message = first.read(selectedMessageProvider)!;
      final engine = _HeldEngine()
        ..answer()
        ..refuseSends = refuse;
      final c = await pump(tester,
          home: WindowHost(request: MessageWindow(message)),
          engine: engine,
          store: undoOnFive());
      await tester.tap(inPane(find.byTooltip('Reply')));
      await tester.pumpAndSettle();
      expect(find.byType(ComposeScreen), findsOneWidget);
      return (c, engine);
    }

    testWidgets('a reply goes at once, not held for Undo', (tester) async {
      final ended = windowEndings(tester);
      final (c, engine) = await replyInAWindow(tester);

      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      expect(engine.sent, hasLength(1), reason: 'gone before the screen left');
      expect(c.read(heldSendsProvider), isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget,
          reason: 'back to the message, the window still there');
      expect(ended, isEmpty);
    });

    testWidgets('a reply refused stays open, saying why', (tester) async {
      final ended = windowEndings(tester);
      final (c, engine) = await replyInAWindow(tester, refuse: true);

      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('The server said no.'), findsOneWidget);
      expect(engine.sent, isEmpty);
      expect(c.read(heldSendsProvider), isEmpty);
      expect(ended, isEmpty);
    });

    testWidgets('in the main window, Undo Send still holds a reply',
        (tester) async {
      final engine = _HeldEngine()..answer();
      final c = await pump(tester, engine: engine, store: undoOnFive());
      await tester.tap(inPane(find.byTooltip('Reply')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      expect(engine.sent, isEmpty, reason: 'held for Undo');
      expect(c.read(heldSendsProvider), hasLength(1));
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(engine.sent, hasLength(1));
    });
  });

  // The Android half, which no Dart test runs, read where it is written.
  // Told "no window" about one that opened, the app deleted the hand-off
  // and opened the draft behind it, and the window came up empty: on the
  // tablet, Forward did nothing visible once Recents held eight windows.
  group('on Android', () {
    const kotlin = 'android/app/src/main/kotlin/com/rdvir/mailtree';
    String read(String path) => File(path).readAsStringSync();

    test('a window is known to be open because it says so', () {
      final bridge = read('$kotlin/WindowsBridge.kt');
      expect(bridge, isNot(contains('appTasks')),
          reason: 'a new window can push an old one out of Recents, so the '
              'count of tasks does not go up');
      expect(bridge, isNot(contains('Thread.sleep')),
          reason: "the new window's onCreate runs on the main thread");
      expect(read('$kotlin/WindowActivity.kt'),
          contains('WindowsBridge.arrived(intent.getStringExtra("route"))'));
    });

    test('a closed window leaves Recents', () {
      final window = RegExp(
        r'<activity\b[^>]*android:name="\.WindowActivity"[^>]*>',
      ).firstMatch(read('android/app/src/main/AndroidManifest.xml'))!.group(0)!;
      expect(window, contains('android:autoRemoveFromRecents="true"'));
    });
  });
}

/// The sample mailbox, whose deletes and read marks wait to be told to
/// answer, and whose sends go at once: a server a window is waiting on.
class _HeldEngine extends SampleMailEngine {
  final deleted = <String>[];
  final marked = <String>[];
  final sent = <Draft>[];
  final _answer = Completer<void>();

  void answer() => _answer.complete();

  /// Deletes refused once answered, as a server says no.
  bool refuseDeletes = false;

  /// Deletes that go only part way once answered: what went is said to
  /// have gone to Trash, with ids to put it back by, and the rest refused.
  bool partlyRefuseDeletes = false;

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    deleted.addAll(messageIds);
    await _answer.future;
    if (refuseDeletes) throw StateError('The server said no.');
    if (partlyRefuseDeletes) {
      final id = messageIds.first;
      final folderId = id.substring(0, id.lastIndexOf('#'));
      throw PartialMove(
        done: [
          MessageMove(
            fromFolderId: folderId,
            toFolderId: '$folderId-trash',
            movedIds: ['$folderId-trash#1'],
          ),
        ],
        moved: messageIds,
        cause: StateError('The rest were refused.'),
      );
    }
    return super.deleteMessages(messageIds);
  }

  /// Moves put back, which wait for [answerUndo]; refused then where
  /// [refuseUndo].
  final undone = <MessageMove>[];
  bool refuseUndo = false;
  final _undoAnswer = Completer<void>();

  void answerUndo() => _undoAnswer.complete();

  @override
  Future<void> undoMoves(List<MessageMove> moves) async {
    undone.addAll(moves);
    await _undoAnswer.future;
    if (refuseUndo) throw StateError('The server said no to that too.');
  }

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) async {
    marked.addAll(messageIds);
    await _answer.future;
    return super.setMessagesRead(messageIds, isRead);
  }

  /// A message the list does not hold yet is marked here instead. Also
  /// how the sample marks each of a batch, so a batch is noted twice.
  @override
  Future<void> setRead(String messageId, bool isRead) async {
    marked.add(messageId);
    await _answer.future;
    return super.setRead(messageId, isRead);
  }

  /// Sends refused, as a server says no.
  bool refuseSends = false;

  @override
  Future<void> sendDraft(Draft draft) async {
    if (refuseSends) throw const SendFailed('The server said no.');
    sent.add(draft);
  }

  /// Every message an invitation ([_invitation]), whose answers wait to
  /// be told to answer as the rest do.
  bool invitations = false;
  final answered = <String>[];

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    final body = await super.loadMessageBody(messageId);
    if (!invitations) return body;
    return MailBody(text: body.text, html: body.html, calendar: _invitation);
  }

  @override
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) async {
    answered.add(messageId);
    await _answer.future;
    return super.respondToInvite(messageId, invite, response,
        note: note, send: send, proposal: proposal);
  }
}

/// A meeting request to the sample mailbox's personal account.
final _invitation = [
  'BEGIN:VCALENDAR',
  'METHOD:REQUEST',
  'BEGIN:VEVENT',
  'UID:plan-1@example.com',
  'SUMMARY:Planning',
  'DTSTART:20261028T100000Z',
  'DTEND:20261028T110000Z',
  'ORGANIZER;CN=Dana Levi:mailto:dana@example.com',
  'ATTENDEE;CN=Personal:mailto:personal@example.com',
  'END:VEVENT',
  'END:VCALENDAR',
].join('\r\n');

/// A system slow to say the window has opened.
class _SlowOpener extends FakeWindowOpener {
  final answer = Completer<void>();

  @override
  Future<bool> open(WindowRequest request) async {
    opened.add(request);
    await answer.future;
    return opens;
  }
}
