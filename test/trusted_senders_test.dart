import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/print/message_printer.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/trusted_senders.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/print_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/trusted_senders.dart';
import 'package:myemail/ui/messages/attached_message_screen.dart';
import 'package:myemail/ui/messages/full_screen_message.dart';
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

    // The same, in Junk.
    final junk = MailMessage(
      id: 'a:Junk#1',
      accountId: 'a',
      folderId: 'a:Junk',
      uid: 1,
      subject: 'Sale',
      from: const MailAddress(email: 'offers@shop.example', name: 'The Shop'),
      to: const [MailAddress(email: 'me@example.com')],
      date: DateTime(2026, 9, 20),
      preview: '',
      isRead: true,
    );

    // The blocked page keeps the address, renamed, so finding the address
    // alone could not tell a loaded picture from a blocked one.
    void expectLoaded(String page) {
      expect(page, contains('src="https://shop.example/banner.png"'));
      expect(page, isNot(contains('data-blocked-src="https')));
    }

    void expectBlocked(String page) {
      expect(page, contains('data-blocked-src="https://shop.example/'));
      expect(page, isNot(contains(' src="https://')));
      expect(page, isNot(contains('<img src="https://')));
    }

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      Widget? home,
      FakeMessagePrinter? printer,
      Map<String, MailFolder>? folders,
    }) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        if (printer != null) messagePrinterProvider.overrideWithValue(printer),
        for (final m in [message, junk])
          messageBodyProvider(m.id).overrideWith(
            (ref) async => const MailBody(
              text: 'Sale',
              html: '<p>Sale</p><img src="https://shop.example/banner.png">',
            ),
          ),
        folderIndexProvider.overrideWith((ref) => ref.watch(_folders)),
      ]);
      addTearDown(c.dispose);
      if (folders != null) c.read(_folders.notifier).set(folders);
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
      expectLoaded(platform.loadedHtml.last);
    });

    testWidgets('an untrusted sender reaches the page with pictures blocked',
        (tester) async {
      await pump(tester);

      expectBlocked(platform.loadedHtml.last);
    });

    testWidgets('Show images loads them, for this message', (tester) async {
      final c = await pump(tester);

      await tester.tap(find.text('Show images'));
      await tester.pumpAndSettle();

      expectLoaded(platform.loadedHtml.last);
      expect(c.read(trustedSendersProvider), isEmpty);
    });

    testWidgets('the setting to always show them loads them', (tester) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setAlwaysShowImages(true);
      await tester.pumpAndSettle();

      expectLoaded(platform.loadedHtml.last);
    });

    testWidgets('printing leaves out what the pane leaves out',
        (tester) async {
      // The page printed is built apart from the one on screen, and a
      // picture fetched for the paper tells the sender just the same.
      final printer = FakeMessagePrinter();
      final c = await pump(tester, printer: printer);
      Future<void> print() async {
        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Print or save as PDF…'));
        await tester.pumpAndSettle();
      }

      await print();
      expectBlocked(printer.printed.last.html);

      c.read(trustedSendersProvider.notifier).trust('offers@shop.example');
      await tester.pumpAndSettle();
      await print();
      expectLoaded(printer.printed.last.html);
    });

    testWidgets('in Junk, neither the setting nor trust loads them, and '
        'nobody is trusted from there', (tester) async {
      // The From a trust entry matches is the sender's to write, and a
      // picture loaded tells spam the address is read, and when.
      final c = await pump(
        tester,
        home: Scaffold(body: ReadingPane(message: junk)),
      );
      c.read(trustedSendersProvider.notifier).trust('@shop.example');
      c.read(displayProvider.notifier).setAlwaysShowImages(true);
      await tester.pumpAndSettle();
      expectBlocked(platform.loadedHtml.last);

      // Opened again, as landing on it in Junk would.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: Scaffold(body: ReadingPane(message: junk))),
      ));
      await tester.pumpAndSettle();
      expectBlocked(platform.loadedHtml.last);
      expect(find.text('Images are blocked'), findsOneWidget);
      expect(find.byTooltip('Always show pictures from…'), findsNothing);

      // A look, this once, is still Ron's to take.
      await tester.tap(find.text('Show images'));
      await tester.pumpAndSettle();
      expectLoaded(platform.loadedHtml.last);
    });

    testWidgets("until the message's folder is known, pictures wait",
        (tester) async {
      // A message's own window can have the message before its folder
      // list: Junk or not is not known yet, so nothing loads unasked.
      final c = await pump(tester, folders: const {});
      c.read(trustedSendersProvider.notifier).trust('offers@shop.example');
      await tester.pumpAndSettle();
      expectBlocked(platform.loadedHtml.last);

      c.read(_folders.notifier).set(_folderList);
      await tester.pumpAndSettle();
      expectLoaded(platform.loadedHtml.last);
    });

    testWidgets('in Junk, full screen and printing leave them out too',
        (tester) async {
      final printer = FakeMessagePrinter();
      final c = await pump(
        tester,
        printer: printer,
        home: Scaffold(body: ReadingPane(message: junk)),
      );
      c.read(trustedSendersProvider.notifier).trust('offers@shop.example');
      c.read(displayProvider.notifier).setAlwaysShowImages(true);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print or save as PDF…'));
      await tester.pumpAndSettle();
      expectBlocked(printer.printed.last.html);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: FullScreenMessage(message: junk)),
      ));
      await tester.pumpAndSettle();
      expectBlocked(platform.loadedHtml.last);
    });

    testWidgets('an email attached to one in Junk keeps them out too',
        (tester) async {
      final eml = Uint8List.fromList(utf8.encode([
        'From: The Shop <offers@shop.example>',
        'To: me@example.com',
        'Subject: Sale',
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=utf-8',
        '',
        '<p>Sale</p><img src="https://shop.example/banner.png">',
      ].join('\r\n')));
      final c = await pump(
        tester,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => openAttachedMessage(
              context,
              eml,
              key: 'a:Junk#1/2',
              inJunk: true,
            ),
            child: const Text('open'),
          ),
        ),
      );
      c.read(displayProvider.notifier).setAlwaysShowImages(true);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expectBlocked(platform.loadedHtml.last);
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
      expectLoaded(platform.loadedHtml.last);
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

/// The folders the reading pane's messages are in, an Inbox and a Junk.
final _folderList = {
  for (final (path, role) in [
    ('INBOX', FolderRole.inbox),
    ('Junk', FolderRole.junk),
  ])
    'a:$path': MailFolder.at(
      accountId: 'a',
      path: path,
      role: role,
      capabilities: const FolderCapabilities.systemFolder(),
    ),
};

/// The folder index as a test has it, known or not yet.
class _Folders extends Notifier<Map<String, MailFolder>> {
  @override
  Map<String, MailFolder> build() => _folderList;

  void set(Map<String, MailFolder> folders) => state = folders;
}

final _folders =
    NotifierProvider<_Folders, Map<String, MailFolder>>(_Folders.new);
