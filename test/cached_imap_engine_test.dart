import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/message_move.dart';

import 'fakes/fake_imap_transport.dart';

void main() {
  late FakeImapTransport server;
  late MemoryAccountStore accounts;
  late MemoryCredentialStore secrets;
  late MemoryCacheStore cache;
  late CachedImapEngine engine;
  final calls = <String>[];

  setUp(() {
    server = FakeImapTransport();
    accounts = MemoryAccountStore();
    secrets = MemoryCredentialStore();
    cache = MemoryCacheStore();
    calls.clear();
    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: cache,
      transportFactory: (account, credentials) {
        calls.add('transport for ${account.emailAddress} '
            'with ${credentials.runtimeType}');
        return server;
      },
    );
  });

  Future<Account> addAccount() => engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );

  void seedGmail() {
    server.folder('INBOX', role: FolderRole.inbox);
    server.folder('[Gmail]/Sent Mail', role: FolderRole.sent);
    server.folder('[Gmail]/Trash', role: FolderRole.deleted);
    server.folder('Work');
    server.folder('Work/Invoices');
  }

  group('accounts', () {
    test('adding an account probes the server before storing anything',
        () async {
      seedGmail();
      final a = await addAccount();
      expect(server.calls, contains('LIST'));
      expect(accounts.read().single.id, a.id);
      expect(await secrets.readSecret(a.id), 'abcdabcdabcdabcd');
      expect(calls.single, contains('me@example.com'));
    });

    test('two accounts added in the same millisecond get different ids',
        () async {
      // The id was the clock alone, so a second mailbox added straight after
      // the first shared its Keystore entry, its cache and its sync state.
      seedGmail();
      final first = await addAccount();
      final second = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'work@example.com',
        provider: MailProvider.gmail,
        secret: 'wxyzwxyzwxyzwxyz',
      );
      expect(second.id, isNot(first.id));
      expect(await secrets.readSecret(first.id), 'abcdabcdabcdabcd');
      expect(await secrets.readSecret(second.id), 'wxyzwxyzwxyzwxyz');
    });

    test('a refused login stores nothing', () async {
      server.offline = true;
      await expectLater(addAccount(), throwsA(isA<ConnectionFailed>()));
      expect(accounts.read(), isEmpty);
      expect(await secrets.readSecret('anything'), isNull);
    });

    test('the same address twice is refused before touching the server',
        () async {
      seedGmail();
      await addAccount();
      server.calls.clear();
      await expectLater(addAccount(), throwsA(isA<AuthenticationFailed>()));
      expect(server.calls, isEmpty);
    });

    test('removing an account clears its secret and cache', () async {
      seedGmail();
      server.folder('INBOX').deliver();
      final a = await addAccount();
      await engine.loadMessages('${a.id}:INBOX');
      expect(await cache.countMessages(a.id, 'INBOX'), 1);

      await engine.removeAccount(a.id);
      expect(accounts.read(), isEmpty);
      expect(await secrets.readSecret(a.id), isNull);
      expect(await cache.countMessages(a.id, 'INBOX'), 0);
      expect(server.calls.last, 'LOGOUT');
    });
  });

  group('folders', () {
    test('map roles, flatten Gmail system folders, nest user folders',
        () async {
      seedGmail();
      final a = await addAccount();
      final folders = await engine.loadFolders(a.id);
      final byPath = {for (final f in folders) f.path: f};

      expect(byPath['INBOX']!.role, FolderRole.inbox);
      expect(byPath['[Gmail]/Sent Mail']!.parentId, isNull);
      expect(byPath['[Gmail]/Sent Mail']!.displayName, 'Sent');
      expect(byPath['Work/Invoices']!.parentId, '${a.id}:Work');
      expect(byPath['Work']!.capabilities.canRename, isTrue);
      expect(byPath['[Gmail]/Trash']!.capabilities.canEmpty, isTrue);
    });

    test('offline, the last folder list is served; with none, it fails',
        () async {
      seedGmail();
      final a = await addAccount();
      final online = await engine.loadFolders(a.id);

      server.offline = true;
      final offline = await engine.loadFolders(a.id);
      expect(offline.map((f) => f.path), online.map((f) => f.path));
      expect(offline.firstWhere((f) => f.path == 'Work/Invoices').parentId,
          '${a.id}:Work');

      await engine.folderLists.delete(a.id);
      await expectLater(engine.loadFolders(a.id), throwsA(isA<ConnectionFailed>()));
    });

    test('rename cascades to the cache and reports the new ids', () async {
      seedGmail();
      server.folder('Work/Invoices').deliver();
      final a = await addAccount();
      await engine.loadMessages('${a.id}:Work/Invoices');

      final r = await engine.renameFolder('${a.id}:Work', 'Office');
      expect(r.oldId, '${a.id}:Work');
      expect(r.newId, '${a.id}:Office');
      expect(r.folder.path, 'Office');
      expect(await cache.countMessages(a.id, 'Office/Invoices'), 1);
      expect(await cache.countMessages(a.id, 'Work/Invoices'), 0);
      expect(server.calls, contains('RENAME Work Office'));
    });

    test('a folder deleted elsewhere loses its cache at the next listing',
        () async {
      // Kept for good before, and in the way of a later rename to its name.
      seedGmail();
      server.folder('Work/Invoices').deliver();
      final a = await addAccount();
      await engine.loadMessages('${a.id}:Work/Invoices');
      expect(await cache.countMessages(a.id, 'Work/Invoices'), 1);

      server.folders.remove('Work/Invoices');
      await engine.loadFolders(a.id);

      expect(await cache.countMessages(a.id, 'Work/Invoices'), 0);
      expect(await cache.readFolderState(a.id, 'Work/Invoices'), isNull);
    });

    test('but not when the listing could not be had', () async {
      seedGmail();
      server.folder('Work/Invoices').deliver();
      final a = await addAccount();
      await engine.loadMessages('${a.id}:Work/Invoices');

      server.offline = true;
      await engine.loadFolders(a.id);

      expect(await cache.countMessages(a.id, 'Work/Invoices'), 1);
    });

    test('rename onto an existing name is a conflict', () async {
      seedGmail();
      server.folder('Office');
      final a = await addAccount();
      await expectLater(
        engine.renameFolder('${a.id}:Work', 'office'),
        throwsA(isA<FolderNameConflict>()),
      );
    });

    test('create and delete go to the server and the cache', () async {
      seedGmail();
      final a = await addAccount();
      final created = await engine.createFolder(
        accountId: a.id,
        name: 'Receipts',
        parentId: '${a.id}:Work',
      );
      expect(created.path, 'Work/Receipts');
      expect(server.calls, contains('CREATE Work/Receipts'));

      server.folder('Work/Receipts').deliver();
      await engine.loadMessages(created.id);
      await engine.deleteFolder(created.id);
      expect(server.calls, contains('DELETE Work/Receipts'));
      expect(await cache.countMessages(a.id, 'Work/Receipts'), 0);
    });

    test('deleting a folder deletes the folders under it, deepest first',
        () async {
      // IMAP's DELETE leaves them. The dialog said they would go, the app
      // forgot their settings, and they came back at the top level.
      seedGmail();
      server
        ..folder('Work/Invoices/2026')
        ..folder('Workshop');
      final a = await addAccount();
      server.calls.clear();

      await engine.deleteFolder('${a.id}:Work');

      expect(server.calls.where((c) => c.startsWith('DELETE')), [
        'DELETE Work/Invoices/2026',
        'DELETE Work/Invoices',
        'DELETE Work',
      ]);
      final left = (await engine.loadFolders(a.id)).map((f) => f.path);
      expect(left, isNot(contains(startsWith('Work/'))));
      expect(left, contains('Workshop'), reason: 'a name that only starts '
          'the same is another folder');
    });
  });

  group('a batch delete that stops part way', () {
    test('says which went, so those can stay gone and be put back',
        () async {
      // Two folders: the first went to Trash, the second failed, and the
      // whole batch was reported as not done, with no Undo for the first.
      seedGmail();
      server.folder('INBOX').deliver(subject: 'In the Inbox');
      server.folder('Work').deliver(subject: 'In Work');
      final a = await addAccount();
      await engine.loadMessages('${a.id}:INBOX');
      await engine.loadMessages('${a.id}:Work');
      server.refuseMovesFrom.add('Work');

      await expectLater(
        engine.deleteMessages(['${a.id}:INBOX#1', '${a.id}:Work#1']),
        throwsA(isA<PartialMove>()
            .having((p) => p.moved, 'moved', ['${a.id}:INBOX#1'])
            .having((p) => p.done.single.toFolderId, 'went to',
                '${a.id}:[Gmail]/Trash')),
      );
      expect(server.folder('INBOX').messages, isEmpty);
      expect(server.folder('Work').messages, hasLength(1));
    });

    test('and one that fails before anything went is an ordinary failure',
        () async {
      seedGmail();
      server.folder('Work').deliver(subject: 'In Work');
      final a = await addAccount();
      await engine.loadMessages('${a.id}:Work');
      server.refuseMovesFrom.add('Work');

      await expectLater(
        engine.deleteMessages(['${a.id}:Work#1']),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('messages', () {
    test('lists come from the cache after a sync, newest first', () async {
      seedGmail();
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 3; i++) {
        inbox.deliver(subject: 'M${i + 1}');
      }
      final a = await addAccount();

      final page = await engine.loadMessages('${a.id}:INBOX');
      expect(page.map((m) => m.subject), ['M3', 'M2', 'M1']);
      expect(page.first.id, '${a.id}:INBOX#3');
      expect(page.first.preview, isEmpty, reason: 'no body fetched yet');
    });

    test('opening a message caches its body and fills the preview',
        () async {
      seedGmail();
      server.folder('INBOX').deliver(body: 'Full body here.');
      final a = await addAccount();
      await engine.loadMessages('${a.id}:INBOX');

      final body = await engine.loadMessageBody('${a.id}:INBOX#1');
      expect(body.text, 'Full body here.');

      final again = await engine.loadMessages('${a.id}:INBOX');
      expect(again.single.preview, 'Full body here.');

      server.calls.clear();
      await engine.loadMessageBody('${a.id}:INBOX#1');
      expect(server.calls, isEmpty, reason: 'served from cache');
    });

    test('offline, the cached list and bodies are still readable', () async {
      seedGmail();
      server.folder('INBOX').deliver(subject: 'Kept', body: 'Kept body');
      final a = await addAccount();
      await engine.loadMessages('${a.id}:INBOX');
      await engine.loadMessageBody('${a.id}:INBOX#1');

      server.offline = true;
      final page = await engine.loadMessages('${a.id}:INBOX');
      expect(page.single.subject, 'Kept');
      final body = await engine.loadMessageBody('${a.id}:INBOX#1');
      expect(body.text, 'Kept body');
    });

    test('paging past the first window fetches older mail', () async {
      seedGmail();
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 260; i++) {
        inbox.deliver();
      }
      final a = await addAccount();
      final first = await engine.loadMessages('${a.id}:INBOX', limit: 50);
      expect(first.first.uid, 260);
      final deep = await engine.loadMessages('${a.id}:INBOX',
          offset: 220, limit: 20);
      expect(deep.first.uid, 40);
      expect(deep.length, 20);
    });

    test('mark all read and empty go through the transport', () async {
      seedGmail();
      final trash = server.folder('[Gmail]/Trash');
      trash.deliver();
      trash.deliver();
      final a = await addAccount();
      await engine.loadMessages('${a.id}:[Gmail]/Trash');

      await engine.markAllRead('${a.id}:[Gmail]/Trash');
      expect(server.calls, contains('STORE [Gmail]/Trash 1:* +MessageFlag.seen'));
      final rows = await cache.readMessages(a.id, '[Gmail]/Trash');
      expect(rows.every((m) => m.isRead), isTrue);

      await engine.emptyFolder('${a.id}:[Gmail]/Trash');
      expect(server.calls, contains('EXPUNGE [Gmail]/Trash'));
      expect(trash.messages, isEmpty);
      expect(await cache.countMessages(a.id, '[Gmail]/Trash'), 0);
    });
  });

  // On both stores. The 2.29.0 bug was the database's alone: its upsert
  // never wrote the preview. Run on the in-memory store only, which never
  // had it, the test that guards it could not fail.
  for (final onDisk in [false, true]) {
    group('preview lines, ${onDisk ? 'in the database' : 'in memory'}', () {
      late CacheStore store;
      MailDatabase? db;

      setUp(() {
        db = onDisk ? MailDatabase(NativeDatabase.memory()) : null;
        store = onDisk ? DriftCacheStore(db!) : MemoryCacheStore();
        engine = CachedImapEngine(
          accountStore: accounts,
          credentialStore: secrets,
          cache: store,
          transportFactory: (_, _) => server,
        );
      });

      tearDown(() async => db?.close());

      test('a server that sends them fills in rows cached without one',
          () async {
        // What a work mailbox looks like after an update that started
        // keeping the preview: the newest mail has a second line and
        // everything below it, cached by the version before, does not.
        // Asking again for the window costs Graph nothing it was not
        // already spending.
        seedGmail();
        final inbox = server.folder('INBOX');
        inbox.deliver(subject: 'One');
        inbox.deliver(subject: 'Two');
        final a = await addAccount();
        await engine.loadMessages('${a.id}:INBOX');
        expect(
          (await store.readMessages(a.id, 'INBOX'))
              .every((m) => m.preview.isEmpty),
          isTrue,
          reason: 'nothing was sent with the headers',
        );

        // The server starts sending them, and the app syncs again.
        server.suppliesPreviews = true;
        for (final m in inbox.messages.values) {
          m.preview = 'The first line of ${m.subject}.';
        }
        await engine.loadMessages('${a.id}:INBOX');

        final rows = await store.readMessages(a.id, 'INBOX');
        expect(rows.map((m) => m.preview),
            everyElement(startsWith('The first line of')));
      });

      test('a server that sends none is never asked', () async {
        // An IMAP server has no preview at any price, and a round trip that
        // cannot help is a round trip not worth making.
        seedGmail();
        server.folder('INBOX').deliver(subject: 'One');
        final a = await addAccount();
        await engine.loadMessages('${a.id}:INBOX');
        server.calls.clear();

        await engine.loadMessages('${a.id}:INBOX');

        expect(server.calls.where((c) => c.startsWith('REFRESH')), isEmpty);
      });

      test('a preview already found in a body is not wiped by an empty one',
          () async {
        // With a second message still lacking one, so the headers really
        // are asked for again: alone, the first never was, and the test
        // checked nothing.
        seedGmail();
        final inbox = server.folder('INBOX');
        inbox.deliver(subject: 'One', body: 'Hello there.');
        final two = inbox.deliver(subject: 'Two');
        final a = await addAccount();
        final shown = await engine.loadMessages('${a.id}:INBOX');
        await engine.loadMessageBody(
          shown.firstWhere((m) => m.subject == 'One').id,
        );
        expect(
          (await store.readMessages(a.id, 'INBOX'))
              .firstWhere((m) => m.subject == 'One')
              .preview,
          isNotEmpty,
        );

        server.suppliesPreviews = true;
        two.preview = 'The second one.';
        server.calls.clear();
        await engine.loadMessages('${a.id}:INBOX');

        expect(server.calls.where((c) => c.startsWith('REFRESH')), isNotEmpty);
        final rows = await store.readMessages(a.id, 'INBOX');
        expect(rows.firstWhere((m) => m.subject == 'One').preview,
            contains('Hello there'));
        expect(rows.firstWhere((m) => m.subject == 'Two').preview,
            'The second one.');
      });
    });
  }

  group('putting a delete back', () {
    Future<Account> seeded() async {
      seedGmail();
      server.folder('INBOX')
        ..deliver(subject: 'Keep me')
        ..deliver(subject: 'Also keep me');
      final a = await addAccount();
      await engine.loadMessages('${a.id}:INBOX');
      return a;
    }

    test('goes by the ids the server gave, where it gave them', () async {
      final a = await seeded();
      final inbox = '${a.id}:INBOX';
      final before = await engine.loadMessages(inbox);
      final doomed = before.firstWhere((m) => m.subject == 'Keep me');

      final moves = await engine.deleteMessages([doomed.id]);

      expect(moves.single.movedIds, hasLength(1));
      expect(moves.single.toFolderId, '${a.id}:[Gmail]/Trash');
      await engine.undoMoves(moves);

      final after = await engine.loadMessages(inbox);
      expect(after.map((m) => m.subject), contains('Keep me'));
      expect(server.folder('[Gmail]/Trash').messages, isEmpty);
    });

    test('works on a server that will not say where it put them', () async {
      // IMAP without UIDPLUS: the move happens, no COPYUID comes back, and
      // the new UID is unknowable from the response. The Message-ID is the
      // way back, because it follows the message into its new folder.
      server.reportsCopyUids = false;
      final a = await seeded();
      final inbox = '${a.id}:INBOX';
      final before = await engine.loadMessages(inbox);
      final doomed = before.firstWhere((m) => m.subject == 'Keep me');

      final moves = await engine.deleteMessages([doomed.id]);

      expect(moves.single.movedIds, isEmpty, reason: 'the server said nothing');
      expect(moves.single.messageIds, hasLength(1));
      expect(canUndoAll(moves, 1), isTrue, reason: 'there is still a way back');

      await engine.undoMoves(moves);

      final after = await engine.loadMessages(inbox);
      expect(after.map((m) => m.subject), contains('Keep me'));
      expect(server.folder('[Gmail]/Trash').messages, isEmpty);
    });

    test('a message with no Message-ID at all cannot be put back', () async {
      // Plenty of mail in the wild has none. Better to say nothing than to
      // offer a way back that does not exist.
      server.reportsCopyUids = false;
      seedGmail();
      server.folder('INBOX').deliver(subject: 'Anonymous', messageId: '');
      final a = await addAccount();
      final inbox = '${a.id}:INBOX';
      final before = await engine.loadMessages(inbox);

      final moves = await engine.deleteMessages([before.single.id]);

      expect(canUndoAll(moves, 1), isFalse);
    });

    test('a move is put back the same way', () async {
      final a = await seeded();
      final inbox = '${a.id}:INBOX';
      final before = await engine.loadMessages(inbox);
      final one = before.first;

      final moves = await engine.moveMessages([one.id], '${a.id}:Work');
      expect(server.folder('Work').messages, hasLength(1));

      await engine.undoMoves(moves);

      expect(server.folder('Work').messages, isEmpty);
      expect(
        (await engine.loadMessages(inbox)).map((m) => m.subject),
        contains(one.subject),
      );
    });
  });
}
