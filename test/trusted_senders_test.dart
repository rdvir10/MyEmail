import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/trusted_senders.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/trusted_senders.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/settings/trusted_senders_screen.dart';

import 'fakes/fake_webview.dart';

/// Pictures from a sender you trust, without being asked every time.
void main() {
  group('who is covered', () {
    test('an address, and a whole domain when asked for one', () {
      final trusted = {'sales@shop.example', '@news.example'};

      expect(isSenderTrusted(trusted, 'sales@shop.example'), isTrue);
      expect(isSenderTrusted(trusted, 'SALES@Shop.Example'), isTrue,
          reason: 'addresses are not case-sensitive');
      expect(isSenderTrusted(trusted, 'offers@shop.example'), isFalse,
          reason: 'one address is one address');
      expect(isSenderTrusted(trusted, 'anyone@news.example'), isTrue);
      expect(isSenderTrusted(trusted, 'someone@elsewhere.example'), isFalse);
      expect(isSenderTrusted(trusted, null), isFalse);
      expect(isSenderTrusted(trusted, ''), isFalse);
    });

    test('a domain entry is written so it cannot be taken for an address', () {
      expect(trustDomain('sales@shop.example'), '@shop.example');
      expect(trustAddress(' Sales@Shop.Example '), 'sales@shop.example');
      expect(trustDomain('not-an-address'), isNull);
      expect(describeTrustEntry('@shop.example'), 'Everyone at shop.example');
      expect(describeTrustEntry('a@b.example'), 'a@b.example');
    });

    test('domains are listed first, each alphabetically', () {
      expect(
        sortedTrustEntries({'b@x.example', '@z.example', 'a@x.example', '@a.example'}),
        ['@a.example', '@z.example', 'a@x.example', 'b@x.example'],
      );
    });
  });

  group('remembering', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a trusted sender outlives the app, and can be taken back', () {
      final store = MemoryUiStateStore();
      final first = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      first.read(trustedSendersProvider.notifier).trust('Sales@Shop.Example');
      expect(first.read(trustedSendersProvider), {'sales@shop.example'});
      first.dispose();

      final second = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      addTearDown(second.dispose);
      expect(second.read(trustedSendersProvider.notifier).trusts('sales@shop.example'),
          isTrue, reason: 'kept across a restart');

      second.read(trustedSendersProvider.notifier).forget('sales@shop.example');
      expect(second.read(trustedSendersProvider), isEmpty);
    });

    test('nothing empty is ever trusted', () {
      final c = container();
      c.read(trustedSendersProvider.notifier)
        ..trust('   ')
        ..trust('@');
      expect(c.read(trustedSendersProvider), isEmpty);
    });
  });

  group('in the reading pane', () {
    late FakeWebViewPlatform platform;
    setUp(() => platform = FakeWebViewPlatform.install());

    final message = MailMessage(
      id: 'a:INBOX#1',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: 1,
      subject: 'Sale',
      from: const MailAddress(email: 'offers@shop.example', name: 'The Shop'),
      to: const [MailAddress(email: 'me@example.com')],
      date: DateTime(2026, 9, 20),
      preview: '',
      isRead: true,
    );

    Future<ProviderContainer> pump(WidgetTester tester, {Widget? home}) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        messageBodyProvider(message.id).overrideWith(
          (ref) async => const MailBody(
            text: 'Sale',
            html: '<p>Sale</p><img src="https://shop.example/banner.png">',
          ),
        ),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: home ?? Scaffold(body: ReadingPane(message: message))),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the blocked bar offers to trust the sender or the domain',
        (tester) async {
      final c = await pump(tester);
      expect(find.text('Images are blocked'), findsOneWidget);

      await tester.tap(find.byTooltip('Always show pictures from…'));
      await tester.pumpAndSettle();
      expect(find.text('Always show from offers@shop.example'), findsOneWidget);
      await tester.tap(find.text('Always show from everyone at shop.example'));
      await tester.pumpAndSettle();

      expect(c.read(trustedSendersProvider), {'@shop.example'});
      expect(find.text('Images are blocked'), findsNothing,
          reason: 'trusting loads them at once, as proof it took');
      expect(platform.loadedHtml.last, contains('https://shop.example/banner.png'));
    });

    testWidgets('a trusted sender is never asked about again', (tester) async {
      final c = await pump(tester);
      c.read(trustedSendersProvider.notifier).trust('offers@shop.example');
      await tester.pumpAndSettle();
      platform.loadedHtml.clear();

      // Open it again, as returning to the message would.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: Scaffold(body: ReadingPane(message: message))),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Images are blocked'), findsNothing);
      expect(platform.loadedHtml.last, contains('https://shop.example/banner.png'));
    });

    testWidgets('trusting can be undone from the message itself',
        (tester) async {
      final c = await pump(tester);
      await tester.tap(find.byTooltip('Always show pictures from…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Always show from offers@shop.example'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(c.read(trustedSendersProvider), isEmpty);
    });

    testWidgets('Settings lists them and takes one back', (tester) async {
      final c = await pump(tester, home: const TrustedSendersScreen());
      c.read(trustedSendersProvider.notifier)
        ..trust('offers@shop.example')
        ..trust('@news.example');
      await tester.pumpAndSettle();

      expect(find.text('offers@shop.example'), findsOneWidget);
      expect(find.text('Everyone at news.example'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('@news.example')),
        matching: find.byTooltip('Stop trusting'),
      ));
      await tester.pumpAndSettle();

      expect(c.read(trustedSendersProvider), {'offers@shop.example'});
      expect(find.text('Everyone at news.example'), findsNothing);
    });
  });
}
