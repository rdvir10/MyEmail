import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/quote_builder.dart';
import 'package:myemail/data/compose/reply_draft.dart' show asParagraphs;
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/ui/compose/html_editor.dart';

import 'fakes/fake_webview.dart';

/// Writing with lines rather than paragraphs: no gap under every line, a
/// blank line where one is wanted, and a quote that keeps its own spacing.
void main() {
  final original = MailMessage(
    id: 'a:INBOX#1',
    accountId: 'a',
    folderId: 'a:INBOX',
    uid: 1,
    subject: 'Time off',
    from: const MailAddress(email: 'karen@example.com', name: 'Karen'),
    to: const [],
    date: DateTime(2026, 10, 2, 20, 1),
    preview: '',
  );

  group('what a message opens with', () {
    test('a reply: a line to write on, then signature and quote, a blank '
        'line between each', () {
      final html = buildComposeHtml(
        kind: ComposeKind.reply,
        original: original,
        originalText: 'Hello',
        signatureHtml: '<div>Ron</div>',
      );
      expect(
        html,
        startsWith('<div>$caretMarker<br></div>$blankLine'
            '<div class="mailtree-signature"><div>Ron</div></div>$blankLine'
            '<div class="mailtree-quote"><div>On '),
      );
      expect(html, isNot(contains('<p>On ')),
          reason: 'the attribution is a line, not a spaced paragraph');
    });

    test('a new message with no signature is one line and nothing else', () {
      expect(
        buildComposeHtml(kind: ComposeKind.newMessage),
        '<div>$caretMarker<br></div>',
      );
    });

    test("a quoted Outlook message keeps the rule that takes its gaps away",
        () {
      // Outlook opens every style sheet with <!--. Escaped with the rest,
      // it took the first rule with it: p.MsoNormal {margin:0}, and every
      // quote of an Outlook message came out double-spaced.
      const outlook = '<html><head><style><!--\n'
          'p.MsoNormal {margin:0in;}\n'
          '--></style></head><body><p class="MsoNormal">Hello</p></body></html>';
      final quoted = quotedOriginal(html: outlook);
      expect(quoted, contains('p.MsoNormal {margin:0in;}'));
      expect(quoted, isNot(contains('!--')));
      expect(quoted, isNot(contains('<!--')));
    });

    test('a reply written in the notification keeps its blank lines', () {
      expect(asParagraphs('Hi\n\nThanks\nRon'),
          '<div>Hi</div>$blankLine<div>Thanks<br>Ron</div>');
    });
  });

  group('the editor', () {
    final doc = editorDocument('<div>Hi</div>', dark: false, nonce: 'n');

    test('starts close to the top, lines a little apart, no gap between',
        () {
      expect(doc, contains('padding:6px 16px'));
      expect(doc, contains('font:15px/1.35'));
      expect(doc, contains(
          "document.execCommand('defaultParagraphSeparator', false, 'div');"));
      expect(doc, contains("document.body.innerHTML = '<div><br></div>';"));
    });

    test("an old paragraph of this message's own goes out with no gap", () {
      expect(doc, contains('body > p, .mailtree-signature p{margin:0}'));
      final getHtml = doc.substring(
        doc.indexOf('window.mailtreeGetHtml = function'),
        doc.indexOf('window.mailtreeLineSpacing'),
      );
      expect(getHtml, contains("closest('.mailtree-quote')"),
          reason: "the quote's are the sender's");
      expect(getHtml, contains("paragraphs[p].style.margin = '0';"));
    });
  });

  group('line spacing on the toolbar', () {
    late FakeWebViewPlatform page;

    Future<void> pumpEditor(WidgetTester tester) async {
      page = FakeWebViewPlatform.install()..finishLoads = true;
      final controller = HtmlEditorController(initialHtml: '<div>Hi</div>');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: HtmlEditor(controller: controller)),
              EditorToolbar(controller: controller, enabled: true),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('Line spacing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('offers Outlook\'s three, written as Outlook writes them',
        (tester) async {
      await pumpEditor(tester);

      await choose(tester, '1.5 lines');
      expect(page.ranJavaScript.last, 'window.mailtreeLineSpacing("150%");');

      await choose(tester, 'Double');
      expect(page.ranJavaScript.last, 'window.mailtreeLineSpacing("200%");');

      await choose(tester, 'Single');
      expect(page.ranJavaScript.last, 'window.mailtreeLineSpacing("");');
    });
  });
}
