import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// The top of a new message: what is asked for, and where the cursor waits.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Draft draft({
    List<MailAddress> to = const [],
    List<MailAddress> bcc = const [],
    ComposeKind kind = ComposeKind.newMessage,
  }) =>
      Draft(
        accountId: 'acct-personal',
        kind: kind,
        to: to,
        cc: const [],
        bcc: bcc,
        subject: '',
        htmlBody: '<p></p>',
        attachments: const [],
      );

  Future<void> open(WidgetTester tester, Draft d) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mailEngineProvider.overrideWithValue(SampleMailEngine())],
        child: MaterialApp(home: ComposeScreen(draft: d)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The text field whose outline carries this name.
  Finder field(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(TextField),
      );

  group('what is asked for', () {
    testWidgets('To, Cc and Subject are there from the start', (tester) async {
      // Cc used to hide behind a button. Anyone who copies someone in on
      // most messages was pressing it every time.
      await open(tester, draft());

      expect(field('To'), findsOneWidget);
      expect(field('Cc'), findsOneWidget);
      expect(field('Subject'), findsOneWidget);
    });

    testWidgets('each is drawn as a box, not a bare line', (tester) async {
      // The old row was a word and an underline, indistinguishable from a
      // heading; nothing about it said "type here".
      await open(tester, draft());

      final to = tester.widget<TextField>(field('To'));
      expect(to.decoration?.border, isA<OutlineInputBorder>());
      expect(to.decoration?.labelText, 'To');
    });

    testWidgets('Bcc waits behind a button', (tester) async {
      await open(tester, draft());
      expect(field('Bcc'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Bcc'));
      await tester.pumpAndSettle();

      expect(field('Bcc'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Bcc'), findsNothing,
          reason: 'the button has done its job');
    });

    testWidgets('a draft that already has Bcc shows it', (tester) async {
      await open(
        tester,
        draft(bcc: const [MailAddress(email: 'quiet@example.com')]),
      );

      expect(field('Bcc'), findsOneWidget);
      expect(find.text('quiet@example.com'), findsOneWidget);
    });
  });

  group('where the cursor waits', () {
    testWidgets('in To, for a new message', (tester) async {
      await open(tester, draft());

      final to = tester.widget<TextField>(field('To'));
      expect(to.autofocus, isTrue);
    });

    testWidgets('not in To, for a reply that already has one', (tester) async {
      // The recipient is filled in; the cursor belongs in the body.
      await open(
        tester,
        draft(
          kind: ComposeKind.reply,
          to: const [MailAddress(email: 'them@example.com')],
        ),
      );

      final to = tester.widget<TextField>(field('To'));
      expect(to.autofocus, isFalse);
    });
  });
}
