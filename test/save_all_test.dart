import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/attachment_bar.dart';
import 'package:myemail/ui/messages/save_all.dart';

/// Save All Attachments: every file on a message into one folder, chosen
/// once.
void main() {
  test('what it says when done', () {
    expect(saveAllOutcome(3, const []), 'Saved all 3 files.');
    expect(saveAllOutcome(1, const []), 'Saved the file.');
    expect(saveAllOutcome(3, const ['b.pdf']),
        'Saved 2 of 3. Not saved: b.pdf.');
    expect(saveAllOutcome(2, const ['a', 'b']), 'Could not save the files.');
  });

  Future<FakeFileBridge> pump(
    WidgetTester tester, {
    List<MailAttachment> files = _two,
  }) async {
    final bridge = FakeFileBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          mailEngineProvider.overrideWithValue(_Files(files)),
          fileBridgeProvider.overrideWithValue(bridge),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AttachmentBar(messageId: 'a:INBOX#1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return bridge;
  }

  testWidgets('puts every file in the folder chosen', (tester) async {
    final bridge = await pump(tester);
    bridge.folderToPick = 'content://tree/Downloads';
    await tester.tap(find.byKey(const ValueKey('save-all-attachments')));
    await tester.pumpAndSettle();
    expect(
      bridge.savedIntoFolder.map((s) => (s.folder, s.name)),
      [
        ('content://tree/Downloads', 'Plan.pdf'),
        ('content://tree/Downloads', 'Site.jpg'),
      ],
    );
    expect(find.text('Saved all 2 files.'), findsOneWidget);
  });

  testWidgets('a picker closed saves nothing and says nothing',
      (tester) async {
    final bridge = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('save-all-attachments')));
    await tester.pumpAndSettle();
    expect(bridge.savedIntoFolder, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('one the folder refuses is named, the rest still saved',
      (tester) async {
    final bridge = await pump(tester);
    bridge
      ..folderToPick = 'content://tree/x'
      ..refuseNames.add('Plan.pdf');
    await tester.tap(find.byKey(const ValueKey('save-all-attachments')));
    await tester.pumpAndSettle();
    expect(bridge.savedIntoFolder.map((s) => s.name), ['Site.jpg']);
    expect(find.text('Saved 1 of 2. Not saved: Plan.pdf.'), findsOneWidget);
  });

  testWidgets('one file has its own Save as, and no Save all', (tester) async {
    await pump(tester, files: [_two.first]);
    expect(find.byKey(const ValueKey('save-all-attachments')), findsNothing);
  });
}

const _two = [
  MailAttachment(
    id: '2',
    name: 'Plan.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 1000,
  ),
  MailAttachment(
    id: '3',
    name: 'Site.jpg',
    mimeType: 'image/jpeg',
    sizeBytes: 2000,
  ),
];

class _Files extends SampleMailEngine {
  _Files(this.files);

  final List<MailAttachment> files;

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async => files;
}
