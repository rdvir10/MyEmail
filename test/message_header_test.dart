import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The block above a message: its subject once, and who it went to.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailMessage message({
    List<MailAddress> to = const [],
    List<MailAddress> cc = const [],
  }) =>
      MailMessage(
        id: 'a:INBOX#1',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: 'Hadco / AR Automation',
        preview: '',
        from: const MailAddress(email: 'mike@example.com', name: 'Mike McD'),
        to: to,
        cc: cc,
        date: DateTime(2026, 9, 21, 16, 26),
        isRead: true,
      );

  Future<void> pump(
    WidgetTester tester, {
    required Widget home,
    required MailMessage m,
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      messageBodyProvider(m.id).overrideWith((ref) async => const MailBody(
            text: 'Hello',
          )),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the subject', () {
    testWidgets('is said once on a screen of its own', (tester) async {
      // The app bar carries it there; the header repeating it left two
      // subject lines, the second squeezed between the buttons.
      final m = message();
      await pump(tester, m: m, home: MessageScreen(message: m));

      expect(find.text(m.subject), findsOneWidget);
    });

    testWidgets('is on its own line in the pane, not beside the buttons',
        (tester) async {
      final m = message();
      await pump(
        tester,
        m: m,
        size: const Size(1200, 900),
        home: Scaffold(body: ReadingPane(message: m, onPopOut: () {})),
      );

      expect(find.text(m.subject), findsOneWidget);
      final subject = tester.getRect(find.text(m.subject));
      final reply = tester.getRect(find.byTooltip('Reply'));
      expect(subject.bottom, lessThanOrEqualTo(reply.top + 1),
          reason: 'the buttons are under it, not beside it');
      expect(subject.width, greaterThan(400),
          reason: 'it has the width of the pane to wrap in');
    });
  });

  group('who it went to', () {
    testWidgets('every name is there, with its address', (tester) async {
      final m = message(to: const [
        MailAddress(email: 'nadav@example.com', name: 'Nadav Elster'),
        MailAddress(email: 'ron@example.com', name: 'Ron Dvir'),
      ]);
      await pump(tester, m: m, home: MessageScreen(message: m));

      expect(find.textContaining('Nadav Elster'), findsOneWidget);
      expect(find.textContaining('nadav@example.com'), findsOneWidget);
      expect(find.textContaining('Ron Dvir'), findsOneWidget);
    });

    testWidgets('a long list is not folded away', (tester) async {
      // Folding to the first two was what this did, and on a work mailbox
      // the copy list is often the point of the message.
      final m = message(to: [
        for (var i = 0; i < 9; i++)
          MailAddress(email: 'person$i@example.com', name: 'Person $i'),
      ]);
      await pump(tester, m: m, home: MessageScreen(message: m));

      expect(find.textContaining('Person 8'), findsOneWidget);
      expect(find.textContaining('person8@example.com'), findsOneWidget);
    });

    testWidgets('everyone copied is named too', (tester) async {
      final m = message(
        to: const [MailAddress(email: 'nadav@example.com', name: 'Nadav')],
        cc: const [
          MailAddress(email: 'michal@example.com', name: 'Michal Raz'),
          MailAddress(email: 'nik@example.com', name: 'Nik Shatzir'),
        ],
      );
      await pump(tester, m: m, home: MessageScreen(message: m));

      expect(find.text('CC:'), findsOneWidget);
      expect(find.textContaining('Michal Raz'), findsOneWidget);
      expect(find.textContaining('Nik Shatzir'), findsOneWidget);
    });

    testWidgets('and it folds away for anyone who wants the room',
        (tester) async {
      final m = message(
        to: const [
          MailAddress(email: 'nadav@example.com', name: 'Nadav Elster'),
          MailAddress(email: 'ron@example.com', name: 'Ron Dvir'),
          MailAddress(email: 'barry@example.com', name: 'Barry Boyd'),
        ],
        cc: const [MailAddress(email: 'michal@example.com', name: 'Michal')],
      );
      await pump(tester, m: m, home: MessageScreen(message: m));

      await tester.tap(find.text('Hide details'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Barry Boyd'), findsNothing);
      expect(find.textContaining('CC 1'), findsOneWidget);

      // The link is a span inside the summary line, not a Text of its own.
      await tester.tap(find.textContaining('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Barry Boyd'), findsOneWidget);
    });

    testWidgets('a message addressed to nobody says so', (tester) async {
      final m = message();
      await pump(tester, m: m, home: MessageScreen(message: m));

      expect(find.text('To: (nobody named)'), findsOneWidget);
    });
  });
}
