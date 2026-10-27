import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/files/message_files.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/windows/window_opener.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/message_transfer.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/window_providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/folder_tree/folder_tile.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/file_drop_host.dart';

import 'fakes/fake_webview.dart';

/// A message as a file: copied, dragged, and taken back as a move.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late FakeFileBridge bridge;
  late FakeMessageFiles files;
  late FakeWindowOpener windows;

  setUp(() {
    bridge = FakeFileBridge();
    files = FakeMessageFiles();
    windows = FakeWindowOpener();
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    SampleMailEngine? engine,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      if (engine != null) mailEngineProvider.overrideWithValue(engine),
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      fileBridgeProvider.overrideWithValue(bridge),
      messageFilesProvider.overrideWithValue(files),
      windowOpenerProvider.overrideWithValue(windows),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: FileDropHost(child: AppShell())),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  MailMessage first(WidgetTester tester) =>
      tester.widget<MessageTile>(find.byType(MessageTile).first).message;

  /// Where on screen the first folder row matching [test] is.
  Offset folderAt(WidgetTester tester, bool Function(MailFolder f) test) {
    final tile = tester
        .widgetList<FolderTile>(find.byType(FolderTile))
        .firstWhere((t) => test(t.row.folder));
    return tester.getCenter(find.byWidget(tile));
  }

  Future<void> dropOn(WidgetTester tester, MailMessage m, Offset at) async {
    bridge.drop(const [], label: messageDragLabel, text: m.id, at: at);
    await tester.pumpAndSettle();
  }

  /// [entry] from under More, in [m]'s right-click menu.
  Future<void> fromMore(WidgetTester tester, MailMessage m, String entry) async {
    await tester.tap(find.byKey(ValueKey('tile:${m.id}')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'More'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, entry));
    await tester.pumpAndSettle();
  }

  test('the file name says which message it was', () {
    final m = MailMessage(
      id: 'a:INBOX#1',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: 1,
      subject: 'Re: Q3 numbers — final!',
      from: const MailAddress(email: 'x@example.com'),
      to: const [],
      date: DateTime(2026, 9, 20),
      preview: '',
    );
    expect(emlFileName(m), 're-q3-numbers-final-2026-09-20.eml');
  });

  test('the sample engine hands a message back as it arrived', () async {
    final engine = SampleMailEngine();
    final account = (await engine.loadAccounts()).first;
    final inbox = (await engine.loadFolders(account.id))
        .firstWhere((f) => f.role == FolderRole.inbox);
    final m = (await engine.loadMessages(inbox.id)).first;

    final raw = await engine.rawMessage(m.id);

    expect(raw, contains('Subject: ${m.subject}'));
    expect(raw, contains('From: '));
    expect(raw, contains('\r\n\r\n'), reason: 'headers, a blank line, a body');
  });

  group('copying', () {
    testWidgets('from the right-click menu puts an .eml on the clipboard',
        (tester) async {
      await pump(tester);
      final m = first(tester);

      await fromMore(tester, m, 'Copy');

      expect(bridge.copied.single, endsWith(emlFileName(m)));
      expect(files.written[emlFileName(m)], contains('Subject: ${m.subject}'));
      expect(find.text('Message copied'), findsOneWidget);
    });

    testWidgets('Ctrl+C copies the open message', (tester) async {
      final c = await pump(tester);
      final id = c.read(selectedMessageIdProvider)!;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(bridge.copied, hasLength(1));
      expect(files.written.values.single, contains(id.split('#').last),
          reason: 'the uid is in the Message-ID');
    });

    testWidgets('pasting it into a message attaches it', (tester) async {
      await pump(tester);
      final m = first(tester);
      await fromMore(tester, m, 'Copy');
      // The fake clipboard holds what the fake bridge was given.
      bridge.onClipboard = [
        IncomingFile(
          path: bridge.copied.single,
          name: emlFileName(m),
          mimeType: emlMimeType,
          sizeBytes: 10,
        ),
      ];

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byType(ComposeScreen), findsOneWidget);
      // Paste goes through the real file reader, which needs a disk.
      expect(find.byTooltip('Paste file'), findsOneWidget);
    });
  });

  group('dragging', () {
    testWidgets('in split screen, a long press and pull drags the .eml out',
        (tester) async {
      windows.multiWindow = true;
      final c = await pump(tester);
      await c.read(multiWindowModeProvider.notifier).refresh();
      await tester.pumpAndSettle();
      final m = first(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tile:${m.id}'))),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(bridge.draggedFiles.single.map((f) => f.name), [emlFileName(m)]);
      expect(bridge.draggedLabel, messageDragLabel);
      expect(bridge.draggedText, m.id);
    });

    test('two messages with the same name get files of their own', () async {
      // A Hebrew subject keeps none of its letters in the name, so replies
      // on one day shared one path and a drag delivered copies of the last.
      final files = FakeMessageFiles();
      final a = await files.writeEml('message-2026-09-23.eml', 'A',
          messageId: 'acct:INBOX#1');
      final b = await files.writeEml('message-2026-09-23.eml', 'B',
          messageId: 'acct:INBOX#2');

      expect(a.path, isNot(b.path));
      expect(emlFolderFor('acct:INBOX#1'), isNot(emlFolderFor('acct_INBOX_1')));
    });

    testWidgets('full screen, the same pull stays inside the app',
        (tester) async {
      await pump(tester);
      final m = first(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tile:${m.id}'))),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(bridge.draggedFiles, isEmpty);
    });

    // A hold that is let go where it was opens the row's menu (3.7.0); one
    // pulled somewhere was a drag, and must not.
    testWidgets('a pull onto a folder moves it there, and no menu follows',
        (tester) async {
      final c = await pump(tester);
      final m = first(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final to = folderAt(
        tester,
        (f) =>
            f.id != m.folderId &&
            f.accountId == m.accountId &&
            f.capabilities.canAcceptMessages,
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tile:${m.id}'))),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveTo(to - const Offset(0, 4));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final list = c.read(messagesProvider(folder)).value!;
      expect(list.any((x) => x.id == m.id), isFalse, reason: 'moved out');
      expect(find.byType(PopupMenuItem<String>), findsNothing);
    });

    testWidgets('held and let go where it was, the row opens its menu',
        (tester) async {
      await pump(tester);
      final m = first(tester);

      await tester.longPress(find.byKey(ValueKey('tile:${m.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
      expect(find.widgetWithText(PopupMenuItem<String>, 'Move to…'),
          findsOneWidget);
      expect(bridge.draggedFiles, isEmpty);
    });

    testWidgets('in split screen too, rather than a drag out', (tester) async {
      windows.multiWindow = true;
      final c = await pump(tester);
      await c.read(multiWindowModeProvider.notifier).refresh();
      await tester.pumpAndSettle();
      final m = first(tester);

      await tester.longPress(find.byKey(ValueKey('tile:${m.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
      expect(bridge.draggedFiles, isEmpty,
          reason: 'the drag out waits for the finger to move');
    });
  });

  group('a message dropped back on the app', () {
    testWidgets('onto a folder is moved there', (tester) async {
      final c = await pump(tester);
      final m = first(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final target = tester
          .widgetList<FolderTile>(find.byType(FolderTile))
          .firstWhere((t) =>
              t.row.folder.id != m.folderId &&
              t.row.folder.accountId == m.accountId &&
              t.row.folder.capabilities.canAcceptMessages);
      final at = tester.getCenter(find.byWidget(target));

      bridge.drop(
        const [],
        label: messageDragLabel,
        text: m.id,
        at: at,
      );
      await tester.pumpAndSettle();

      final list = c.read(messagesProvider(folder)).value!;
      expect(list.any((x) => x.id == m.id), isFalse, reason: 'moved out');
      expect(find.textContaining('moved to'), findsOneWidget);
    });

    testWidgets('onto a folder that takes no mail is refused', (tester) async {
      // Another window's drag arrives this way, and so does one within this
      // window in split screen. The tree's own drop target refuses Gmail's
      // Sent Mail and the All Inboxes row; the same drop through the system
      // filed received mail under Sent, and failed outright on All Inboxes.
      final c = await pump(tester);
      final m = first(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;

      await dropOn(
        tester,
        m,
        folderAt(tester, (f) =>
            f.accountId == m.accountId && f.role == FolderRole.sent),
      );
      await dropOn(
        tester,
        m,
        folderAt(tester, (f) => f.role == FolderRole.unifiedInbox),
      );

      final list = c.read(messagesProvider(folder)).value!;
      expect(list.any((x) => x.id == m.id), isTrue, reason: 'left where it is');
      expect(find.textContaining('moved to'), findsNothing);
      expect(find.textContaining('Could not move'), findsNothing);
    });

    testWidgets('onto the folder it is already in does not say it moved',
        (tester) async {
      await pump(tester);
      final m = first(tester);

      await dropOn(tester, m, folderAt(tester, (f) => f.id == m.folderId));

      expect(find.textContaining('moved to'), findsNothing);
    });

    testWidgets('onto a folder can be undone', (tester) async {
      final c = await pump(tester);
      final m = first(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;

      await dropOn(
        tester,
        m,
        folderAt(tester, (f) =>
            f.accountId == m.accountId &&
            f.id != m.folderId &&
            f.role == FolderRole.user),
      );
      expect(find.textContaining('moved to'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pumpAndSettle();

      final list = c.read(messagesProvider(folder)).value!;
      expect(list.any((x) => x.subject == m.subject), isTrue,
          reason: 'put back');
      expect(find.text('Message put back'), findsOneWidget);
    });

    testWidgets('that moved is not reported as failed when a mailbox '
        'cannot be listed afterwards', (tester) async {
      // An expired sign-in on one of the five accounts failed its folder
      // listing, and every account was listed before anything was said.
      final engine = _ListingFails();
      final c = await pump(tester, engine: engine);
      final m = first(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final at = folderAt(tester, (f) =>
          f.accountId == m.accountId &&
          f.id != m.folderId &&
          f.role == FolderRole.user);
      engine.failing = true;

      await dropOn(tester, m, at);

      final list = c.read(messagesProvider(folder)).value!;
      expect(list.any((x) => x.id == m.id), isFalse, reason: 'moved out');
      expect(find.textContaining('moved to'), findsOneWidget);
      expect(find.textContaining('Could not move'), findsNothing);
    });

    testWidgets('from another window, though in no list here, can be undone',
        (tester) async {
      final engine = _ListingFails();
      final c = await pump(tester, engine: engine);
      final m = first(tester);
      final folders = c.read(folderIndexProvider).values.where((f) =>
          f.accountId == m.accountId &&
          f.role == FolderRole.user &&
          f.parentId == null);
      final from = folders.first;
      final to = folders.last;
      // Another window's list: the folder is not open here.
      final theirs = (await tester.runAsync(() => engine.loadMessages(from.id)))!
          .first;
      final at = folderAt(tester, (f) => f.id == to.id);
      engine.failing = true;

      await dropOn(tester, theirs, at);

      expect(find.textContaining('moved to'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
      expect(find.textContaining('Could not move'), findsNothing);
    });

    testWidgets('from another window, half moved, shows here what went',
        (tester) async {
      // The connection lost part way: the open list went on without the
      // message that had come into it, until the next refresh.
      final engine = _StopsAfterOne();
      final c = await pump(tester, engine: engine);
      final open = c.read(effectiveSelectedFolderIdProvider)!;
      final to = first(tester).folderId;
      final from = c.read(folderIndexProvider).values.firstWhere((f) =>
          f.accountId == first(tester).accountId &&
          f.role == FolderRole.user);
      final theirs = (await tester.runAsync(() => engine.loadMessages(from.id)))!
          .take(2)
          .toList();

      bridge.drop(
        const [],
        label: messageDragLabel,
        text: theirs.map((m) => m.id).join('\n'),
        at: folderAt(tester, (f) => f.id == to),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Moved 1 of 2'), findsOneWidget);
      final list = c.read(messagesProvider(open)).value!;
      expect(
        list.any((x) =>
            x.subject == theirs.first.subject && x.date == theirs.first.date),
        isTrue,
        reason: 'the one that went',
      );
    });

    testWidgets('anywhere else, with nothing being written, is left alone',
        (tester) async {
      await pump(tester);
      final m = first(tester);

      bridge.drop(
        [IncomingFile(path: '/x.eml', name: 'x.eml', mimeType: emlMimeType, sizeBytes: 1)],
        label: messageDragLabel,
        text: m.id,
        at: const Offset(900, 500),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsNothing,
          reason: 'a file from outside would start a message; our own does not');
    });
  });
}

/// Moves the first of a batch and then loses the connection, as a server
/// that drops part way does.
class _StopsAfterOne extends SampleMailEngine {
  @override
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  ) async {
    if (messageIds.length < 2) {
      return super.moveMessages(messageIds, toFolderId);
    }
    final done = await super.moveMessages([messageIds.first], toFolderId);
    throw PartialMove(
      done: done,
      moved: [messageIds.first],
      cause: StateError('connection lost'),
    );
  }
}

/// Answers everything but a folder listing once [failing] is set, the way a
/// mailbox whose sign-in has expired does.
class _ListingFails extends SampleMailEngine {
  bool failing = false;

  @override
  Future<List<MailFolder>> loadFolders(String accountId) {
    if (failing) throw StateError('signed out');
    return super.loadFolders(accountId);
  }
}
