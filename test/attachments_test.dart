import 'package:flutter/material.dart';
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

  setUp(() {
    bridge = FakeFileBridge();
    files = MemoryAttachmentFiles();
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
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          fileBridgeProvider.overrideWithValue(bridge),
          attachmentFilesProvider.overrideWithValue(files),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<(ProviderContainer, String)> messageWithFiles() async {
      final c = container();
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
    Future<ProviderContainer> pumpBar(WidgetTester tester) async {
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          fileBridgeProvider.overrideWithValue(bridge),
          attachmentFilesProvider.overrideWithValue(files),
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
  });
}
