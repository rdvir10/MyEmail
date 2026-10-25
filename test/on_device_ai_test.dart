import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ai/on_device_ai.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/ai_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/ai_writing.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/ai_message_bars.dart';

import 'fakes/fake_webview.dart';

/// The phone's own AI (#56–#58): a summary, proofread and rewrite, and
/// suggested replies, against a fake of it.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const english = 'Hi Ron, thanks for the samples you sent last week. We '
      'tested the aluminium sheets in the press shop and the finish held up '
      'well. Before we place the order we need three things: the lead time '
      'for 2,000 sheets, whether you can cut them to 1200 by 2400, and the '
      'price with delivery to Haifa. If the numbers work we would like the '
      'first delivery by the end of November, and a second one in January. '
      'Please also send the certificate for the alloy, as our customer asks '
      'for it with every batch. Let me know if a call on Tuesday suits you.';
  const hebrew = 'שלום רון, תודה על הדוגמאות ששלחת בשבוע שעבר. בדקנו את '
      'הפחים במחלקת הכבישה והגימור החזיק מעמד היטב. לפני שנזמין אנחנו צריכים '
      'שלושה דברים: זמן אספקה, חיתוך במידה, ומחיר כולל משלוח לחיפה.';

  const longEnglish = '$english $english';

  test('English is told from Hebrew, and a short line from neither', () {
    expect(readsAsEnglish(english), isTrue);
    expect(readsAsEnglish(hebrew), isFalse);
    expect(readsAsEnglish('$hebrew Thanks'), isFalse);
    expect(readsAsEnglish('Thanks!'), isFalse, reason: 'too few letters');
    expect(readsAsEnglish('Thanks!', minimum: 1), isTrue);
    expect(roughTokens('a' * 400), 100);
  });

  test("a message's own words, not the history quoted under them", () {
    const body = MailBody(text: 'Sounds good, see you then.\n\n'
        'On Thu, 22 Oct 2026 at 10:00, Dana Levi <dana@example.com> wrote:\n'
        '> Can we meet on Tuesday?\n');
    expect(ownWordsOf(body), 'Sounds good, see you then.');
    const outlook = MailBody(text: 'Done, attached.\n\n'
        'From: Dana Levi <dana@example.com>\nSent: Thursday\nThe old one');
    expect(ownWordsOf(outlook), 'Done, attached.');
    const quoted = MailBody(text: 'Yes.\n> no\n> maybe');
    expect(ownWordsOf(quoted), 'Yes.');
  });

  MailMessage message({String from = 'dana@example.com'}) => MailMessage(
        id: 'a:INBOX#1',
        accountId: 'acct-personal',
        folderId: 'acct-personal:INBOX',
        uid: 1,
        subject: 'Samples',
        from: MailAddress(email: from, name: 'Dana Levi'),
        to: const [],
        date: DateTime(2026, 10, 22, 10),
        preview: '',
        isRead: true,
      );

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child,
    FakeOnDeviceAi ai,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      onDeviceAiProvider.overrideWithValue(ai),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: Scaffold(body: child)),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  group('the summary', () {
    testWidgets('offered for a long English message, and made on a tap',
        (tester) async {
      final ai = FakeOnDeviceAi(summary: '• They want a quote.\n• By Tuesday.');
      await pump(
        tester,
        AiSummaryBar(message: message(), body: const MailBody(text: longEnglish)),
        ai,
      );
      await tester.tap(find.byKey(const ValueKey('ai-summarise')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('ai-summary')), findsOneWidget);
      expect(find.textContaining('They want a quote.'), findsOneWidget);
      expect(ai.asked.single.$2, longEnglish);
    });

    testWidgets('not for Hebrew, a short message, or a phone without it',
        (tester) async {
      Future<void> nothingFor(String text, FakeOnDeviceAi ai) async {
        await pump(
          tester,
          AiSummaryBar(message: message(), body: MailBody(text: text)),
          ai,
        );
        expect(find.byKey(const ValueKey('ai-summarise')), findsNothing);
      }

      await nothingFor(hebrew * 3, FakeOnDeviceAi());
      await nothingFor('Thanks, that works for me.', FakeOnDeviceAi());
      await nothingFor(
        longEnglish,
        FakeOnDeviceAi(ready: {AiFeature.summarize: AiReadiness.unavailable}),
      );
    });

    testWidgets('a model not yet on the phone is fetched first',
        (tester) async {
      final ai =
          FakeOnDeviceAi(ready: {AiFeature.summarize: AiReadiness.downloadable});
      await pump(
        tester,
        AiSummaryBar(message: message(), body: const MailBody(text: longEnglish)),
        ai,
      );
      await tester.tap(find.byKey(const ValueKey('ai-summarise')));
      await tester.pumpAndSettle();
      expect(ai.asked.first, ('download', 'summarize'));
      expect(find.byKey(const ValueKey('ai-summary')), findsOneWidget);
    });
  });

  group('suggested replies', () {
    testWidgets('a tap starts a reply with the words in', (tester) async {
      final ai = FakeOnDeviceAi(replies: ['Sounds good', 'Thanks!']);
      await pump(
        tester,
        SuggestedReplies(message: message(), body: const MailBody(text: english)),
        ai,
      );
      expect(find.text('Sounds good'), findsOneWidget);
      expect(find.text('Thanks!'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ai-reply:0')));
      await tester.pumpAndSettle();
      final compose = tester.widget<ComposeScreen>(find.byType(ComposeScreen));
      expect(compose.draft.kind, ComposeKind.reply);
      expect(compose.draft.htmlBody, contains('Sounds good'));
    });

    testWidgets('none for mail written from here', (tester) async {
      final ai = FakeOnDeviceAi(replies: ['Sounds good']);
      await pump(
        tester,
        SuggestedReplies(
          message: message(from: 'personal@example.com'),
          body: const MailBody(text: english),
        ),
        ai,
      );
      expect(find.text('Sounds good'), findsNothing, reason: 'it is mine');
    });

    testWidgets('none for Hebrew, and not even asked', (tester) async {
      final ai = FakeOnDeviceAi(replies: ['Sounds good']);
      await pump(
        tester,
        SuggestedReplies(message: message(), body: const MailBody(text: hebrew)),
        ai,
      );
      expect(find.text('Sounds good'), findsNothing);
      expect(ai.asked, isEmpty);
    });
  });

  group('proofread and rewrite', () {
    Widget host(
      FakeOnDeviceAi ai, {
      required String text,
      required List<String> written,
    }) =>
        Consumer(
          builder: (context, ref, _) => Center(
            child: AiWritingButton(
              enabled: true,
              read: () async => text,
              write: (t) async => written.add(t),
            ),
          ),
        );

    testWidgets('Proofread shows the corrected words, and Use this puts '
        'them in', (tester) async {
      final written = <String>[];
      final ai = FakeOnDeviceAi();
      await pump(
        tester,
        host(ai, text: 'Thanks for teh samples.', written: written),
        ai,
      );
      await tester.tap(find.byKey(const ValueKey('compose-ai')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('compose-ai:Proofread')));
      await tester.pumpAndSettle();

      expect(find.text('Thanks for the samples.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-use')));
      await tester.pumpAndSettle();
      expect(written, ['Thanks for the samples.']);
    });

    testWidgets('a rewrite in the style chosen', (tester) async {
      final written = <String>[];
      final ai = FakeOnDeviceAi();
      await pump(
        tester,
        host(ai, text: 'Send me the price by Tuesday.', written: written),
        ai,
      );
      await tester.tap(find.byKey(const ValueKey('compose-ai')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('compose-ai:More formal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-use')));
      await tester.pumpAndSettle();
      expect(written, ['More formal: Send me the price by Tuesday.']);
      expect(ai.asked.last.$1, RewriteStyle.formal.name);
    });

    testWidgets('nothing to correct says so, with nothing to use',
        (tester) async {
      final written = <String>[];
      final ai = FakeOnDeviceAi();
      await pump(
        tester,
        host(ai, text: 'All is well here.', written: written),
        ai,
      );
      await tester.tap(find.byKey(const ValueKey('compose-ai')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('compose-ai:Proofread')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing to correct.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-use')), findsNothing);
    });

    testWidgets('too long, in Hebrew, or nothing written: said, and not '
        'asked', (tester) async {
      Future<void> refused(String text, String says) async {
        final ai = FakeOnDeviceAi();
        await pump(tester, host(ai, text: text, written: []), ai);
        await tester.tap(find.byKey(const ValueKey('compose-ai')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('compose-ai:Shorter')));
        await tester.pumpAndSettle();
        expect(find.textContaining(says), findsOneWidget);
        expect(ai.asked, isEmpty);
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold)))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }

      await refused(english * 2, 'about 150 words');
      await refused(hebrew, 'English only');
      await refused('   ', 'Write something first');
    });

    testWidgets('not there on a phone without the AI', (tester) async {
      final ai = FakeOnDeviceAi(ready: {
        AiFeature.proofread: AiReadiness.unavailable,
        AiFeature.rewrite: AiReadiness.unavailable,
      });
      await pump(tester, host(ai, text: 'x', written: []), ai);
      expect(find.byKey(const ValueKey('compose-ai')), findsNothing);
    });
  });
}
