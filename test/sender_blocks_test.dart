import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/sender_blocks.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sender_blocks.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/settings/blocked_senders_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_imap_transport.dart';
import 'fakes/fake_webview.dart';

/// Block sender and Not junk (#40): the app's own lists, new mail from a
/// blocked sender sent to Junk as it arrives, and the menus that fill them.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('the lists', () {
    test('a sender is blocked by address or by domain, unless never blocked',
        () {
      final blocks = const SenderBlocks()
          .block('Spam@Shop.example')
          .block('@ads.example');

      expect(blocks.blocks('spam@shop.example'), isTrue);
      expect(blocks.blocks('other@shop.example'), isFalse);
      expect(blocks.blocks('anyone@ads.example'), isTrue);
      expect(blocks.blocks('dana@example.com'), isFalse);
      expect(blocks.blocks(null), isFalse);

      final excepted = blocks.neverBlock('news@ads.example');
      expect(excepted.blocks('news@ads.example'), isFalse);
      expect(excepted.blocks('promo@ads.example'), isTrue);
      expect(excepted.neverBlocks('NEWS@ads.example'), isTrue);
    });

    test('blocking takes a sender off the never-blocked list, and back', () {
      final blocks = const SenderBlocks().neverBlock('dana@example.com');
      final blocked = blocks.block('dana@example.com');

      expect(blocked.safe, isEmpty);
      expect(blocked.blocks('dana@example.com'), isTrue);
      expect(blocked.neverBlock('dana@example.com').blocked, isEmpty);
      expect(blocked.forget('dana@example.com').isEmpty, isTrue);
    });

    test('what can be typed as an entry', () {
      expect(SenderBlocks.entryFrom(' Dana@Example.com '), 'dana@example.com');
      expect(SenderBlocks.entryFrom('example.com'), '@example.com');
      expect(SenderBlocks.entryFrom('@example.com'), '@example.com');
      expect(SenderBlocks.entryFrom('localhost'), isNull);
      expect(SenderBlocks.entryFrom(''), isNull);
      expect(SenderBlocks.entryFrom('@'), isNull);
    });

    test('kept as JSON, and what does not read is nothing', () {
      final blocks =
          const SenderBlocks().block('@ads.example').neverBlock('a@b.example');

      expect(SenderBlocks.fromJsonString(blocks.toJsonString()), blocks);
      expect(SenderBlocks.fromJsonString('not json'), const SenderBlocks());
      expect(SenderBlocks.fromJsonString(null), const SenderBlocks());
    });
  });

  group('as mail arrives', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late Account account;
    var blocks = const SenderBlocks();

    setUp(() async {
      blocks = const SenderBlocks();
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('[Gmail]/Spam', role: FolderRole.junk)
        ..folder('[Gmail]/Trash', role: FolderRole.deleted)
        ..folder('Work');
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
        senderBlocks: () => blocks,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      await engine.loadFolders(account.id);
    });

    String inbox() => '${account.id}:INBOX';

    test('new mail from a blocked sender goes to Junk before the list has '
        'it; the rest stays', () async {
      server.folder('INBOX').deliver(subject: 'Before', from: 'spam@ads.example');
      await engine.loadMessages(inbox());
      blocks = const SenderBlocks().block('@ads.example');
      server.folder('INBOX')
        ..deliver(subject: 'Offer', from: 'promo@ads.example')
        ..deliver(subject: 'Lunch', from: 'dana@example.com');

      final list = await engine.loadMessages(inbox());

      expect(list.map((m) => m.subject), containsAll(['Before', 'Lunch']),
          reason: 'mail there before the block stays where it is');
      expect(list.map((m) => m.subject), isNot(contains('Offer')));
      expect(
        server.folder('[Gmail]/Spam').messages.values.map((m) => m.subject),
        ['Offer'],
      );
    });

    test('someone never blocked is not moved, though their domain is',
        () async {
      await engine.loadMessages(inbox());
      blocks = const SenderBlocks()
          .block('@ads.example')
          .neverBlock('news@ads.example');
      server.folder('INBOX').deliver(subject: 'Wanted', from: 'news@ads.example');

      final list = await engine.loadMessages(inbox());

      expect(list.single.subject, 'Wanted');
      expect(server.folder('[Gmail]/Spam').messages, isEmpty);
    });

    test('only the Inbox: mail filed elsewhere is left alone', () async {
      await engine.loadMessages('${account.id}:Work');
      blocks = const SenderBlocks().block('@ads.example');
      server.folder('Work').deliver(subject: 'Filed', from: 'promo@ads.example');

      final list = await engine.loadMessages('${account.id}:Work');

      expect(list.single.subject, 'Filed');
    });

    test('the first fill of an Inbox is the Inbox as it was, and stays',
        () async {
      blocks = const SenderBlocks().block('@ads.example');
      server.folder('INBOX').deliver(subject: 'Old', from: 'promo@ads.example');

      final list = await engine.loadMessages(inbox());

      expect(list.single.subject, 'Old');
    });
  });

  group('on screen', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      SampleMailEngine? engine,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        if (engine != null) mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    List<String> rows(ProviderContainer c) => [
          for (final m in c.read(sortedMessagesProvider(
              c.read(effectiveSelectedFolderIdProvider)!)))
            m.id,
        ];

    Future<void> fromMenu(WidgetTester tester, String entry) async {
      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
    }

    testWidgets('Block sender: this message to Junk, their mail after it '
        'too, and Undo takes both back', (tester) async {
      final engine = SampleMailEngine();
      final c = await pump(tester, engine: engine);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;
      final email = message.from.email;

      await fromMenu(tester, 'Block sender');

      expect(find.text('Blocked. Mail from $email goes to Junk.'),
          findsOneWidget);
      expect(rows(c), isNot(contains(message.id)));
      expect(c.read(senderBlocksProvider).blocks(email), isTrue);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(c.read(senderBlocksProvider).blocks(email), isFalse);
      final inbox =
          await tester.runAsync(() => engine.loadMessages(message.folderId));
      expect(inbox!.any((m) => m.subject == message.subject), isTrue);
    });

    testWidgets('a blocked sender is offered Unblock, and the never-blocked '
        'entries by name and by domain', (tester) async {
      final c = await pump(tester);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final email = c.read(selectedMessageProvider)!.from.email;
      final domain = email.substring(email.indexOf('@'));
      c.read(senderBlocksProvider.notifier).block(domain);
      await tester.pumpAndSettle();

      await fromMenu(tester, "Never block sender's domain");
      expect(c.read(senderBlocksProvider).safe, {domain});
      expect(c.read(senderBlocksProvider).blocked, isEmpty);

      c.read(senderBlocksProvider.notifier)
        ..forget(domain)
        ..block(email);
      await tester.pumpAndSettle();
      await fromMenu(tester, 'Unblock sender');
      expect(c.read(senderBlocksProvider).blocks(email), isFalse);
      expect(find.text('$email unblocked.'), findsOneWidget);
    });

    testWidgets('Not junk, in Junk: back to the Inbox, and never blocked',
        (tester) async {
      final c = await pump(tester);
      final spam = c
          .read(foldersProvider)
          .value!['acct-personal']!
          .firstWhere((f) => f.role == FolderRole.junk);
      c.read(selectedFolderIdProvider.notifier).select(spam.id);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('Not junk'),
      ));
      await tester.pumpAndSettle();

      expect(rows(c), isNot(contains(message.id)));
      expect(c.read(senderBlocksProvider).neverBlocks(message.from.email),
          isTrue);
      expect(
        find.textContaining('Moved to Inbox.'),
        findsOneWidget,
      );
    });

    testWidgets('Settings lists them, takes typed ones, and removes them',
        (tester) async {
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: BlockedSendersScreen()),
      ));
      Finder field(String section) => find.descendant(
            of: find.byKey(ValueKey('add-$section')),
            matching: find.byType(TextField),
          );
      Finder add(String section) => find.descendant(
            of: find.byKey(ValueKey('add-$section')),
            matching: find.text('Add'),
          );

      await tester.enterText(field('blocked'), 'ads.example');
      await tester.tap(add('blocked'));
      await tester.pumpAndSettle();
      expect(find.text('Everyone at ads.example'), findsOneWidget);
      expect(c.read(senderBlocksProvider).blocked, {'@ads.example'});

      await tester.enterText(field('safe'), 'nonsense');
      await tester.tap(add('safe'));
      await tester.pumpAndSettle();
      expect(find.text('An address, or a domain such as example.com'),
          findsOneWidget, reason: 'a word with no dot is no domain');
      expect(c.read(senderBlocksProvider).safe, isEmpty);

      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('blocked:@ads.example')),
        matching: find.byTooltip('Remove'),
      ));
      await tester.pumpAndSettle();
      expect(c.read(senderBlocksProvider).blocked, isEmpty);
    });
  });
}
