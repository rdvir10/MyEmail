import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/domain/pending_change.dart';

/// Where changes made with the server out of reach wait for it: the same
/// promises from the store the tests use and from the database the phone
/// does, which the app and the background sync both write to.
void main() {
  final stores = <(String, Future<(CacheStore, Future<void> Function())> Function())>[
    ('in memory', () async => (MemoryCacheStore(), () async {})),
    (
      'in the database',
      () async {
        final db = MailDatabase(NativeDatabase.memory());
        return (DriftCacheStore(db) as CacheStore, db.close);
      }
    ),
  ];

  for (final (name, make) in stores) {
    group('changes kept for later, $name', () {
      late CacheStore store;
      late Future<void> Function() close;
      final at = DateTime(2026, 11, 12, 9);

      setUp(() async {
        final made = await make();
        store = made.$1;
        close = made.$2;
      });

      tearDown(() => close());

      PendingChange change(
        int uid, {
        String action = 'one',
        String account = 'acct',
        String path = 'INBOX',
        String? toPath = 'Trash',
        PendingKind kind = PendingKind.delete,
        Duration made = Duration.zero,
      }) =>
          PendingChange(
            accountId: account,
            path: path,
            uid: uid,
            uidValidity: 7,
            messageId: '<m$uid@example.com>',
            kind: kind,
            toPath: toPath,
            wanted: kind == PendingKind.read ? false : null,
            due: kind == PendingKind.followUp ? DateTime(2026, 11, 20) : null,
            action: action,
            madeAt: at.add(made),
          );

      Future<List<PendingChange>> claim(
        String by, {
        Duration after = const Duration(seconds: 10),
        DateTime? staleBefore,
      }) =>
          store.claimPending(
            by: by,
            madeBefore: at.add(after),
            staleBefore: staleBefore ?? at,
            now: at.add(after),
          );

      test('are kept in the order made, each given its number, and read '
          'back as written', () async {
        await store.addPending([
          change(3, kind: PendingKind.read, toPath: null),
          change(1, kind: PendingKind.followUp, toPath: null),
        ]);
        await store.addPending([change(2)]);

        final kept = await store.readPending();

        expect([for (final c in kept) c.uid], [3, 1, 2]);
        expect(kept[0].id < kept[1].id && kept[1].id < kept[2].id, isTrue);
        final read = kept[0];
        expect(
          (read.accountId, read.path, read.uidValidity, read.messageId),
          ('acct', 'INBOX', 7, '<m3@example.com>'),
        );
        expect((read.kind, read.wanted, read.toPath, read.action),
            (PendingKind.read, false, null, 'one'));
        expect(read.madeAt, at);
        expect(kept[1].due, DateTime(2026, 11, 20));
        expect((kept[2].kind, kept[2].toPath), (PendingKind.delete, 'Trash'));
      });

      test('are read for one account', () async {
        await store.addPending([change(1), change(2, account: 'other')]);

        expect([for (final c in await store.readPending(accountId: 'other')) c.uid],
            [2]);
      });

      test('are not taken before they have been held', () async {
        await store.addPending([change(1, made: const Duration(seconds: 5))]);

        expect(await claim('a', after: const Duration(seconds: 1)), isEmpty);
        expect(await claim('a', after: const Duration(seconds: 6)), hasLength(1));
      });

      test('taken by one sender, are not taken by another until it lapses',
          () async {
        await store.addPending([change(1), change(2)]);

        expect(await claim('app'), hasLength(2));
        expect(await claim('background'), isEmpty);
        expect(
          await claim('background',
              after: const Duration(minutes: 6),
              staleBefore: at.add(const Duration(minutes: 1))),
          hasLength(2),
          reason: 'a sender that died with them lets them go',
        );
      });

      test('of an account another sender holds are not taken, so the '
          'later do not go ahead of the earlier', () async {
        await store.addPending([change(1)]);
        await claim('background');
        await store.addPending([
          change(2, made: const Duration(seconds: 1)),
          change(3, account: 'other', made: const Duration(seconds: 1)),
        ]);

        final taken = await claim('app', after: const Duration(seconds: 20));

        expect([for (final c in taken) c.uid], [3]);
      });

      test('are taken for one account, where it is named', () async {
        await store.addPending([change(1), change(2, account: 'other')]);

        final taken = await store.claimPending(
          by: 'app',
          madeBefore: at.add(const Duration(seconds: 10)),
          staleBefore: at,
          now: at.add(const Duration(seconds: 10)),
          accountId: 'other',
        );

        expect([for (final c in taken) c.uid], [2]);
        expect([for (final c in await claim('background')) c.uid], [1],
            reason: 'the rest are left for another sender');
      });

      test('are held afresh while their sender works, and one that lost '
          'them hears so', () async {
        await store.addPending([change(1)]);
        await claim('app');
        expect(
          await store.renewPending('app', at.add(const Duration(minutes: 4))),
          hasLength(1),
        );
        // Not lapsed at six minutes: held afresh at four.
        expect(
          await claim('background',
              after: const Duration(minutes: 6),
              staleBefore: at.add(const Duration(minutes: 1))),
          isEmpty,
        );
        // Lapsed, taken over, and the first sender's hold is gone.
        await claim('background',
            after: const Duration(minutes: 20),
            staleBefore: at.add(const Duration(minutes: 10)));
        expect(
          await store.renewPending('app', at.add(const Duration(minutes: 20))),
          isEmpty,
        );
      });

      test('are let go of by their sender only', () async {
        await store.addPending([change(1)]);
        final taken = await claim('app');

        await store.releasePending([taken.single.id],
            by: 'someone else', error: 'Not mine.', now: at, failed: true);
        await store.unclaimPending([taken.single.id], by: 'someone else');

        expect(await claim('background'), isEmpty, reason: 'still held');
        expect(await store.takeFailedPending(), isEmpty);
        await store.unclaimPending([taken.single.id], by: 'app');
        expect(await claim('background'), hasLength(1));
        expect((await store.readPending()).single.tries, 0,
            reason: 'let go of untried');
      });

      test('let go of, are taken again, with what stopped them', () async {
        await store.addPending([change(1)]);
        final taken = await claim('app');

        await store.releasePending([taken.single.id],
            by: 'app', error: 'No connection.', now: at);

        final kept = (await store.readPending()).single;
        expect((kept.tries, kept.error), (1, 'No connection.'));
        expect(await claim('app'), hasLength(1));
      });

      test('given up on, are no longer waiting, and are handed over once',
          () async {
        await store.addPending([change(1), change(2)]);
        final taken = await claim('app');

        await store.releasePending([taken.first.id],
            by: 'app', error: 'Refused.', now: at, failed: true);

        expect([for (final c in await store.readPending()) c.uid], [2]);
        final failed = await store.takeFailedPending();
        expect([for (final c in failed) (c.uid, c.error)], [(1, 'Refused.')]);
        expect(await store.takeFailedPending(), isEmpty);
      });

      test('are dropped once sent', () async {
        await store.addPending([change(1), change(2)]);
        final taken = await claim('app');

        await store.dropPending([taken.first.id]);

        expect([for (final c in await store.readPending()) c.uid], [2]);
      });

      test('are taken back by action: those nobody is sending, and how many '
          'somebody is', () async {
        await store.addPending([change(1)]);
        await claim('app');
        await store.addPending([
          change(2, made: const Duration(minutes: 1)),
          change(3, action: 'another', made: const Duration(minutes: 1)),
        ]);

        final (:taken, :going) = await store.cancelPending(
          'one',
          staleBefore: at,
        );

        expect([for (final c in taken) c.uid], [2]);
        expect(going, 1);
        expect([for (final c in await store.readPending()) c.uid], [1, 3]);
      });

      test('are found again under a new number', () async {
        await store.addPending([change(1)]);
        final id = (await store.readPending()).single.id;

        await store.renumberPending(id, 42, 8);

        final kept = (await store.readPending()).single;
        expect((kept.uid, kept.uidValidity), (42, 8));
      });

      test('go with their account', () async {
        await store.addPending([change(1), change(2, account: 'other')]);

        await store.deleteAccount('acct');

        expect([for (final c in await store.readPending()) c.accountId],
            ['other']);
      });

      test('follow a folder renamed, from it and into it', () async {
        await store.addPending([
          change(1, path: 'Work'),
          change(2, path: 'Work/Bills'),
          change(3, toPath: 'Work/Bills'),
          change(4, path: 'Workshop'),
        ]);

        await store.renameFolder('acct', 'Work', 'Office');

        expect(
          [for (final c in await store.readPending()) (c.path, c.toPath)],
          [
            ('Office', 'Trash'),
            ('Office/Bills', 'Trash'),
            ('INBOX', 'Office/Bills'),
            ('Workshop', 'Trash'),
          ],
        );
      });

      test('go with a folder deleted', () async {
        await store.addPending([
          change(1, path: 'Work'),
          change(2, path: 'Work/Bills'),
          change(3),
        ]);

        await store.deleteFolder('acct', 'Work');

        expect([for (final c in await store.readPending()) c.uid], [3]);
      });
    });
  }
}
