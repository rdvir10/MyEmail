import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/attachment_files.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/attachment_bar.dart';

import 'fakes/fake_webview.dart';

/// What comes attached to a message, and what can be done with it.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late FakeFileBridge bridge;
  late MemoryAttachmentFiles files;

  // The cache directory, for the tests that use the real disk.
  late Directory temp;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    bridge = FakeFileBridge();
    files = MemoryAttachmentFiles();
    temp = Directory.systemTemp.createTempSync('myemail-attachments-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    temp.deleteSync(recursive: true);
  });

  group('names that have to touch a filesystem', () {
    test('a name with a path in it cannot climb out of its folder', () {
      // The name comes from whoever sent the message.
      expect(safeFileName('../../etc/passwd'), 'etc_passwd');
      expect(safeFileName(r'..\..\windows\system32'), 'windows_system32');
      expect(safeFileName('/etc/shadow'), 'etc_shadow');
    });

    test('a name that is nothing at all still gets one', () {
      expect(safeFileName(''), 'attachment');
      expect(safeFileName('   '), 'attachment');
      expect(safeFileName('...'), 'attachment');
    });

    test('a very long name is cut but keeps its extension', () {
      final cut = safeFileName('${'a' * 300}.pdf');

      expect(cut.length, lessThanOrEqualTo(120));
      expect(cut, endsWith('.pdf'));
    });

    test('characters Windows refuses are replaced, not dropped', () {
      expect(safeFileName('Q3: plan?.xlsx'), 'Q3_ plan_.xlsx');
    });

    test('a long name in Chinese or Thai still fits on the disk', () {
      // The disk counts bytes, 255 of them, and each of these is three. At
      // 120 characters the download could never be written.
      final cut = safeFileName('${'季度财务报告' * 30}.pdf');

      expect(utf8.encode(cut).length, lessThanOrEqualTo(200));
      expect(cut, endsWith('.pdf'));
      expect(cut, startsWith('季度财务报告'));
    });

    test('and is cut between characters, never through one', () {
      final cut = safeFileName('a${'😀' * 100}');

      // Half an emoji is a lone surrogate, which no filesystem takes.
      expect(cut.runes.where((r) => r >= 0xD800 && r <= 0xDFFF), isEmpty);
      expect(cut.runes.last, 0x1F600);
    });
  });

  group('the copy on disk', () {
    MailAttachment invoice({String id = '2', int size = 10}) => MailAttachment(
          id: id,
          name: 'invoice.pdf',
          mimeType: 'application/pdf',
          sizeBytes: size,
        );

    test('is not handed to a new message in the same place', () async {
      // `acct:INBOX#1` is a place, not a message: a recreated folder numbers
      // from 1 again, and so does a forgotten Microsoft folder.
      const disk = DiskAttachmentFiles();
      await disk.write(
          'a:INBOX#1', invoice(), Uint8List.fromList(utf8.encode('old')));

      expect(await disk.cached('a:INBOX#1', invoice()), isNotNull);
      expect(await disk.cached('a:INBOX#1', invoice(size: 11)), isNull,
          reason: 'IMAP: same part, another file');
      expect(await disk.cached('a:INBOX#1', invoice(id: 'AAMkAD=')), isNull,
          reason: 'Microsoft: another attachment id');
    });
  });

  group('sizes as a person reads them', () {
    test('bytes, kilobytes, megabytes', () {
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(2048), '2 KB');
      expect(formatFileSize(1572864), '1.5 MB');
      expect(formatFileSize(52428800), '50 MB');
    });
  });

  group('downloading', () {
    ProviderContainer container(AttachmentFiles on) {
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          fileBridgeProvider.overrideWithValue(bridge),
          attachmentFilesProvider.overrideWithValue(on),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<(ProviderContainer, String)> messageWithFiles({
      AttachmentFiles? on,
    }) async {
      final c = container(on ?? files);
      final engine = c.read(mailEngineProvider) as SampleMailEngine;
      final accounts = await engine.loadAccounts();
      final folders = await engine.loadFolders(accounts.first.id);
      for (final folder in folders) {
        final messages = await engine.loadMessages(folder.id);
        for (final m in messages) {
          if (m.hasAttachments) return (c, m.id);
        }
      }
      fail('the sample data has a message with an attachment');
    }

    test('a message says what is attached without fetching any of it',
        () async {
      final (c, messageId) = await messageWithFiles();

      final listed = await c.read(attachmentsProvider(messageId).future);

      expect(listed, isNotEmpty);
      expect(listed.first.name, isNotEmpty);
      expect(listed.first.sizeBytes, greaterThan(0));
      expect(files.written, isEmpty, reason: 'nothing downloaded yet');
    });

    test('asking for the file downloads it once', () async {
      final (c, messageId) = await messageWithFiles();
      final listed = await c.read(attachmentsProvider(messageId).future);
      final downloads = c.read(attachmentDownloadsProvider.notifier);

      await downloads.file(messageId, listed.first);
      await downloads.file(messageId, listed.first);

      expect(files.written, hasLength(1),
          reason: 'the second ask is answered from what was already fetched');
    });

    test('a copy Android has cleared away is fetched again', () async {
      // The cache is Android's to empty. A file remembered from earlier was
      // handed out anyway, and Save as failed on it without a word.
      final (c, messageId) =
          await messageWithFiles(on: const DiskAttachmentFiles());
      final listed = await c.read(attachmentsProvider(messageId).future);
      final downloads = c.read(attachmentDownloadsProvider.notifier);

      final first = await downloads.file(messageId, listed.first);
      first!.deleteSync();
      final again = await downloads.file(messageId, listed.first);

      expect(again!.existsSync(), isTrue);
      expect(again.lengthSync(), greaterThan(0));
    });

    test('a failure is remembered rather than thrown at the screen', () async {
      final (c, messageId) = await messageWithFiles();
      final downloads = c.read(attachmentDownloadsProvider.notifier);
      const missing = MailAttachment(
        id: 'nope',
        name: 'nothing.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 1,
      );

      final file = await downloads.file(messageId, missing);

      expect(file, isNull);
      expect(downloads.stateOf(messageId, missing).error, isNotNull);
    });
  });

  group('the bar on a message', () {
    Future<ProviderContainer> pumpBar(
      WidgetTester tester, {
      AttachmentFiles? on,
    }) async {
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          fileBridgeProvider.overrideWithValue(bridge),
          attachmentFilesProvider.overrideWithValue(on ?? files),
        ],
      );
      addTearDown(c.dispose);

      // runAsync, because the sample engine answers after a short delay and
      // a widget test's clock only moves when the test moves it: awaiting it
      // directly waits for ever.
      final withFiles = await tester.runAsync(() async {
        final engine = c.read(mailEngineProvider) as SampleMailEngine;
        final accounts = await engine.loadAccounts();
        for (final folder in await engine.loadFolders(accounts.first.id)) {
          for (final m in await engine.loadMessages(folder.id)) {
            if (m.hasAttachments) return m.id;
          }
        }
        return null;
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(body: AttachmentBar(messageId: withFiles!)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('lists each file with its size', (tester) async {
      await pumpBar(tester);

      expect(find.textContaining('.pdf'), findsOneWidget);
      expect(find.text('180 KB'), findsOneWidget);
    });

    testWidgets('a tap downloads it and hands it to another app',
        (tester) async {
      await pumpBar(tester);

      await tester.tap(find.textContaining('.pdf'));
      await tester.pumpAndSettle();

      expect(bridge.opened, hasLength(1));
    });

    testWidgets('a long press picks it up to drag somewhere else',
        (tester) async {
      // Which in split screen is how a file gets into the app next door.
      await pumpBar(tester);

      await tester.longPress(find.textContaining('.pdf'));
      await tester.pumpAndSettle();

      expect(bridge.dragged, hasLength(1));
    });

    testWidgets('the menu copies it to the clipboard', (tester) async {
      await pumpBar(tester);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(bridge.copied, hasLength(1));
    });

    testWidgets('and shares it', (tester) async {
      await pumpBar(tester);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share…'));
      await tester.pumpAndSettle();

      expect(bridge.shared, hasLength(1));
    });

    group('Save as', () {
      late _Picker picker;
      late FilePickerPlatform before;
      setUp(() {
        before = FilePickerPlatform.instance;
        FilePickerPlatform.instance = picker = _Picker();
      });
      tearDown(() => FilePickerPlatform.instance = before);

      /// Choose Save as from the chip's menu, on a real disk.
      Future<void> saveAs(WidgetTester tester) async {
        await pumpBar(tester, on: const DiskAttachmentFiles());
        await tester.tap(find.byIcon(Icons.more_vert).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save as…'));
        // In turns until it has said something: the sample server's delay
        // runs on the test's clock, and each step on the disk on the real
        // one, which a widget test's clock does not wait for.
        for (var i = 0;
            i < 250 && find.byType(SnackBar).evaluate().isEmpty;
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      testWidgets('puts the file where the person chose', (tester) async {
        await saveAs(tester);

        expect(picker.saved.single, endsWith('.pdf'));
        expect(find.text('Saved.'), findsOneWidget);
      });

      testWidgets('that fails says so', (tester) async {
        // A full disk, or a cloud folder that will not take the write. It
        // used to end with nothing on screen at all.
        picker.fails = true;

        await saveAs(tester);

        expect(find.text('Could not save the attachment.'), findsOneWidget);
      });
    });
  });
}

/// The system's save dialog, answered without one.
class _Picker extends FilePickerPlatform {
  bool fails = false;
  final List<String> saved = [];

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (fails) throw const FileSystemException('No space left on device');
    saved.add(fileName);
    return Uri.parse('content://documents/$fileName');
  }
}
