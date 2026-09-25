import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/attachment_files.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/attachment_bar.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Under a message's subject: Move beside Delete, and the files, which fold
/// away and leave out the pictures the body already shows.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('Move', () {
    Future<void> openFirstMessage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
    }

    testWidgets('is beside Delete, and asks where to', (tester) async {
      await openFirstMessage(tester);

      final move = find.byTooltip('Move to folder');
      expect(move, findsOneWidget);
      expect(
        tester.getCenter(move).dx,
        lessThan(tester.getCenter(find.byTooltip('Delete')).dx),
      );

      await tester.tap(move);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('put away without a choice, the message stays open',
        (tester) async {
      await openFirstMessage(tester);
      await tester.tap(find.byTooltip('Move to folder'));
      await tester.pumpAndSettle();

      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(MessageScreen), findsOneWidget);
    });
  });

  group('the files under a message', () {
    const id = 'a:INBOX#7';
    const logo = MailAttachment(
      id: 'a-1',
      name: 'image.png',
      mimeType: 'image/png',
      sizeBytes: 2000,
      contentId: 'ii_logo0',
    );
    const resume = MailAttachment(
      id: 'a-2',
      name: 'Kevin Resume.docx',
      mimeType: 'application/octet-stream',
      sizeBytes: 42000,
    );

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required Future<Map<String, String>> Function() pictures,
      MemoryUiStateStore? store,
    }) async {
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(store ?? MemoryUiStateStore()),
        fileBridgeProvider.overrideWithValue(FakeFileBridge()),
        attachmentFilesProvider.overrideWithValue(MemoryAttachmentFiles()),
        attachmentsProvider(id).overrideWith((ref) async => [logo, resume]),
        messageBodyProvider(id).overrideWith(
          (ref) async => const MailBody(
            text: 'Hey Ron',
            html: '<p>Hey Ron</p><img src="cid:ii_logo0">',
          ),
        ),
        inlinePicturesProvider(id).overrideWith((ref) => pictures()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              // Shown the way the reading pane shows it: the body is asked
              // for before the bar is built.
              body: Consumer(
                builder: (context, ref, _) {
                  ref.watch(messageBodyProvider(id));
                  return const AttachmentBar(messageId: id);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('a picture the body shows gets no chip', (tester) async {
      // A signature's logo and icons were three "image.png" chips above the
      // one file that mattered.
      await pump(
        tester,
        pictures: () async => {'ii_logo0': 'data:image/png;base64,AAAA'},
      );

      expect(find.text('Kevin Resume.docx'), findsOneWidget);
      expect(find.text('image.png'), findsNothing);
      expect(find.textContaining('1 attachment'), findsOneWidget);
    });

    testWidgets('a picture that could not be fetched keeps its chip',
        (tester) async {
      await pump(tester, pictures: () async => const {});

      expect(find.text('image.png'), findsOneWidget);
      expect(find.textContaining('2 attachments'), findsOneWidget);
    });

    testWidgets('they fold away to their count, and it is remembered',
        (tester) async {
      final store = MemoryUiStateStore();
      await pump(tester, pictures: () async => const {}, store: store);

      await tester.tap(find.textContaining('2 attachments'));
      await tester.pumpAndSettle();
      expect(find.text('Kevin Resume.docx'), findsNothing);
      expect(find.textContaining('2 attachments'), findsOneWidget,
          reason: 'the count still says they are there');
      expect(store.readString(UiStateKeys.attachmentsFolded), 'folded');

      // The next message opens folded too.
      await pump(tester, pictures: () async => const {}, store: store);
      expect(find.text('Kevin Resume.docx'), findsNothing);

      await tester.tap(find.textContaining('2 attachments'));
      await tester.pumpAndSettle();
      expect(find.text('Kevin Resume.docx'), findsOneWidget);
    });
  });
}
