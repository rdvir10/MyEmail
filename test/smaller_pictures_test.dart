import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/draft_files.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/compose/smaller_pictures.dart';
import 'package:myemail/ui/messages/attached_message_screen.dart';

import 'fakes/fake_webview.dart';

/// Pictures coming into a message offered smaller, and a file on a message
/// being written opened to look at (3.7.2).
void main() {
  late _Shrinker shrinker;
  late MemoryDraftFiles files;
  late FakeFileBridge bridge;

  setUp(() {
    FakeWebViewPlatform.install();
    shrinker = _Shrinker();
    files = MemoryDraftFiles();
    bridge = FakeFileBridge();
  });

  DraftAttachment file(String name, String type, int kb) => DraftAttachment(
        fileName: name,
        mimeType: type,
        bytes: Uint8List(kb * 1024),
      );

  Future<void> open(
    WidgetTester tester,
    List<DraftAttachment> attachments, {
    bool offer = true,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        pictureShrinkerProvider.overrideWithValue(shrinker),
        draftFilesProvider.overrideWithValue(files),
        fileBridgeProvider.overrideWithValue(bridge),
      ],
      child: MaterialApp(
        home: ComposeScreen(
          draft: Draft(
            accountId: 'acct-personal',
            kind: ComposeKind.newMessage,
            htmlBody: '<p></p>',
            attachments: attachments,
          ),
          offerSmallerPictures: offer,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  List<String> attached(WidgetTester tester) => [
        for (final chip in tester.widgetList<InputChip>(find.byType(InputChip)))
          ((chip.label as Text).data)!,
      ];

  group('pictures coming in', () {
    testWidgets('over a megabyte in all are offered smaller, each size '
        'saying what they would weigh', (tester) async {
      await open(tester, [
        file('IMG_1.heic', 'image/heic', 800),
        file('IMG_2.jpg', 'image/jpeg', 800),
        file('report.pdf', 'application/pdf', 2000),
      ]);

      expect(find.text('Make the pictures smaller?'), findsOneWidget);
      expect(find.text('2 pictures, 1.6 MB'), findsOneWidget,
          reason: 'the PDF is not a picture');
      Finder weight(String size) => find.descendant(
          of: find.byKey(ValueKey('smaller-$size')), matching: find.byType(Text));
      expect(tester.widget<Text>(weight('small').last).data, '320 KB');
      expect(tester.widget<Text>(weight('medium').last).data, '512 KB');
      expect(tester.widget<Text>(weight('large').last).data, '768 KB');

      await tester.tap(find.byKey(const ValueKey('smaller-medium')));
      await tester.pumpAndSettle();

      expect(find.text('Make the pictures smaller?'), findsNothing);
      expect(attached(tester), [
        'IMG_1.jpg  256 KB',
        'IMG_2.jpg  256 KB',
        'report.pdf  2.0 MB',
      ]);
    });

    testWidgets('Actual size leaves them as they came', (tester) async {
      await open(tester, [file('IMG_1.jpg', 'image/jpeg', 1500)]);
      expect(find.text('Make the picture smaller?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('smaller-actual')));
      await tester.pumpAndSettle();

      expect(attached(tester), ['IMG_1.jpg  1.5 MB']);
    });

    testWidgets('under a megabyte in all, nothing is asked', (tester) async {
      await open(tester, [
        file('IMG_1.jpg', 'image/jpeg', 400),
        file('IMG_2.png', 'image/png', 400),
      ]);

      expect(find.byType(SmallerPicturesSheet), findsNothing);
      expect(shrinker.asked, isEmpty);
    });

    testWidgets('a draft opened again is not asked about', (tester) async {
      await open(tester, [file('IMG_1.jpg', 'image/jpeg', 3000)], offer: false);

      expect(find.byType(SmallerPicturesSheet), findsNothing);
    });

    testWidgets('a picture that would come out no smaller stays as it is',
        (tester) async {
      shrinker.grows = true;
      await open(tester, [file('IMG_1.jpg', 'image/jpeg', 1200)]);

      await tester.tap(find.byKey(const ValueKey('smaller-small')));
      await tester.pumpAndSettle();

      expect(attached(tester), ['IMG_1.jpg  1.2 MB']);
    });
  });

  group('a file on the message', () {
    testWidgets('opens with a tap, in whatever opens that sort of file',
        (tester) async {
      await open(tester, [file('report.pdf', 'application/pdf', 20)]);

      await tester.tap(find.byType(InputChip));
      await tester.pumpAndSettle();

      expect(bridge.opened, ['/memory/outgoing/report.pdf']);
      expect(files.written['/memory/outgoing/report.pdf'], hasLength(20 * 1024));
    });

    testWidgets('a message forwarded as a file opens here, as an email',
        (tester) async {
      final eml = DraftAttachment(
        fileName: 'quote.eml',
        mimeType: 'message/rfc822',
        bytes: Uint8List.fromList(utf8.encode(
          'From: Dana <dana@example.com>\r\n'
          'To: ron@example.com\r\n'
          'Subject: The quote\r\n'
          'Date: Mon, 26 Oct 2026 09:00:00 +0200\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          'Numbers attached.\r\n',
        )),
      );
      await open(tester, [eml]);

      await tester.tap(find.byType(InputChip));
      await tester.pumpAndSettle();

      expect(find.byType(AttachedMessageScreen), findsOneWidget);
      expect(bridge.opened, isEmpty);
    });
  });
}

/// Pictures "made smaller" by their size and nothing else: Small a fifth of
/// what they were, Medium a third, Large a half (as 800, 1280 and 1920 of
/// 4000 pixels), or larger than they were where [grows].
class _Shrinker implements PictureShrinker {
  final List<(String, int)> asked = [];
  bool grows = false;

  @override
  Future<DraftAttachment?> shrink(DraftAttachment picture, int longSide) async {
    asked.add((picture.fileName, longSide));
    final size = grows
        ? picture.size * 2
        : switch (longSide) {
            800 => picture.size * 2 ~/ 10,
            1280 => picture.size * 32 ~/ 100,
            _ => picture.size * 48 ~/ 100,
          };
    return DraftAttachment(
      fileName: jpegName(picture.fileName),
      mimeType: 'image/jpeg',
      bytes: Uint8List(size),
    );
  }
}
