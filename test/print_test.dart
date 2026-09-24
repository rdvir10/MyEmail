import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/print/message_printer.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/print_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// A message on paper, or as a PDF, which are the same sheet.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  final message = MailMessage(
    id: 'a:INBOX#1',
    accountId: 'a',
    folderId: 'a:INBOX',
    uid: 1,
    subject: 'Q3 <numbers>',
    from: const MailAddress(email: 'dana@example.com', name: 'Dana & Co'),
    to: const [MailAddress(email: 'me@example.com')],
    date: DateTime(2026, 9, 20, 13, 25),
    preview: '',
  );

  group('the page', () {
    test('has a header block, escaped, then the body as it was', () {
      final page = printableMessage(
        message,
        const MailBody(text: 'x', html: '<p>Body <b>here</b></p>'),
        bodyHtml: '<p>Body <b>here</b></p>',
      );

      expect(page, contains('<h1>Q3 &lt;numbers&gt;</h1>'));
      expect(page, contains('Dana &amp; Co &lt;dana@example.com&gt;'));
      expect(page, contains('2026-09-20 13:25'));
      expect(page, contains('<p>Body <b>here</b></p>'));
    });

    test('a refresh in the message cannot send the printer elsewhere', () {
      final page = printableMessage(
        message,
        const MailBody(text: 'x'),
        bodyHtml: '<meta http-equiv="refresh" content="0;url=https://t/">'
            '<p>Body</p>',
      );

      expect(page, isNot(contains('https://t/')));
      expect(page, contains('<p>Body</p>'));
    });

    // The message's styles share the page with the header. One rule,
    // `.head{display:none}`, printed a message without its real From and
    // Date, and a little more drew a fake pair in their place. These check
    // the page's side of that; what a browser makes of it was checked in
    // Chrome, printing to PDF, against those attacks.
    group("the message's styles cannot reach the header", () {
      const attack = '<style>.head{display:none !important}</style>'
          '<p>Body</p>';

      test('the page rules come first, in a layer of their own', () {
        final page = printableMessage(
          message,
          const MailBody(text: 'x'),
          bodyHtml: attack,
        );

        // Among !important rules the first layer beats everything after
        // it, whatever the selector. Unnamed, so nothing can join it.
        final layer = page.indexOf('@layer {');
        expect(layer, greaterThan(0));
        expect(layer, lessThan(page.indexOf(attack)));
        expect(page, contains('body > .head *'));
        expect(
          RegExp(r'body > \.head, body > \.head \* \{ all: revert !important; \}')
              .hasMatch(page),
          isTrue,
          reason: 'every property of the header is the page\'s to set',
        );
      });

      test('a style on the message\'s own <body> is not taken as the page\'s',
          () {
        // The parser merges a stray <body style> into the page's body, but
        // only where the page's body has no such attribute.
        final page = printableMessage(
          message,
          const MailBody(text: 'x'),
          bodyHtml: '<body style="margin-top:-900px !important"><p>Body</p>',
        );

        expect(page, contains('<html style="">'));
        expect(page, contains('<body style="">'));
      });

      test('the message is shut in an element it cannot close', () {
        // A stray </div> closed the last div open, and what followed was out
        // in the page, free to be laid over the header.
        String shutIn(String page) => RegExp(r'<(mailtree-message-[0-9a-f]{12})>')
            .firstMatch(page)!
            .group(1)!;
        final page = printableMessage(
          message,
          const MailBody(text: 'x'),
          bodyHtml: '</div></div><p>Body</p>',
        );
        final name = shutIn(page);
        final opened = page.indexOf('<$name>');

        expect(page.indexOf('</div></div><p>Body</p>'), greaterThan(opened));
        expect(page.indexOf('</$name>'),
            greaterThan(page.indexOf('<p>Body</p>')));
        expect(page, contains('body > $name { display: block !important; '
            'position: relative !important; z-index: 0 !important;'));
        // Made up afresh each time, so a message cannot name it.
        expect(
          shutIn(printableMessage(message, const MailBody(text: 'x'),
              bodyHtml: '<p>Body</p>')),
          isNot(name),
        );
      });
    });

    test('a plain-text message keeps its line breaks', () {
      final page = printableMessage(
        message,
        const MailBody(text: 'line one\nline <two>'),
        bodyHtml: '',
      );

      expect(page, contains('<pre'));
      expect(page, contains('line one\nline &lt;two&gt;'));
    });

    test('printed with pictures hidden, the page fetches nothing', () {
      // Printing must not tell the sender the message was read, however its
      // pictures are written.
      final hidden = printableMessage(
        message,
        const MailBody(text: 'x'),
        bodyHtml: '<img src="https://t/p.gif">',
      );
      final shown = printableMessage(
        message,
        const MailBody(text: 'x'),
        bodyHtml: '<img src="https://t/p.gif">',
        remoteAllowed: true,
      );

      expect(hidden, contains("default-src 'none'"));
      expect(hidden, isNot(contains('img-src *')));
      expect(shown, contains('img-src *'));
    });
  });

  group('from the reading pane', () {
    late FakeMessagePrinter printer;
    setUp(() => printer = FakeMessagePrinter());

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        messagePrinterProvider.overrideWithValue(printer),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the three-dot menu prints the open message', (tester) async {
      final c = await pump(tester);
      final open = c.read(selectedMessageProvider)!;

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print or save as PDF…'));
      await tester.pumpAndSettle();

      expect(printer.printed.single.title, open.subject);
      expect(printer.printed.single.html, contains('<h1>'));
      expect(printer.printed.single.html, contains(open.from.email));
    });

    testWidgets('Ctrl+P prints it from anywhere', (tester) async {
      final c = await pump(tester);
      final open = c.read(selectedMessageProvider)!;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(printer.printed.single.title, open.subject);
    });

    testWidgets('where there is no print sheet the entry is greyed',
        (tester) async {
      printer = FakeMessagePrinter(supported: false);
      await pump(tester);

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();

      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Print or save as PDF…'),
      );
      expect(item.enabled, isFalse);
    });
  });
}
