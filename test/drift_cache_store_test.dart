import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/domain/mail_message.dart';

import 'fakes/fake_imap_transport.dart';
import 'fakes/sqlite.dart';

CachedMessage _msg(int uid, {bool read = false, String subject = 'S'}) =>
    CachedMessage(
      uid: uid,
      subject: '$subject $uid',
      from: const MailAddress(email: 'x@example.com', name: 'X'),
      to: const [MailAddress(email: 'me@example.com')],
      date: DateTime(2026, 9, 1).add(Duration(hours: uid)),
      isRead: read,
      isFlagged: false,
      hasAttachments: false,
    );

void main() {
  final available = ensureSqlite3();

  group(
    'DriftCacheStore',
    () {
      late MailDatabase db;
      late DriftCacheStore store;

      setUp(() {
        db = MailDatabase(NativeDatabase.memory());
        store = DriftCacheStore(db);
      });

      tearDown(() => db.close());

      test('folder state round-trips, including nulls', () async {
        expect(await store.readFolderState('a', 'INBOX'), isNull);
        await store.writeFolderState(
          'a',
          'INBOX',
          FolderSyncState(
            uidValidity: 7,
            lastSync: DateTime(2026, 9, 14, 10),
            uidNext: 100,
          ),
        );
        final s = await store.readFolderState('a', 'INBOX');
        expect(s!.uidValidity, 7);
        expect(s.uidNext, 100);
        expect(s.highestModSeq, isNull);
        expect(s.lastSync, DateTime(2026, 9, 14, 10));

        // Overwrite on the same key.
        await store.writeFolderState(
          'a',
          'INBOX',
          FolderSyncState(uidValidity: 8, lastSync: DateTime(2026, 9, 15)),
        );
        expect((await store.readFolderState('a', 'INBOX'))!.uidValidity, 8);
      });

      test('messages page newest first and report their uid range', () async {
        await store.upsertMessages('a', 'INBOX', [_msg(1), _msg(5), _msg(3)]);
        expect(await store.countMessages('a', 'INBOX'), 3);
        expect(await store.uidRange('a', 'INBOX'), (min: 1, max: 5));
        final page = await store.readMessages('a', 'INBOX', limit: 2);
        expect(page.map((m) => m.uid), [5, 3]);
        final next = await store.readMessages('a', 'INBOX', offset: 2, limit: 2);
        expect(next.map((m) => m.uid), [1]);
        expect(await store.uidRange('a', 'Empty'), isNull);
      });

      test('addresses survive the JSON column', () async {
        await store.upsertMessages('a', 'INBOX', [_msg(1)]);
        final m = await store.readMessage('a', 'INBOX', 1);
        expect(m!.from.name, 'X');
        expect(m.to.single.email, 'me@example.com');
        expect(m.to.single.name, isNull);
      });

      test('a header upsert keeps an existing body and preview', () async {
        await store.upsertMessages('a', 'INBOX', [_msg(1)]);
        await store.writeBody('a', 'INBOX', 1,
            text: 'Body', html: '<p>Body</p>', preview: 'Body');
        await store.upsertMessages('a', 'INBOX', [_msg(1, read: true)]);
        final m = await store.readMessage('a', 'INBOX', 1);
        expect(m!.isRead, isTrue, reason: 'header fields updated');
        expect(m.bodyText, 'Body', reason: 'body kept');
        expect(m.bodyHtml, '<p>Body</p>');
        expect(m.preview, 'Body');
      });

      test('flags update and uids delete', () async {
        await store.upsertMessages('a', 'INBOX', [_msg(1), _msg(2), _msg(3)]);
        await store.updateFlags('a', 'INBOX', {
          2: (isRead: true, isFlagged: true),
        });
        expect((await store.readMessage('a', 'INBOX', 2))!.isFlagged, isTrue);
        await store.deleteUids('a', 'INBOX', {1, 3});
        expect(await store.countMessages('a', 'INBOX'), 1);
      });

      test('clearFolder drops rows and state for that folder only', () async {
        await store.upsertMessages('a', 'INBOX', [_msg(1)]);
        await store.upsertMessages('a', 'Other', [_msg(1)]);
        await store.writeFolderState('a', 'INBOX',
            FolderSyncState(uidValidity: 1, lastSync: DateTime(2026)));
        await store.clearFolder('a', 'INBOX');
        expect(await store.countMessages('a', 'INBOX'), 0);
        expect(await store.readFolderState('a', 'INBOX'), isNull);
        expect(await store.countMessages('a', 'Other'), 1);
      });

      test('rename moves the folder and its subtree, not look-alikes',
          () async {
        await store.upsertMessages('a', 'Work', [_msg(1)]);
        await store.upsertMessages('a', 'Work/Invoices', [_msg(1)]);
        await store.upsertMessages('a', 'Workshop', [_msg(1)]);
        await store.writeFolderState('a', 'Work/Invoices',
            FolderSyncState(uidValidity: 1, lastSync: DateTime(2026)));

        await store.renameFolder('a', 'Work', 'Office');

        expect(await store.countMessages('a', 'Office'), 1);
        expect(await store.countMessages('a', 'Office/Invoices'), 1);
        expect(await store.readFolderState('a', 'Office/Invoices'), isNotNull);
        expect(await store.countMessages('a', 'Work'), 0);
        expect(await store.countMessages('a', 'Workshop'), 1,
            reason: 'prefix match respects the separator');
      });

      test('LIKE wildcards in folder names do not over-match', () async {
        await store.upsertMessages('a', 'Tax_2026', [_msg(1)]);
        await store.upsertMessages('a', 'TaxX2026', [_msg(1)]);
        await store.upsertMessages('a', 'Tax_2026/Receipts', [_msg(1)]);

        await store.deleteFolder('a', 'Tax_2026');

        expect(await store.countMessages('a', 'Tax_2026'), 0);
        expect(await store.countMessages('a', 'Tax_2026/Receipts'), 0);
        expect(await store.countMessages('a', 'TaxX2026'), 1,
            reason: '_ must be a literal underscore, not a wildcard');
      });

      test('deleteAccount is scoped to the account', () async {
        await store.upsertMessages('a', 'INBOX', [_msg(1)]);
        await store.upsertMessages('b', 'INBOX', [_msg(1)]);
        await store.deleteAccount('a');
        expect(await store.countMessages('a', 'INBOX'), 0);
        expect(await store.countMessages('b', 'INBOX'), 1);
      });

      test('the sync state machine runs unchanged on the Drift store',
          () async {
        final server = FakeImapTransport();
        final inbox = server.folder('INBOX');
        for (var i = 0; i < 8; i++) {
          inbox.deliver();
        }
        final sync = FolderSync(
          transport: server,
          store: store,
          accountId: 'a',
          windowSize: 5,
        );

        final first = await sync.sync('INBOX');
        expect(first.added, 5);

        inbox.deliver(subject: 'New');
        inbox.delete(6);
        final second = await sync.sync('INBOX');
        expect(second.added, 1);
        expect(second.removed, 1);
        final uids =
            (await store.readMessages('a', 'INBOX', limit: 100)).map((m) => m.uid);
        expect(uids, [9, 8, 7, 5, 4]);

        inbox.rebuild();
        final third = await sync.sync('INBOX');
        expect(third.cacheReset, isTrue);
      });
    },
    skip: available
        ? false
        : 'sqlite3.dll not found; see PLAN.md toolchain (tools\\sqlite3)',
  );
}
