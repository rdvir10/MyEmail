import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/html_body_view.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Pictures a message puts in its own body: a screenshot pasted into an
/// Outlook message, the logo in a signature. They are named in the HTML by
/// Content-ID, and nothing put them there, so each was a broken image with
/// the picture only reachable as a chip under the message.
void main() {
  test('the pictures a message names are fetched as data: URIs', () async {
    final engine = _WithPictures();
    final c = ProviderContainer(
      overrides: [mailEngineProvider.overrideWithValue(engine)],
    );
    addTearDown(c.dispose);

    final pictures = await c.read(inlinePicturesProvider('m1').future);

    expect(pictures, {
      'logo@x': 'data:image/png;base64,${base64Encode(_logo)}',
    });
    expect(engine.fetched, ['p1'],
        reason: 'an ordinary file is not downloaded to show the body');
  });

  testWidgets('pictures arriving keep the images the reader asked for',
      (tester) async {
    // They come after the body, so the page loads again; taken for a new
    // message, it hid the remote images the reader had just asked to see.
    final platform = FakeWebViewPlatform.install();
    Widget view(Map<String, String> pictures) => MaterialApp(
          home: Scaffold(
            body: HtmlBodyView(
              html: '<img src="https://x.example/a.png">'
                  '<img src="cid:logo@x">',
              inlinePictures: pictures,
            ),
          ),
        );
    await tester.pumpWidget(view(const {}));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show images'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(view(const {'logo@x': 'data:image/png;base64,AA'}));
    await tester.pumpAndSettle();

    final page = platform.loadedHtml.last;
    expect(page, contains('src="data:image/png;base64,AA"'));
    expect(page, contains('<img src="https://x.example/a.png">'));
    expect(page, isNot(contains('data-blocked-src="https')));
  });

  testWidgets('the reading pane puts them in the body', (tester) async {
    FakeWebViewPlatform.install();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(_WithPictures()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();

    final view = tester.widget<HtmlBodyView>(find.byType(HtmlBodyView));
    expect(view.inlinePictures.keys, ['logo@x']);
  });
}

final _logo = Uint8List.fromList([137, 80, 78, 71]);

/// The sample engine, with a logo named by Content-ID in every body.
class _WithPictures extends SampleMailEngine {
  final fetched = <String>[];

  @override
  Future<MailBody> loadMessageBody(String messageId) async => const MailBody(
        text: 'Hi',
        html: '<p>Hi</p><img src="cid:logo@x">',
      );

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async => [
        const MailAttachment(
          id: 'p1',
          name: 'logo.png',
          mimeType: 'image/png',
          sizeBytes: 4,
          isInline: true,
          contentId: 'Logo@X',
        ),
        const MailAttachment(
          id: 'f1',
          name: 'report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 5,
        ),
      ];

  @override
  Future<Uint8List> fetchAttachment(String messageId, String id) async {
    fetched.add(id);
    return _logo;
  }
}
