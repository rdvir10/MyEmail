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
