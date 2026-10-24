import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/signature_images.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart' show ComposeKind;
import 'package:myemail/domain/signature.dart';
import 'package:myemail/state/compose_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/signature_editor_screen.dart';
import 'package:myemail/ui/settings/signatures_screen.dart';

import 'fakes/fake_webview.dart';

/// A signature written in the real editor, pictures and all.
void main() {
  group('hosted pictures', () {
    Future<FetchedImage?> fetch(Uri uri) async => uri.host == 'ok.example.com'
        ? FetchedImage(Uint8List.fromList([1, 2, 3]), 'image/png')
        : null;

    test('are brought inside the signature as data', () async {
      const html = '<p>Ron</p><img src="https://ok.example.com/logo.png" width=80>';

      final out = await inlineRemoteImages(html, fetch: fetch);

      expect(out, contains('src="data:image/png;base64,${base64Encode([1, 2, 3])}"'));
      expect(out, contains('width=80'), reason: 'the rest of the tag is kept');
      expect(out, isNot(contains('ok.example.com')));
    });

    test('one that cannot be fetched is left as the link it was', () async {
      const html = '<img src="https://down.example.com/x.png">';
      expect(await inlineRemoteImages(html, fetch: fetch), html);
    });

    test('data and cid pictures are not touched', () async {
      const html = '<img src="data:image/gif;base64,R0lG"><img src="cid:logo">';
      var calls = 0;
      await inlineRemoteImages(html, fetch: (_) async {
        calls++;
        return null;
      });
      expect(calls, 0);
    });
  });

  group('the screen', () {
    late FakeWebViewPlatform platform;
    setUp(() => platform = FakeWebViewPlatform.install());

    Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: MaterialApp(home: home)),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Signatures lists each account with what it has and an Edit',
        (tester) async {
      final c = await pump(tester, const SignaturesScreen());
      final accounts = await c.read(accountsProvider.future);
      c.read(signaturesProvider.notifier).set(Signature.single(accountId: accounts.first.id,
            html: '<p>Ron Dvir<br><b>Sales &amp; Marketing</b></p>',
          ));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Edit'), findsOneWidget,
          reason: 'one for the signature there is');
      expect(find.textContaining('Sales & Marketing'), findsOneWidget,
          reason: 'shown as words, not as HTML');
      expect(find.text('Nothing yet'), findsOneWidget);
      expect(find.text('Add a signature'), findsOneWidget);
      expect(find.text('Add another signature'), findsOneWidget);
      expect(find.text('New messages'), findsOneWidget);
      expect(find.text('Replies and forwards'), findsOneWidget);
    });

    testWidgets('Edit opens the editor holding the saved signature',
        (tester) async {
      final c = await pump(tester, const SignaturesScreen());
      final accounts = await c.read(accountsProvider.future);
      c.read(signaturesProvider.notifier).set(Signature.single(accountId: accounts.first.id,
            html: '<p>Ron Dvir</p>',
          ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit').first);
      await tester.pumpAndSettle();

      expect(find.byType(SignatureEditorScreen), findsOneWidget);
      expect(platform.loadedHtml.last, contains('<p>Ron Dvir</p>'));
      expect(find.byTooltip('Bold'), findsOneWidget);
    });

    testWidgets('Save writes it back, through the picture step',
        (tester) async {
      var inlined = 0;
      final c = await pump(tester, const SizedBox());
      // Nothing on screen is loading the accounts, so time has to pass
      // for real while they are read.
      final accounts =
          (await tester.runAsync(() => c.read(accountsProvider.future)))!;
      c.read(signaturesProvider.notifier).set(Signature.single(
            accountId: accounts.first.id,
            html: '<p>Before</p>',
          ));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: SignatureEditorScreen(
            account: accounts.first,
            signatureId: Signature.mainId,
            inlineImages: (html) async {
              inlined++;
              return '$html<!-- inlined -->';
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(inlined, 1);
      // The fake page never attaches, so the editor hands back what it was
      // given; a real page hands back what was typed.
      expect(c.read(signaturesProvider)[accounts.first.id]!.html,
          contains('<!-- inlined -->'));
    });

    testWidgets('a second signature, named, and chosen for replies',
        (tester) async {
      final c = await pump(tester, const SizedBox());
      const id = 'acct-personal';
      final notifier = c.read(signaturesProvider.notifier);
      notifier.set(Signature.single(accountId: id, html: '<p>Ron Dvir, Hadco</p>'));
      notifier.set(notifier.forAccount(id).withSignature(
            const NamedSignature(id: 'short', name: 'Short', html: '<p>Ron</p>'),
          ));
      notifier.set(notifier
          .forAccount(id)
          .withDefaults(forNew: Signature.mainId, forReplies: 'short'));

      final signature = c.read(signaturesProvider)[id]!;
      expect(signature.named.map((s) => s.name), ['Signature', 'Short']);
      expect(signature.htmlFor(ComposeKind.newMessage), '<p>Ron Dvir, Hadco</p>');
      expect(signature.htmlFor(ComposeKind.reply), '<p>Ron</p>');
      expect(signature.without('short').htmlFor(ComposeKind.reply), '',
          reason: 'gone, and no longer the replies one');
    });
  });
}
