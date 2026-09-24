import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/common/problem_view.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// What compose does when a message cannot go, or cannot be kept. Only the
/// way that works had a test, so a change that closed the window on a
/// failure, and lost what was written in it, would have gone unnoticed.
void main() {
  late FakeWebViewPlatform page;
  setUp(() => page = FakeWebViewPlatform.install());

  const dana = MailAddress(email: 'dana@example.com');

  Draft draft({
    List<MailAddress> to = const [],
    List<MailAddress> cc = const [],
    List<MailAddress> bcc = const [],
  }) =>
      Draft(
        accountId: 'acct-personal',
        kind: ComposeKind.newMessage,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: 'Numbers',
        htmlBody: '<p>The figures for Thursday.</p>',
      );

  /// Compose pushed onto a route, so there is somewhere to go back to.
  Future<void> open(WidgetTester tester, Draft draft, _Engine engine) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mailEngineProvider.overrideWithValue(engine)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => ComposeScreen(draft: draft),
                    ),
                  ),
                  child: const Text('open compose'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open compose'));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  testWidgets('with nobody to send to it says so and sends nothing',
      (tester) async {
    final engine = _Engine();
    await open(tester, draft(), engine);

    await send(tester);

    expect(find.text('Add at least one recipient.'), findsOneWidget);
    expect(engine.sent, isEmpty);
    expect(find.byType(ComposeScreen), findsOneWidget);
  });

  testWidgets('a Cc that is not an address stops it', (tester) async {
    final engine = _Engine();
    await open(
      tester,
      draft(to: [dana], cc: [const MailAddress(email: 'not an address')]),
      engine,
    );

    await send(tester);

    expect(find.text('One of the addresses does not look right.'),
        findsOneWidget);
    expect(engine.sent, isEmpty);
  });

  testWidgets('a Bcc that is not an address stops it too', (tester) async {
    // The one nobody else on the message would notice missing.
    final engine = _Engine();
    await open(
      tester,
      draft(to: [dana], bcc: [const MailAddress(email: 'nobody@')]),
      engine,
    );

    await send(tester);

    expect(find.text('One of the addresses does not look right.'),
        findsOneWidget);
    expect(engine.sent, isEmpty);
  });

  testWidgets('a message to Bcc alone is sent', (tester) async {
    // The engines accept it; the screen refused it.
    final engine = _Engine();
    await open(tester, draft(bcc: [dana]), engine);

    await send(tester);

    expect(engine.sent.single.bcc, [dana]);
    expect(find.byType(ComposeScreen), findsNothing);
  });

  testWidgets('a send that fails keeps the window and what is in it',
      (tester) async {
    final engine = _Engine()..refuseSend = true;
    await open(tester, draft(to: [dana]), engine);

    await send(tester);

    expect(find.byType(ComposeScreen), findsOneWidget);
    expect(find.byType(ProblemView), findsOneWidget);
    expect(find.textContaining('The server said no.'), findsWidgets);
    expect(find.text('Message sent'), findsNothing);
    expect(find.textContaining('dana@example.com'), findsWidgets);
    expect(find.text('Numbers'), findsOneWidget);
  });

  // What is typed lives in the editor's page. The fake page never finished
  // loading, so every test sent what the window opened with, and the read
  // that really happens on a phone went untested.
  group('what the editor holds', () {
    setUp(() => page.finishLoads = true);

    testWidgets('what was typed on the page is what is sent',
        (tester) async {
      page.answer = (script) => script.contains('mailtreeGetHtml')
          ? jsonEncode('<p>Typed on the page.</p>')
          : '';
      final engine = _Engine();
      await open(tester, draft(to: [dana]), engine);

      await send(tester);

      expect(engine.sent.single.htmlBody, '<p>Typed on the page.</p>');
    });

    testWidgets('a page that answers null sends nothing', (tester) async {
      // Its script failed. Sent as it stood, the message read "null".
      page.answer = (_) => 'null';
      final engine = _Engine();
      await open(tester, draft(to: [dana]), engine);

      await send(tester);

      expect(engine.sent, isEmpty);
      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.byType(ProblemView), findsOneWidget);
    });

    testWidgets('Ctrl+Enter pressed in the page sends', (tester) async {
      page.answer = (script) => script.contains('mailtreeGetHtml')
          ? jsonEncode('<p>Sent from the keyboard.</p>')
          : '';
      final engine = _Engine();
      await open(tester, draft(to: [dana]), engine);

      page.sendFromPage('MyEmail', '{"type":"key","value":"send"}');
      await tester.pumpAndSettle();

      expect(engine.sent.single.htmlBody, '<p>Sent from the keyboard.</p>');
    });

    testWidgets('an unreadable page still lets the window be left',
        (tester) async {
      // It cannot be judged unchanged, so it asks; Discard is the way out.
      page.answer = (_) => 'null';
      await open(tester, draft(to: [dana]), _Engine());

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsNothing);
    });
  });

  testWidgets('a draft that cannot be saved keeps the window open',
      (tester) async {
    // Closing now would lose the message that could not be kept, which is
    // the very thing saving it was for.
    final engine = _Engine()..refuseSave = true;
    await open(tester, draft(to: [dana]), engine);

    // Written in, or leaving would not ask.
    await tester.enterText(
      find.widgetWithText(TextField, 'Numbers'),
      'Numbers for Thursday',
    );
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();

    expect(find.byType(ComposeScreen), findsOneWidget);
    expect(find.byType(ProblemView), findsOneWidget);
    expect(find.text('Saved to Drafts'), findsNothing);
    expect(find.text('Numbers for Thursday'), findsOneWidget);
  });
}

/// The sample engine, recording what it sends and refusing on request.
class _Engine extends SampleMailEngine {
  bool refuseSend = false;
  bool refuseSave = false;
  final sent = <Draft>[];

  @override
  Future<void> sendDraft(Draft draft) async {
    if (refuseSend) throw const SendFailed('The server said no.');
    sent.add(draft);
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    if (refuseSave) throw const SendFailed('The server said no.');
    return super.saveDraft(draft);
  }
}
