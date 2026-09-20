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

  /// The text field on the same row as this name.
  ///
  /// The name is the one in the fixed-width box to the left of the field,
  /// not the "Bcc" on the button at the end of the Cc row, which is the
  /// same word in a different place.
  Finder field(String label) {
    final name = find.descendant(
      of: find.byWidgetPredicate((w) => w is SizedBox && w.width == 64),
      matching: find.text(label),
    );
    return find.descendant(
      of: find.ancestor(of: name, matching: find.byType(Row)),
      matching: find.byType(TextField),
    );
  }

  group('what is asked for', () {
    testWidgets('To, Cc and Subject are there from the start', (tester) async {
      // Cc used to hide behind a button. Anyone who copies someone in on
      // most messages was pressing it every time.
      await open(tester, draft());

      expect(field('To'), findsOneWidget);
      expect(field('Cc'), findsOneWidget);
      expect(field('Subject'), findsOneWidget);
    });

    testWidgets('each is a light rule beside a muted name, in body type',
        (tester) async {
      // Not a bare word, which said nothing, and not an outlined box, which
      // shouted over the message: a rule under the field, like the body.
      await open(tester, draft());

      final to = tester.widget<TextField>(field('To'));
      expect(to.decoration?.border, isA<UnderlineInputBorder>());
      expect(to.decoration?.filled, isFalse);
      expect(find.text('To'), findsOneWidget, reason: 'the name, to the left');
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
