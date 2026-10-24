import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/signature.dart';
import 'package:myemail/state/compose_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/compose/html_editor.dart';
import 'package:myemail/ui/compose/insert_picture.dart';

import 'fakes/fake_webview.dart';
import 'helpers/send_at_once.dart';

/// The editor of batch 4: more formatting, links, pictures in the text,
/// @mentions, and more than one signature.
void main() {
  late FakeWebViewPlatform page;
  setUp(() => page = FakeWebViewPlatform.install()..finishLoads = true);

  Future<ProviderContainer> open(
    WidgetTester tester, {
    SampleMailEngine? engine,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(engine ?? _People()),
        uiStateStoreProvider.overrideWithValue(sendAtOnce()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: ComposeScreen(
            draft: Draft(
              accountId: 'acct-personal',
              kind: ComposeKind.newMessage,
              subject: 'Plans',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  group('formatting', () {
    testWidgets('strikethrough, a colour, a highlight, a size', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Strikethrough'));
      await tester.tap(find.byTooltip('Font colour'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Red'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Highlight'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yellow'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byTooltip('Size'),
        find.byType(ListView).last,
        const Offset(-200, 0),
      );
      await tester.tap(find.byTooltip('Size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Large'));
      await tester.pumpAndSettle();

      expect(page.ranJavaScript, containsAll([
        'window.mailtreeFormat("strikeThrough", null);',
        'window.mailtreeFormat("foreColor", "#c50f1f");',
        'window.mailtreeFormat("hiliteColor", "#ffff00");',
        'window.mailtreeFormat("fontSize", "5");',
      ]));
    });

    testWidgets('a link, from an address typed without its https://',
        (tester) async {
      await open(tester);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('editor-link')),
        find.byType(ListView).last,
        const Offset(-300, 0),
      );
      await tester.tap(find.byKey(const ValueKey('editor-link')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('link-address')), 'hadco.com/specs');
      await tester.enterText(find.byKey(const ValueKey('link-text')), 'Specs');
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();

      expect(page.ranJavaScript,
          contains('window.mailtreeLink("https://hadco.com/specs", "Specs");'));
    });

    test('what a typed address becomes', () {
      expect(linkAddress('example.com'), 'https://example.com');
      expect(linkAddress('http://x.org/a'), 'http://x.org/a');
      expect(linkAddress('dana@example.com'), 'mailto:dana@example.com');
      expect(linkAddress('tel:+97231234567'), 'tel:+97231234567');
    });
  });

  testWidgets('a picture: from the pictures, or taken now', (tester) async {
    await open(tester);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('editor-picture')),
      find.byType(ListView).last,
      const Offset(-300, 0),
    );
    await tester.tap(find.byKey(const ValueKey('editor-picture')));
    await tester.pumpAndSettle();
    expect(find.text('From your pictures'), findsOneWidget);
    expect(find.text('Take a photo'), findsOneWidget);
    expect(
      pictureHtml('image/jpeg', 'AAAA'),
      '<img src="data:image/jpeg;base64,AAAA" alt="" '
      'style="max-width:100%;height:auto">',
    );
  });

  testWidgets('an @mention: suggested, put in, and added to To',
      (tester) async {
    await open(tester);
    page.sendFromPage('MyEmail', jsonEncode({'type': 'mention', 'value': 'da'}));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('mention:dana@example.com'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(page.ranJavaScript,
        contains('window.mailtreeMention("Dana Levi", "dana@example.com");'));
    expect(find.text('Dana Levi <dana@example.com>'), findsOneWidget,
        reason: 'on To now');
    expect(chip, findsNothing);
  });

  testWidgets('the Signature menu puts in another, or none', (tester) async {
    final c = await open(tester);
    final notifier = c.read(signaturesProvider.notifier);
    notifier.set(Signature.single(
      accountId: 'acct-personal',
      html: '<p>Ron Dvir, Hadco</p>',
    ));
    notifier.set(notifier.forAccount('acct-personal').withSignature(
          const NamedSignature(id: 'short', name: 'Short', html: '<p>Ron</p>'),
        ));
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('signature-menu')),
      find.byType(ListView).last,
      const Offset(-300, 0),
    );
    await tester.tap(find.byKey(const ValueKey('signature-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Short'));
    await tester.pumpAndSettle();
    expect(page.ranJavaScript.last, 'window.mailtreeSetSignature("<p>Ron</p>");');

    await tester.tap(find.byKey(const ValueKey('signature-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No signature'));
    await tester.pumpAndSettle();
    expect(page.ranJavaScript.last, 'window.mailtreeSetSignature("");');
  });

  group('signatures', () {
    test('one of the old shape becomes the account\'s first, for both', () {
      final old = Signature.fromJson(const {
        'accountId': 'a',
        'html': '<p>Ron</p>',
        'onReply': false,
      });
      expect(old.named.single.html, '<p>Ron</p>');
      expect(old.htmlFor(ComposeKind.newMessage), '<p>Ron</p>');
      expect(old.htmlFor(ComposeKind.reply), '', reason: 'not on replies');
    });

    test('several, kept as written', () {
      final two = Signature.single(accountId: 'a', html: '<p>Full</p>')
          .withSignature(
            const NamedSignature(id: 's', name: 'Short', html: '<p>R</p>'),
          )
          .withDefaults(forNew: Signature.mainId, forReplies: 's');
      final back = Signature.mapFromJson(jsonEncode([two.toJson()]))!['a']!;
      expect(back, two);
      expect(back.htmlFor(ComposeKind.forward), '<p>R</p>');
    });
  });
}

/// The sample engine, with someone in its mail history.
class _People extends SampleMailEngine {
  @override
  Future<List<AddressSuggestion>> recentAddresses() async => const [
        AddressSuggestion(
          email: 'dana@example.com',
          name: 'Dana Levi',
          timesSeen: 4,
          timesSent: 2,
        ),
      ];
}
