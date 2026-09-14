import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/account_store.dart';
import 'package:mailtree/data/cache/cache_store.dart';
import 'package:mailtree/data/credential_store.dart';
import 'package:mailtree/data/imap/cached_imap_engine.dart';
import 'package:mailtree/data/imap/imap_mapping.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/domain/account.dart';
import 'package:mailtree/domain/folder_role.dart';
import 'package:mailtree/ui/messages/message_tile.dart';
import 'package:mailtree/ui/messages/search_bar.dart';
import 'package:mailtree/ui/shell/app_shell.dart';

import 'fakes/fake_imap_transport.dart';

void main() {
  group('buildSearchCriteria', () {
    test('matches subject, sender or body for each word', () {
      final c = buildSearchCriteria('invoice');
      expect(c, startsWith('CHARSET UTF-8'));
      expect(c, contains('OR OR SUBJECT "invoice" FROM "invoice" BODY "invoice"'));
    });

    test('several words are ANDed, which narrows the result', () {
      final c = buildSearchCriteria('acme  invoice');
      expect('OR OR'.allMatches(c).length, 2);
      expect(c, contains('"acme"'));
      expect(c, contains('"invoice"'));
    });

    test('quotes and backslashes are escaped, not passed through', () {
      final c = buildSearchCriteria('say "hi"');
      expect(c, contains(r'"\"hi\""'));
      expect(c, isNot(contains('BODY ""hi""')),
          reason: 'an unescaped quote would close the string and inject');
      expect(buildSearchCriteria(r'back\slash'), contains(r'back\\slash'));
    });

    test('an empty query searches nothing in particular', () {
      expect(buildSearchCriteria('   '), 'ALL');
    });
  });

  group('sample engine search', () {
    late SampleMailEngine engine;

    setUp(() async {
      engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      await engine.loadFolders('acct-side');
    });

    test('a folder scope looks only in that folder', () async {
      final hits = await engine.searchMessages(
        'the',
        const SearchScope.folder('acct-personal:INBOX'),
      );
      expect(hits, isNotEmpty);
      expect(hits.every((m) => m.folderId == 'acct-personal:INBOX'), isTrue);
    });

    test('an account scope spans that account only', () async {
      final hits = await engine.searchMessages(
        'the',
        const SearchScope.account('acct-personal'),
      );
      expect(hits.map((m) => m.accountId).toSet(), {'acct-personal'});
      expect(hits.map((m) => m.folderId).toSet().length, greaterThan(1));
    });

    test('everywhere spans accounts and is newest first', () async {
      final hits =
          await engine.searchMessages('the', const SearchScope.everywhere());
      expect(hits.map((m) => m.accountId).toSet().length, 2);
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i].date.isAfter(hits[i - 1].date), isFalse);
      }
    });

    test('All Mail, Spam and Trash are left out of the wide scopes', () async {
      final hits =
          await engine.searchMessages('the', const SearchScope.everywhere());
      final folders = await engine.loadFolders('acct-personal');
      final excluded = {
        for (final f in folders)
          if (f.role == FolderRole.archive ||
              f.role == FolderRole.junk ||
              f.role == FolderRole.deleted)
            f.id,
      };
      expect(
        hits.where((m) => excluded.contains(m.folderId)),
        isEmpty,
        reason: 'All Mail would duplicate every hit',
      );
    });

    test('every word must match', () async {
      final one = await engine.searchMessages(
          'invoice', const SearchScope.everywhere());
      final two = await engine.searchMessages(
          'invoice zzzznotpresent', const SearchScope.everywhere());
      expect(one, isNotEmpty);
      expect(two, isEmpty);
    });

    test('an empty query finds nothing rather than everything', () async {
      expect(
        await engine.searchMessages('  ', const SearchScope.everywhere()),
        isEmpty,
      );
    });
  });

  group('cached engine search', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late Account account;

    setUp(() async {
      server = FakeImapTransport();
      server.folder('INBOX', role: FolderRole.inbox)
        ..deliver(subject: 'Acme invoice', body: 'Please pay')
        ..deliver(subject: 'Lunch?', body: 'Thursday');
      server.folder('Work').deliver(subject: 'Acme contract', body: 'Draft');
      server.folder('[Gmail]/All Mail', role: FolderRole.archive)
          .deliver(subject: 'Acme invoice', body: 'copy');
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
    });

    test('a folder search hits the server and returns rows', () async {
      final hits = await engine.searchMessages(
        'acme',
        SearchScope.folder('${account.id}:INBOX'),
      );
      expect(hits.single.subject, 'Acme invoice');
      expect(server.calls.any((c) => c.startsWith('UID SEARCH INBOX')), isTrue);
    });

    test('an account search covers folders but skips All Mail', () async {
      final hits = await engine.searchMessages(
        'acme',
        SearchScope.account(account.id),
      );
      expect(hits.map((m) => m.subject).toSet(), {'Acme invoice', 'Acme contract'});
      expect(
        server.calls.any((c) => c.contains('UID SEARCH [Gmail]/All Mail')),
        isFalse,
      );
    });

    test('cached rows are reused, uncached ones fetched', () async {
      // Prime the cache for INBOX.
      await engine.loadMessages('${account.id}:INBOX');
      server.calls.clear();

      await engine.searchMessages(
        'acme',
        SearchScope.account(account.id),
      );
      final fetches =
          server.calls.where((c) => c.startsWith('UID FETCH INBOX ')).toList();
      expect(fetches, isEmpty, reason: 'INBOX hit was already cached');
      expect(
        server.calls.any((c) => c.startsWith('UID FETCH Work ')),
        isTrue,
        reason: 'Work was never cached, so its hit needs headers',
      );
    });

    test('an unreachable server yields no results rather than an error',
        () async {
      server.offline = true;
      expect(
        await engine.searchMessages('acme', SearchScope.account(account.id)),
        isEmpty,
      );
    });
  });

  group('search UI', () {
    Widget app() => const ProviderScope(child: MaterialApp(home: AppShell()));

    void wide(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('typing searches and shows where each hit lives',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
      expect(tiles, isNotEmpty);
      expect(tiles.every((t) => t.folderLabel != null), isTrue,
          reason: 'results carry a folder chip');
      expect(
        tiles.every((t) => t.message.subject.toLowerCase().contains('invoice')),
        isTrue,
      );
    });

    testWidgets('clearing the box returns to the folder list', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final before =
          tester.widgetList<MessageTile>(find.byType(MessageTile)).length;

      await tester.enterText(find.byType(TextField).last, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      // The clear button inside the search field, not the folder-search one.
      await tester.tap(find.descendant(
        of: find.byType(MessageSearchBar),
        matching: find.byIcon(Icons.close),
      ));
      await tester.pumpAndSettle();

      expect(
        tester.widgetList<MessageTile>(find.byType(MessageTile)).length,
        before,
      );
    });

    testWidgets('a query with no matches says so', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'zzzznotpresent');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('No messages found'), findsOneWidget);
    });

    testWidgets('the scope chooser appears in a real folder only',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Unified inbox: nothing to scope to.
      await tester.enterText(find.byType(TextField).last, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('All mail'), findsNothing);

      await tester.tap(find.text('Inbox').first);
      await tester.pumpAndSettle();
      expect(find.text('All mail'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
    });
  });
}
