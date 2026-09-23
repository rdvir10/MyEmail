import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// Which account a message goes out from, chosen from the header.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Draft draft(String accountId, {List<MailAddress> to = const []}) => Draft(
        accountId: accountId,
        kind: ComposeKind.reply,
        to: to,
        cc: const [],
        bcc: const [],
        subject: 'Re: numbers',
        htmlBody: '<p></p>',
        attachments: const [],
      );

  Future<ProviderContainer> open(
    WidgetTester tester,
    SampleMailEngine engine,
    String accountId, {
    List<MailAddress> to = const [],
  }) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [mailEngineProvider.overrideWithValue(engine)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: ComposeScreen(draft: draft(accountId, to: to))),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  final picker = find.byKey(const ValueKey('from-account'));

  testWidgets('with more than one account, From is a choice', (tester) async {
    final engine = SampleMailEngine();
    final accounts = (await tester.runAsync(engine.loadAccounts))!;
    await open(tester, engine, accounts.first.id);

    expect(picker, findsOneWidget);
    expect(find.text(accounts.first.emailAddress), findsOneWidget,
        reason: 'the account the reply arrived at, to begin with');
  });

  testWidgets('choosing another account sends from it', (tester) async {
    // Sent, not only shown: the picker could say one account while the
    // message went from the one the original arrived at.
    final engine = _Recording();
    final accounts = (await tester.runAsync(engine.loadAccounts))!;
    await open(
      tester,
      engine,
      accounts.first.id,
      to: const [MailAddress(email: 'dana@example.com')],
    );

    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(accounts[1].emailAddress).last);
    await tester.pumpAndSettle();

    final chosen = tester.widget<DropdownButton<String>>(picker).value;
    expect(chosen, accounts[1].id);

    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(engine.sent.single.accountId, accounts[1].id);
  });

  testWidgets('with one account there is nothing to choose', (tester) async {
    // A menu with one entry is a puzzle, so the sender is just stated.
    final engine = SampleMailEngine();
    final accounts = (await tester.runAsync(() async {
      final all = await engine.loadAccounts();
      for (final a in all.skip(1)) {
        await engine.removeAccount(a.id);
      }
      return all;
    }))!;
    await open(tester, engine, accounts.first.id);

    expect(picker, findsNothing);
    expect(find.textContaining('From ${accounts.first.emailAddress}'),
        findsOneWidget);
  });
}

/// The sample engine, keeping what it was asked to send.
class _Recording extends SampleMailEngine {
  final sent = <Draft>[];

  @override
  Future<void> sendDraft(Draft draft) async => sent.add(draft);
}
