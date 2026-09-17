import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/domain/folder_role.dart';

import 'fakes/fake_imap_transport.dart';

void main() {
  late FakeImapTransport server;
  late MemoryCacheStore store;
  late FolderSync sync;

  setUp(() {
    server = FakeImapTransport();
    store = MemoryCacheStore();
    sync = FolderSync(
      transport: server,
      store: store,
      accountId: 'a',
      windowSize: 5,
      clock: () => DateTime(2026, 9, 14, 12),
    );
  });

  Future<List<int>> cachedUids() async =>
      (await store.readMessages('a', 'INBOX', limit: 1000))
          .map((m) => m.uid)
          .toList();

  group('first sync', () {
    test('fills only the newest window, by sequence number', () async {
      final inbox = server.folder('INBOX', role: FolderRole.inbox);
      for (var i = 0; i < 12; i++) {
        inbox.deliver();
      }

      final result = await sync.sync('INBOX');

      expect(result.added, 5);
      expect(result.cacheReset, isFalse);
      expect(await cachedUids(), [12, 11, 10, 9, 8]);
      expect(server.calls, contains('FETCH INBOX 8:12'));
      final state = await store.readFolderState('a', 'INBOX');
      expect(state!.uidValidity, 1000);
      expect(state.highestModSeq, inbox.highestModSeq);
    });

    test('an empty folder records state and caches nothing', () async {
      server.folder('INBOX');
      final result = await sync.sync('INBOX');
      expect(result.added, 0);
      expect(await store.readFolderState('a', 'INBOX'), isNotNull);
    });
  });

  group('incremental sync', () {
    test('new mail is appended without refetching the window', () async {
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 3; i++) {
        inbox.deliver();
      }
      await sync.sync('INBOX');
      server.calls.clear();

      inbox.deliver(subject: 'Fresh');
      inbox.deliver(subject: 'Fresher');
      final result = await sync.sync('INBOX');

      expect(result.added, 2);
      expect(await cachedUids(), [5, 4, 3, 2, 1]);
      expect(server.calls, contains('UID FETCH INBOX 4:*'));
      expect(server.calls.where((c) => c.startsWith('FETCH INBOX')), isEmpty,
          reason: 'no sequence-number refetch of the whole window');
    });

    test('nothing new means nothing added, despite the n:* quirk', () async {
      final inbox = server.folder('INBOX');
      inbox.deliver();
      inbox.deliver();
      await sync.sync('INBOX');

      final result = await sync.sync('INBOX');
      expect(result.added, 0);
      expect(await cachedUids(), [2, 1]);
    });

    test('flag changes made elsewhere are mirrored via CONDSTORE', () async {
      final inbox = server.folder('INBOX');
      inbox.deliver();
      inbox.deliver();
      inbox.deliver();
      await sync.sync('INBOX');
      server.calls.clear();

      await server.storeFlag('INBOX',
          uids: [2], flag: MessageFlag.seen, set: true);
      await server.storeFlag('INBOX',
          uids: [3], flag: MessageFlag.flagged, set: true);
      final result = await sync.sync('INBOX');

      expect(result.updated, 2, reason: 'only the two changed rows came back');
      final m2 = await store.readMessage('a', 'INBOX', 2);
      final m3 = await store.readMessage('a', 'INBOX', 3);
      expect(m2!.isRead, isTrue);
      expect(m3!.isFlagged, isTrue);
      expect(
        server.calls.any((c) => c.contains('CHANGEDSINCE')),
        isTrue,
        reason: 'CONDSTORE was used',
      );
    });

    test('without CONDSTORE every flag in the window is fetched', () async {
      server.supportsCondStore = false;
      final inbox = server.folder('INBOX');
      inbox.deliver();
      inbox.deliver();
      await sync.sync('INBOX');
      server.calls.clear();

      await server.storeFlag('INBOX',
          uids: [1], flag: MessageFlag.seen, set: true);
      final result = await sync.sync('INBOX');

      expect(result.updated, 2);
      expect(server.calls.any((c) => c.contains('CHANGEDSINCE')), isFalse);
      expect((await store.readMessage('a', 'INBOX', 1))!.isRead, isTrue);
    });

    test('messages deleted on the server disappear from the cache', () async {
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 4; i++) {
        inbox.deliver();
      }
      await sync.sync('INBOX');

      inbox.delete(2);
      inbox.delete(4);
      final result = await sync.sync('INBOX');

      expect(result.removed, 2);
      expect(await cachedUids(), [3, 1]);
    });

    test('a cached body survives a header refresh', () async {
      final inbox = server.folder('INBOX');
      inbox.deliver(body: 'The whole body text.');
      await sync.sync('INBOX');
      await sync.body('INBOX', 1);
      server.calls.clear();

      // Another sync re-upserts the header for uid 1 via the n:* quirk path.
      await sync.sync('INBOX');
      final m = await store.readMessage('a', 'INBOX', 1);
      expect(m!.bodyText, 'The whole body text.');
      expect(m.preview, 'The whole body text.');

      // And the body is served from cache now.
      await sync.body('INBOX', 1);
      expect(server.calls.where((c) => c.endsWith('BODY')), isEmpty);
    });
  });

  group('UIDVALIDITY', () {
    test('a changed UIDVALIDITY wipes the folder and refills it', () async {
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 3; i++) {
        inbox.deliver();
      }
      await sync.sync('INBOX');
      await sync.body('INBOX', 3);
      expect((await store.readMessage('a', 'INBOX', 3))!.hasBody, isTrue);

      inbox.rebuild();
      inbox.deliver(subject: 'After rebuild');
      final result = await sync.sync('INBOX');

      expect(result.cacheReset, isTrue);
      expect(result.added, 4);
      final state = await store.readFolderState('a', 'INBOX');
      expect(state!.uidValidity, 1001);
      // The old body for "uid 3" must be gone: uid 3 is a different message now.
      final m3 = await store.readMessage('a', 'INBOX', 3);
      expect(m3!.hasBody, isFalse);
      expect(m3.subject, 'Message 3');
    });
  });

  group('paging older mail', () {
    test('ensureCached extends the window downward by sequence', () async {
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 12; i++) {
        inbox.deliver();
      }
      await sync.sync('INBOX');
      expect(await store.countMessages('a', 'INBOX'), 5);

      final have = await sync.ensureCached('INBOX', 9);
      expect(have, 9);
      expect(await cachedUids(), [12, 11, 10, 9, 8, 7, 6, 5, 4]);
      expect(server.calls, contains('FETCH INBOX 4:7'));

      // Asking for more than exists caps at the folder size.
      expect(await sync.ensureCached('INBOX', 50), 12);
    });

    test('ensureCached is a no-op when enough is cached', () async {
      final inbox = server.folder('INBOX');
      inbox.deliver();
      await sync.sync('INBOX');
      server.calls.clear();
      expect(await sync.ensureCached('INBOX', 1), 1);
      expect(server.calls, isEmpty);
    });
  });

  group('cache store housekeeping', () {
    test('renaming a folder carries its cache and subtree along', () async {
      server.folder('Work').deliver();
      server.folder('Work/Invoices').deliver();
      await sync.sync('Work');
      await sync.sync('Work/Invoices');

      await store.renameFolder('a', 'Work', 'Office');
      expect(await store.countMessages('a', 'Office'), 1);
      expect(await store.countMessages('a', 'Office/Invoices'), 1);
      expect(await store.countMessages('a', 'Work'), 0);
      expect(await store.readFolderState('a', 'Office/Invoices'), isNotNull);
    });

    test('deleting an account drops everything under it', () async {
      server.folder('INBOX').deliver();
      await sync.sync('INBOX');
      await store.deleteAccount('a');
      expect(await store.countMessages('a', 'INBOX'), 0);
      expect(await store.readFolderState('a', 'INBOX'), isNull);
    });
  });
}
