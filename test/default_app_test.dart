import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/attachment_files.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/attachment_bar.dart';

/// An attachment's menu: open it in an app chosen this once, and see which
/// app opens its kind by default, with the way to change that.
void main() {
  late FakeFileBridge bridge;

  Future<void> pumpBar(WidgetTester tester) async {
    bridge = FakeFileBridge();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mailEngineProvider.overrideWithValue(_OnePdf()),
        fileBridgeProvider.overrideWithValue(bridge),
        attachmentFilesProvider.overrideWithValue(MemoryAttachmentFiles()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: AttachmentBar(messageId: 'acct:INBOX#1')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  testWidgets('Open with… offers every app, for this once', (tester) async {
    await pumpBar(tester);

    await choose(tester, 'Open with…');

    expect(bridge.chosenFor, hasLength(1));
    expect(bridge.opened, isEmpty, reason: 'not the default app');
  });

  testWidgets('Default app… names it, and opens its settings to change it',
      (tester) async {
    await pumpBar(tester);
    bridge.defaultApp = const DefaultApp(
      packageName: 'com.google.android.apps.docs',
      label: 'Drive',
    );

    await choose(tester, 'Default app…');

    expect(find.textContaining('PDF files open in Drive.'), findsOneWidget);
    expect(find.textContaining('2. Tap Clear default preferences.'),
        findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(bridge.defaultsShown, ['com.google.android.apps.docs']);
  });

  testWidgets('with none set, it says Android asks, and offers to open',
      (tester) async {
    await pumpBar(tester);

    await choose(tester, 'Default app…');

    expect(find.textContaining('Nothing is set for PDF files'), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pumpAndSettle();
    expect(bridge.opened, hasLength(1));
  });

  testWidgets('the only app that can is said to be the only one',
      (tester) async {
    await pumpBar(tester);
    bridge.defaultApp =
        const DefaultApp(packageName: 'x.reader', label: 'Reader', only: true);

    await choose(tester, 'Default app…');

    expect(find.textContaining('Reader is the only app'), findsOneWidget);
    expect(find.text('Open settings'), findsNothing,
        reason: 'there is no default to clear');
  });

  test('what kind of file it is, as Android sorts them', () {
    expect(filesLike('Report.pdf'), 'PDF files');
    expect(filesLike('notes.docx'), 'DOCX files');
    expect(filesLike('Extrusion shape pictures'), 'files like this');
    expect(filesLike('.hidden'), 'files like this');
  });
}

class _OnePdf extends SampleMailEngine {
  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async => const [
        MailAttachment(
          id: 'a1',
          name: 'Report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 8,
        ),
      ];

  @override
  Future<Uint8List> fetchAttachment(String messageId, String id) async =>
      Uint8List.fromList('%PDF-1.4'.codeUnits);
}
