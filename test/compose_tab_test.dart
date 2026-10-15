import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// Tab, while writing: from one place a message is written in to the next,
/// and nowhere else. Ron found it stopping on every button (2.87.1).
void main() {
  late FakeWebViewPlatform web;

  setUp(() {
    // Pages finish, so the editor attaches and can be given the cursor.
    web = FakeWebViewPlatform.install()..finishLoads = true;
  });

  Draft draft({
    List<MailAddress> to = const [],
    String subject = '',
    ComposeKind kind = ComposeKind.newMessage,
  }) =>
      Draft(
        accountId: 'acct-personal',
        kind: kind,
        to: to,
        cc: const [],
        bcc: const [],
        subject: subject,
        htmlBody: '<p></p>',
        attachments: const [],
      );

  /// The sample engine has two accounts, so From is a choice and a stop.
  Future<void> open(WidgetTester tester, Draft d) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mailEngineProvider.overrideWithValue(SampleMailEngine())],
        child: MaterialApp(home: ComposeScreen(draft: d)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The text field on the row whose name box says [label].
  Finder field(String label) => find.descendant(
        of: find.ancestor(
          of: find.descendant(
            of: find.byWidgetPredicate((w) => w is SizedBox && w.width == 64),
            matching: find.text(label),
          ),
          matching: find.byType(Row),
        ),
        matching: find.byType(TextField),
      );

  FocusNode node(WidgetTester tester, String label) => label == 'From'
      ? tester
          .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('from-account')))
          .focusNode!
      : tester.widget<TextField>(field(label)).focusNode!;

  /// Which stop has the cursor: a field's name, or 'body' once the editor
  /// was last told to take it.
  String at(WidgetTester tester) {
    for (final label in ['From', 'To', 'Cc', 'Bcc', 'Subject']) {
      if (label == 'Bcc' && field('Bcc').evaluate().isEmpty) continue;
      if (node(tester, label).hasFocus) return label;
    }
    return 'elsewhere';
  }

  int bodyFocused() =>
      web.ranJavaScript.where((s) => s == 'window.mailtreeFocus();').length;

  Future<void> tab(WidgetTester tester, {bool back = false}) async {
    if (back) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    if (back) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  /// A key the editor's page reports, as its script would.
  Future<void> fromBody(WidgetTester tester, String key) async {
    web.sendFromPage('MyEmail', '{"type":"key","value":"$key"}');
    await tester.pumpAndSettle();
  }

  group('Tab', () {
    testWidgets('goes To, Cc, Subject, the body, From, and round',
        (tester) async {
      await open(tester, draft());
      expect(at(tester), 'To', reason: 'a new message starts in To');

      await tab(tester);
      expect(at(tester), 'Cc', reason: 'not the Bcc button at the end of Cc');
      await tab(tester);
      expect(at(tester), 'Subject');

      final before = bodyFocused();
      await tab(tester);
      expect(bodyFocused(), before + 1, reason: 'the body is given the cursor');

      await fromBody(tester, 'tab');
      expect(at(tester), 'From');
      await tab(tester);
      expect(at(tester), 'To');
    });

    testWidgets('Shift+Tab goes back the same way', (tester) async {
      await open(tester, draft());
      await tab(tester);
      await tab(tester);
      expect(at(tester), 'Subject');

      await tab(tester, back: true);
      expect(at(tester), 'Cc');
      await tab(tester, back: true);
      expect(at(tester), 'To');
      await tab(tester, back: true);
      expect(at(tester), 'From');

      final before = bodyFocused();
      await tab(tester, back: true);
      expect(bodyFocused(), before + 1, reason: 'From goes back round to the body');

      await fromBody(tester, 'backTab');
      expect(at(tester), 'Subject');
    });

    testWidgets('stops at Bcc once it is showing', (tester) async {
      await open(tester, draft());
      await tester.tap(find.widgetWithText(TextButton, 'Bcc'));
      await tester.pumpAndSettle();
      node(tester, 'Cc').requestFocus();
      await tester.pumpAndSettle();

      await tab(tester);
      expect(at(tester), 'Bcc');
      await tab(tester);
      expect(at(tester), 'Subject');
    });

    testWidgets('held down, still only moves between the fields',
        (tester) async {
      await open(tester, draft());
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(at(tester), 'Subject');
    });

    testWidgets('enters a field with the cursor after what is in it',
        (tester) async {
      await open(tester, draft(subject: 'Quote 12'));
      await tab(tester);
      await tab(tester);
      expect(at(tester), 'Subject');
      final subject = tester.widget<TextField>(field('Subject')).controller!;
      expect(subject.selection, const TextSelection.collapsed(offset: 8));
    });
  });

  group('the cursor starts', () {
    testWidgets('in the body, for a reply', (tester) async {
      await open(
        tester,
        draft(
          kind: ComposeKind.reply,
          to: const [MailAddress(email: 'them@example.com')],
          subject: 'Re: numbers',
        ),
      );
      expect(bodyFocused(), 1);
      expect(at(tester), 'elsewhere', reason: 'no field holds it');
    });

    testWidgets('in To, for a new message, and the body is left alone',
        (tester) async {
      await open(tester, draft());
      expect(bodyFocused(), 0);
      expect(at(tester), 'To');
    });
  });
}
