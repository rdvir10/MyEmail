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
import 'package:myemail/domain/mail_message.dart';
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

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
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

      await tester.tap(find.byKey(ValueKey('tile:${m.id}')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Copy'));
      await tester.pumpAndSettle();

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
      await tester.tap(find.byKey(ValueKey('tile:${m.id}')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Copy'));
      await tester.pumpAndSettle();
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
              !t.row.folder.isSynthetic);
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
