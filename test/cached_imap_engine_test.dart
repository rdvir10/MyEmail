import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/account_store.dart';
import 'package:mailtree/data/cache/cache_store.dart';
import 'package:mailtree/data/credential_store.dart';
import 'package:mailtree/data/imap/cached_imap_engine.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/domain/account.dart';
import 'package:mailtree/domain/folder_role.dart';

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
      transportFactory: (account, secret) {
        calls.add('transport for ${account.emailAddress} with ${secret.length} chars');
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
}
