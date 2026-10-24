import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/search_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'helpers/open_search.dart';

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

    test('named a part of the message, it looks there alone', () {
      expect(buildSearchCriteria('dana', field: SearchField.from),
          'CHARSET UTF-8 FROM "dana"');
      expect(buildSearchCriteria('acme invoice', field: SearchField.subject),
          'CHARSET UTF-8 SUBJECT "acme" SUBJECT "invoice"');
      expect(buildSearchCriteria('pay', field: SearchField.body),
          'CHARSET UTF-8 BODY "pay"');
      expect(buildSearchCriteria('pay', field: SearchField.body),
          isNot(contains('OR')));
    });

    test('a file by its name goes to Gmail in its own words', () {
      // IMAP has no key for it; Gmail, the one IMAP server here, has
      // filename: under X-GM-RAW.
      expect(buildSearchCriteria('invoice', field: SearchField.attachment),
          'CHARSET UTF-8 X-GM-RAW "filename:invoice"');
      expect(buildSearchCriteria('q3 report', field: SearchField.attachment),
          'CHARSET UTF-8 X-GM-RAW "filename:q3" X-GM-RAW "filename:report"');
    });

    test("All Mail's own mail is asked for in Gmail's words too", () {
      expect(
        buildSearchCriteria('acme', field: SearchField.from,
            unlabelledOnly: true),
        'CHARSET UTF-8 FROM "acme" '
        'X-GM-RAW "has:nouserlabels -in:inbox -in:sent -in:drafts"',
      );
    });

    test('a Hebrew or accented word goes as a literal, not between quotes',
        () {
      // IMAP allows only 7-bit text between quotes; Gmail answered BAD.
      // A literal is the length in bytes, then the bytes, after the line
      // break where enough_mail waits for the server's go-ahead.
      final c = buildSearchCriteria('חשבונית José');
      expect(c, contains('SUBJECT {14}\nחשבונית FROM {14}\nחשבונית '
          'BODY {14}\nחשבונית'));
      expect(c, contains('SUBJECT {5}\nJosé'));
      for (final line in c.split('\n')) {
        // Whatever follows a literal's bytes is plain command text again.
        final text = line.replaceFirst(RegExp(r'^[^ ]+ ?'), '');
        expect(RegExp(r'"[^"]*[^\x00-\x7f][^"]*"').hasMatch(text), isFalse,
            reason: 'no 8-bit text between quotes: $line');
      }
    });
  });

  group('folder names in commands', () {
    // Gmail says it takes UTF-8 but holds a client to it only once asked,
    // and enough_mail passed a Hebrew name to it as raw bytes.
    test('go as Modified UTF-7 to a server that says it takes UTF-8', () {
      expect(imapCommandPath('Café', '/', serverTakesUtf8: true), 'Caf&AOk-');
      final hebrew =
          imapCommandPath('Work/קבלות', '/', serverTakesUtf8: true);
      expect(hebrew, startsWith('Work/&'));
      expect(hebrew.codeUnits.every((c) => c < 0x80), isTrue);
      expect(
        em.Mailbox(
          encodedName: hebrew.split('/').last,
          encodedPath: hebrew,
          flags: const [],
          pathSeparator: '/',
        ).path,
        'Work/קבלות',
        reason: 'the server reads back the name it was given',
      );
      expect(imapCommandPath('R&D', '/', serverTakesUtf8: true), 'R&-D');
    });

    test('and as they stand to one that does not, which encodes them', () {
      expect(imapCommandPath('Café', '/', serverTakesUtf8: false), 'Café');
    });

    test("the server's own separator is used", () {
      expect(imapCommandPath('Work/Café', '.', serverTakesUtf8: true),
          'Work.Caf&AOk-');
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

    test('named a part of the message, it matches that part alone',
        () async {
      const scope = SearchScope.folder('acct-personal:INBOX');
      final everywhere = await engine.searchMessages('invoice', scope);
      expect(everywhere, isNotEmpty);

      final inSubject = await engine.searchMessages('invoice', scope,
          field: SearchField.subject);
      expect(inSubject, isNotEmpty);
      expect(
        inSubject.every((m) => m.subject.toLowerCase().contains('invoice')),
        isTrue,
      );

      final fromSender = await engine.searchMessages('invoice', scope,
          field: SearchField.from);
      expect(
        fromSender.every((m) =>
            '${m.from.display} ${m.from.email}'.toLowerCase().contains('invoice')),
        isTrue,
      );

      // Every sample message with files has a "Quote <n>.pdf" among them.
      final byFile = await engine.searchMessages('quote', scope,
          field: SearchField.attachment);
      expect(byFile, isNotEmpty);
      expect(byFile.every((m) => m.hasAttachments), isTrue);
      final byPhoto = await engine.searchMessages('.jpg', scope,
          field: SearchField.attachment);
      expect(byPhoto.map((m) => m.id).toSet(), byFile.map((m) => m.id).toSet());
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

    test('Spam and Trash are left out of the wide scopes, All Mail is not',
        () async {
      // As the real engine has it: mail archived with no label is in All
      // Mail and nowhere else.
      final hits = await engine.searchMessages(
        'the',
        const SearchScope.account('acct-personal'),
        limit: 1000,
      );
      final folders = await engine.loadFolders('acct-personal');
      String folderOf(FolderRole role) =>
          folders.firstWhere((f) => f.role == role).id;

      final searched = hits.map((m) => m.folderId).toSet();
      expect(searched, isNot(contains(folderOf(FolderRole.junk))));
      expect(searched, isNot(contains(folderOf(FolderRole.deleted))));
      expect(searched, contains(folderOf(FolderRole.archive)));
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
      final inbox = server.folder('INBOX', role: FolderRole.inbox);
      // Listed before the label, as Gmail may: which copy of a message is
      // shown must not come down to the order of the folders.
      final allMail =
          server.folder('[Gmail]/All Mail', role: FolderRole.archive);
      final invoice = inbox.deliver(subject: 'Acme invoice', body: 'Please pay');
      inbox.deliver(subject: 'Lunch?', body: 'Thursday');
      final contract =
          server.folder('Work').deliver(subject: 'Acme contract', body: 'Draft');
      // All Mail holds every message, these two as well, under the same
      // Message-ID.
      allMail
        ..deliver(
          subject: invoice.subject,
          body: invoice.body,
          messageId: invoice.messageId,
        )
        ..deliver(
          subject: contract.subject,
          body: contract.body,
          messageId: contract.messageId,
        );
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

    test('named a part of the message, the server is asked for that part',
        () async {
      final scope = SearchScope.folder('${account.id}:INBOX');

      String lastSearch() =>
          server.calls.lastWhere((c) => c.startsWith('UID SEARCH'));

      final inBody = await engine.searchMessages('pay', scope,
          field: SearchField.body);
      expect(inBody.single.subject, 'Acme invoice');
      expect(lastSearch(), 'UID SEARCH INBOX BODY "pay"');

      final inSubject = await engine.searchMessages('pay', scope,
          field: SearchField.subject);
      expect(inSubject, isEmpty, reason: '"pay" is in the body alone');
      expect(lastSearch(), 'UID SEARCH INBOX SUBJECT "pay"');

      server.attachments[1] = [
        MailAttachment(
          id: '2',
          name: 'Quote 44.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 10,
        ),
      ];
      final byFile = await engine.searchMessages('quote', scope,
          field: SearchField.attachment);
      expect(byFile.single.subject, 'Acme invoice');
      expect(lastSearch(), 'UID SEARCH INBOX X-GM-RAW "quote"');
    });

    test('an account search finds mail only All Mail has, and the rest once',
        () async {
      // Archived on the web or the phone, or kept out of the Inbox by a
      // filter, with no label on it: All Mail is the one folder holding it,
      // and no search wider than All Mail itself used to find it.
      server
          .folder('[Gmail]/All Mail')
          .deliver(subject: 'Acme statement', body: 'Archived');

      for (final scope in [
        SearchScope.account(account.id),
        // What All Inboxes searches.
        const SearchScope.everywhere(),
      ]) {
        final hits = await engine.searchMessages('acme', scope);

        expect(
          {for (final m in hits) m.subject: m.folderId},
          {
            'Acme statement': '${account.id}:[Gmail]/All Mail',
            // The copies elsewhere win, so a move from the results moves
            // the message out of the Inbox or the label it is under.
            'Acme invoice': '${account.id}:INBOX',
            'Acme contract': '${account.id}:Work',
          },
        );
        expect(hits, hasLength(3), reason: 'one row per message');
      }
    });

    test('All Mail is asked only for what no other folder has', () async {
      // Every search typed in All Inboxes asks All Mail. Asked for all of
      // it, nearly every hit was a copy of an Inbox or label message, its
      // header fetched for a row that was then dropped.
      final statement = server
          .folder('[Gmail]/All Mail')
          .deliver(subject: 'Acme statement', body: 'Archived');
      server.calls.clear();

      await engine.searchMessages('acme', SearchScope.account(account.id));

      expect(
        server.calls.where((c) => c.startsWith('UID SEARCH [Gmail]/All Mail')),
        [contains('X-GM-RAW "has:nouserlabels -in:inbox')],
      );
      expect(
        server.calls.where((c) => c.startsWith('UID FETCH [Gmail]/All Mail')),
        ['UID FETCH [Gmail]/All Mail ${statement.uid}'],
        reason: 'no header fetched for a copy',
      );
      expect(server.calls.where((c) => c.contains('X-GM-RAW')), hasLength(1),
          reason: 'the Inbox and the labels are searched whole');
    });

    test('All Mail searched on its own is searched whole', () async {
      final hits = await engine.searchMessages(
        'acme',
        SearchScope.folder('${account.id}:[Gmail]/All Mail'),
      );

      expect(hits.map((m) => m.subject).toSet(),
          {'Acme invoice', 'Acme contract'});
      expect(server.calls.where((c) => c.contains('X-GM-RAW')), isEmpty);
    });

    test('the hits a folder has cached are read in one go', () async {
      // Each was read from the cache on its own, a whole row with its
      // body, one after another.
      final counting = _CountingCache();
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: counting,
        transportFactory: (_, _) => server,
      );
      final account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      await engine.loadMessages('${account.id}:INBOX');
      server.calls.clear();

      final hits = await engine.searchMessages(
        'acme',
        SearchScope.folder('${account.id}:INBOX'),
      );

      expect(hits.single.subject, 'Acme invoice');
      expect(counting.singleReads, 0, reason: 'no hit read on its own');
      expect(server.calls.where((c) => c.startsWith('UID FETCH')), isEmpty);
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

    test('Starred, Important and label copies do not repeat a hit', () async {
      // On Gmail a label is the same message seen from another folder. One
      // message marked Important with a label on it came back three times.
      final inbox = server.folder('INBOX');
      final original =
          inbox.deliver(subject: 'Acme receipt', messageId: '<r1@acme>');
      for (final path in ['Receipts', '[Gmail]/Important', '[Gmail]/Starred']) {
        server
            .folder(path, serverManaged: path.startsWith('[Gmail]'))
            .deliver(subject: original.subject, messageId: '<r1@acme>');
      }
      await engine.loadFolders(account.id);
      final hits = await engine.searchMessages(
        'receipt',
        SearchScope.account(account.id),
      );

      expect(hits, hasLength(1));
      expect(hits.single.folderId, '${account.id}:INBOX',
          reason: "the Inbox's copy is the one kept");
      expect(server.calls.any((c) => c.contains('[Gmail]/Important')), isFalse);
    });

    test('an unreachable server says so, rather than that nothing matched',
        () async {
      // On the subway, "No messages found" said the message did not exist
      // when the server had not been reached at all.
      for (final listed in [false, true]) {
        // With its folders listed while there was a signal, and without.
        server.offline = false;
        if (listed) {
          await engine.loadFolders(account.id);
        } else {
          await engine.folderLists.delete(account.id);
        }
        server.offline = true;
        for (final scope in [
          SearchScope.folder('${account.id}:INBOX'),
          SearchScope.account(account.id),
          const SearchScope.everywhere(),
        ]) {
          await expectLater(
            engine.searchMessages('acme', scope),
            throwsA(isA<ConnectionFailed>()),
          );
        }
      }
    });
  });

  group('searching more than one account', () {
    late Map<String, FakeImapTransport> servers;
    late CachedImapEngine engine;

    setUp(() {
      servers = {};
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (account, _) =>
            servers.putIfAbsent(account.emailAddress, FakeImapTransport.new),
      );
    });

    Future<Account> add(String address, MailProvider provider) {
      servers[address] = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox);
      return engine.addAccount(
        displayName: address,
        emailAddress: address,
        provider: provider,
        secret: 'abcdabcdabcdabcd',
      );
    }

    test("Outlook's Archive is searched: it is a folder, not a copy", () async {
      // Left out with Gmail's All Mail, so archived Microsoft mail was never
      // found by any search wider than the Archive folder itself.
      final work = await add('me@work.example', MailProvider.outlook);
      servers['me@work.example']!
          .folder('Archive', role: FolderRole.archive)
          .deliver(subject: 'Acme contract, signed');
      await engine.loadFolders(work.id);

      final hits =
          await engine.searchMessages('acme', SearchScope.account(work.id));

      expect(hits.single.subject, 'Acme contract, signed');
      expect(
        servers['me@work.example']!.calls.where((c) => c.contains('X-GM-RAW')),
        isEmpty,
        reason: 'Gmail alone keeps one message in many folders',
      );
    });

    test("one account needing a sign-in leaves the others' results", () async {
      await add('me@gmail.example', MailProvider.gmail);
      servers['me@gmail.example']!
          .folder('INBOX')
          .deliver(subject: 'Acme invoice');
      await add('me@work.example', MailProvider.outlook);
      servers['me@work.example']!.failWith =
          const AuthenticationFailed('Sign in again.');

      final hits = await engine.searchMessages('acme', SearchScope.everywhere());

      expect(hits.single.subject, 'Acme invoice');
    });

    test('but when nothing could be searched, that is said', () async {
      await add('me@work.example', MailProvider.outlook);
      servers['me@work.example']!.failWith =
          const AuthenticationFailed('Sign in again.');

      await expectLater(
        engine.searchMessages('acme', SearchScope.everywhere()),
        throwsA(isA<AuthenticationFailed>()),
      );
    });

    test("one account out of reach leaves the others' results", () async {
      await add('me@gmail.example', MailProvider.gmail);
      servers['me@gmail.example']!
          .folder('INBOX')
          .deliver(subject: 'Acme invoice');
      await add('me@work.example', MailProvider.outlook);
      servers['me@work.example']!.offline = true;

      final hits = await engine.searchMessages('acme', SearchScope.everywhere());

      expect(hits.single.subject, 'Acme invoice');
    });

    test('and an account searched with nothing found is no messages found',
        () async {
      // Not an error because another account could not be reached: the
      // one that was searched has answered.
      await add('me@gmail.example', MailProvider.gmail);
      final work = await add('me@work.example', MailProvider.outlook);
      // Its folders not yet listed, so it fails before any folder is tried.
      await engine.folderLists.delete(work.id);
      servers['me@work.example']!.offline = true;

      expect(
        await engine.searchMessages('acme', SearchScope.everywhere()),
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

      await openSearch(tester);
      await tester.enterText(searchField, 'invoice');
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

      await openSearch(tester);
      await tester.enterText(searchField, 'invoice');
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

      await openSearch(tester);
      await tester.enterText(searchField, 'zzzznotpresent');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('No messages found'), findsOneWidget);
    });

    testWidgets('a search that reaches no server says so at once, and once',
        (tester) async {
      // Riverpod retried the failure up to ten times, some forty seconds
      // of spinner with every account reconnected each time, before the
      // list said anything.
      wide(tester);
      final engine = _Offline();
      await tester.pumpWidget(ProviderScope(
        overrides: [mailEngineProvider.overrideWithValue(engine)],
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();

      await openSearch(tester);
      await tester.enterText(searchField, 'acme');
      await tester.pump();
      // Past the pause in typing the search waits for, and no further.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.textContaining('Search failed.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(minutes: 1));
      expect(engine.searches, 1);
      expect(find.textContaining('Search failed.'), findsOneWidget);
    });

    testWidgets('the part of the message to look in is chosen under the box',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await openSearch(tester);
      await tester.enterText(searchField, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final chooser = find.byKey(const ValueKey('search-field'));
      expect(chooser, findsOneWidget);
      expect(find.byType(MessageTile), findsWidgets);

      // Nobody is called "invoice": from the sender alone there is nothing.
      await tester.tap(find.byKey(const ValueKey('search-field-from')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('No messages found'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-field-subject')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
      expect(tiles, isNotEmpty);
      expect(
        tiles.every((t) => t.message.subject.toLowerCase().contains('invoice')),
        isTrue,
      );
    });

    testWidgets('a search no server could answer says so at once, is not '
        'run again by itself, and runs again from Try again', (tester) async {
      // Riverpod ran it ten times more over half a minute, every folder's
      // search each time, with a spinner under the box until it gave up.
      wide(tester);
      final engine = _Unreachable();
      await tester.pumpWidget(ProviderScope(
        overrides: [mailEngineProvider.overrideWithValue(engine)],
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();

      await openSearch(tester);
      await tester.enterText(searchField, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));

      expect(find.textContaining('Search failed.'), findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      expect(engine.searches, 1);

      // Back in signal, the same words are asked again without retyping
      // them.
      engine.down = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(engine.searches, 2);
      expect(find.textContaining('Search failed.'), findsNothing);
      expect(find.byType(MessageTile), findsWidgets);
    });

    testWidgets('the scope chooser appears in a real folder only',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Unified inbox: nothing to scope to.
      await openSearch(tester);
      await tester.enterText(searchField, 'invoice');
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

/// The sample engine with no server to search while [down], counting each
/// time it is asked to.
class _Unreachable extends SampleMailEngine {
  var searches = 0;
  var down = true;

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    searches++;
    if (down) throw const ConnectionFailed('No server could be reached.');
    return super.searchMessages(query, scope, limit: limit, field: field);
  }
}

/// On the subway: every search fails to reach a server.
class _Offline extends SampleMailEngine {
  int searches = 0;

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    searches++;
    throw const ConnectionFailed('No connection to imap.gmail.com.');
  }
}

/// The cache, counting the messages read from it one at a time.
class _CountingCache extends MemoryCacheStore {
  int singleReads = 0;

  @override
  Future<CachedMessage?> readMessage(String accountId, String path, int uid) {
    singleReads++;
    return super.readMessage(accountId, path, uid);
  }
}
