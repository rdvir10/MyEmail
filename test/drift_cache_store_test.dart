import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/domain/address_suggestions.dart';
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

/// The one rule for a preview, on either store. The 2.29.0 bug: the
/// database's upsert left the preview out, so a row cached without one
/// never got one; the in-memory store, which the engine tests use, kept the
/// old one instead. Neither is what the other did.
Future<void> _previewsMerge(CacheStore store) async {
  await store.upsertMessages('a', 'INBOX', [_msg(1)]);
  Future<String> preview() async =>
      (await store.readMessages('a', 'INBOX')).single.preview;

  await store.upsertMessages('a', 'INBOX', [_msg(1).copyWith(preview: 'X')]);
  expect(await preview(), 'X');

  await store.upsertMessages('a', 'INBOX', [_msg(1)]);
  expect(await preview(), 'X', reason: 'an empty one leaves it');

  await store.upsertMessages('a', 'INBOX', [_msg(1).copyWith(preview: 'Y')]);
  expect(await preview(), 'Y', reason: 'a new one replaces it');
}

/// A folder deleted or renamed on another device leaves its cache here. A
/// rename to its old name then collided with it, after the server had
/// already made the rename, and was reported as failed.
Future<void> _renameOntoLeftovers(CacheStore store) async {
  await store.upsertMessages('a', 'Old', [_msg(1), _msg(2)]);
  await store.upsertMessages('a', 'Old/Sub', [_msg(3)]);
  await store.writeFolderState(
      'a', 'Old', FolderSyncState(uidValidity: 1, lastSync: DateTime(2026)));
  await store.upsertMessages('a', 'Now', [_msg(1, subject: 'Mine')]);
  await store.writeFolderState(
      'a', 'Now', FolderSyncState(uidValidity: 2, lastSync: DateTime(2026)));

  await store.renameFolder('a', 'Now', 'Old');

  final rows = await store.readMessages('a', 'Old');
  expect(rows.single.subject, 'Mine 1');
  expect((await store.readFolderState('a', 'Old'))!.uidValidity, 2);
  expect(await store.countMessages('a', 'Old/Sub'), 0,
      reason: 'the old folder had no subfolder by that name any more');
  expect(await store.countMessages('a', 'Now'), 0);
}

/// Only what the server still lists stays cached.
Future<void> _pruneToListing(CacheStore store) async {
  await store.upsertMessages('a', 'INBOX', [_msg(1)]);
  await store.upsertMessages('a', 'Gone', [_msg(1)]);
  await store.writeFolderState(
      'a', 'Gone', FolderSyncState(uidValidity: 1, lastSync: DateTime(2026)));
  await store.upsertMessages('b', 'Gone', [_msg(1)]);

  await store.pruneFolders('a', {'INBOX', 'Sent'});

  expect(await store.countMessages('a', 'INBOX'), 1);
  expect(await store.countMessages('a', 'Gone'), 0);
  expect(await store.readFolderState('a', 'Gone'), isNull);
  expect(await store.countMessages('b', 'Gone'), 1,
      reason: 'another account has folders of its own');
}

/// Someone only ever copied is someone you write to.
Future<void> _copiedAreSuggested(CacheStore store) async {
  await store.upsertMessages('a', 'INBOX', [
    CachedMessage(
      uid: 1,
      subject: 'Plans',
      from: const MailAddress(email: 'dana@example.com'),
      to: const [MailAddress(email: 'me@example.com')],
      cc: const [MailAddress(email: 'omer@example.com', name: 'Omer')],
      date: DateTime(2026, 9, 1),
      isRead: false,
      isFlagged: false,
      hasAttachments: false,
    ),
  ]);

  final addresses =
      await store.addressHistory(mine: const {}, now: DateTime(2026, 10));

  expect(addresses.map((a) => a.email).toList()..sort(),
      ['dana@example.com', 'me@example.com', 'omer@example.com']);
  expect(addresses.firstWhere((a) => a.email == 'omer@example.com').name,
      'Omer');
}

/// Who has been written to, how often and how lately, counted the same in
/// SQL as in Dart: one message once however many folders hold it, a
/// message from one of the accounts making its recipients people written
/// to, the newest name and spelling for each address.
Future<void> _historyCounted(CacheStore store) async {
  CachedMessage message(
    int uid, {
    required MailAddress from,
    required List<MailAddress> to,
    List<MailAddress> cc = const [],
    required DateTime date,
    String? messageId,
  }) =>
      CachedMessage(
        uid: uid,
        subject: 'S',
        from: from,
        to: to,
        cc: cc,
        date: date,
        isRead: true,
        isFlagged: false,
        hasAttachments: false,
        messageId: messageId,
      );
  const me = MailAddress(email: 'me@example.com');
  final dana = message(
    1,
    from: const MailAddress(email: 'dana@example.com', name: 'Dana L.'),
    to: const [me],
    date: DateTime.utc(2026, 9, 1),
    messageId: '<a@example.com>',
  );
  // Gmail's All Mail holds the same message again.
  await store.upsertMessages('a', 'INBOX', [dana]);
  await store.upsertMessages('a', '[Gmail]/All Mail', [
    message(
      7,
      from: dana.from,
      to: dana.to,
      date: dana.date,
      messageId: dana.messageId,
    ),
  ]);
  await store.upsertMessages('a', 'Sent', [
    message(
      2,
      from: const MailAddress(email: 'me@example.com', name: 'Me'),
      to: const [MailAddress(email: 'Dana@Example.com', name: 'Dana Levi')],
      cc: const [MailAddress(email: 'omer@example.com')],
      date: DateTime.utc(2026, 9, 30),
      messageId: '<b@example.com>',
    ),
  ]);
  // From the other account, ninety days back, with no Message-ID.
  await store.upsertMessages('b', 'Sent', [
    message(
      3,
      from: const MailAddress(email: 'ME@example.com'),
      to: const [MailAddress(email: 'dana@example.com')],
      date: DateTime.utc(2026, 7, 3),
    ),
  ]);
  await store.upsertMessages('a', 'INBOX', [
    message(
      4,
      from: const MailAddress(email: 'news@shop.example'),
      to: const [MailAddress(email: 'undisclosed-recipients')],
      date: DateTime.utc(2026, 9, 15),
    ),
  ]);

  final history = await store.addressHistory(
    mine: const {'me@example.com'},
    now: DateTime.utc(2026, 10, 1),
  );
  AddressSuggestion person(String email) =>
      history.singleWhere((h) => h.email.toLowerCase() == email);

  expect(history.map((h) => h.email.toLowerCase()).toSet(), {
    'dana@example.com',
    'me@example.com',
    'omer@example.com',
    'news@shop.example',
  }, reason: 'something without an @ is nobody');

  final d = person('dana@example.com');
  expect(d.timesSeen, 3, reason: 'the copy in All Mail is the same message');
  expect(d.timesSent, 2);
  expect(d.weight, closeTo(30 / 31 + 30 / 120, 1e-6));
  expect(d.name, 'Dana Levi', reason: 'the newest name');
  expect(d.email, 'Dana@Example.com', reason: 'the newest spelling');

  final m = person('me@example.com');
  expect(m.timesSeen, 3);
  expect(m.timesSent, 0, reason: 'sending is not being written to');
  expect(m.name, 'Me');

  expect(person('omer@example.com').timesSent, 1,
      reason: 'copied is written to');
  expect(person('news@shop.example').timesSent, 0);
}

/// Replied to and forwarded are kept with the row, replaced by the flags a
/// sync reads, and written again by a header read again, as read is.
Future<void> _repliedAndForwarded(CacheStore store) async {
  await store.upsertMessages('a', 'INBOX', [
    _msg(1).copyWith(isAnswered: true),
    _msg(2),
  ]);
  Future<CachedMessage> row(int uid) async =>
      (await store.readMessage('a', 'INBOX', uid))!;

  expect((await row(1)).isAnswered, isTrue);
  expect((await row(1)).isForwarded, isFalse);
  final listed =
      (await row(1)).toMailMessage(accountId: 'a', folderId: 'a:INBOX');
  expect(listed.isAnswered, isTrue);

  await store.updateFlags('a', 'INBOX', {
    1: (isRead: false, isFlagged: false, isAnswered: false, isForwarded: true),
  });
  expect((await row(1)).isAnswered, isFalse);
  expect((await row(1)).isForwarded, isTrue);

  await store.upsertMessages('a', 'INBOX', [
    _msg(2).copyWith(isAnswered: true, isForwarded: true),
  ]);
  expect((await row(2)).isAnswered, isTrue);
  expect((await row(2)).isForwarded, isTrue);

  // A row read again without a size keeps the one it had, in either store.
  await store.upsertMessages('a', 'INBOX', [_msg(1).copyWith(sizeBytes: 4096)]);
  await store.upsertMessages('a', 'INBOX', [_msg(1)]);
  expect((await row(1)).sizeBytes, 4096);

  // A size the server sends with the flags is kept; a message not cached
  // is left alone.
  await store.updateSizes('a', 'INBOX', {1: 2048, 99: 5});
  expect((await row(1)).sizeBytes, 2048);
  expect(
    (await row(1)).toMailMessage(accountId: 'a', folderId: 'a:INBOX')
        .sizeBytes,
    2048,
  );
  expect(await store.readMessage('a', 'INBOX', 99), isNull);
}

/// Every query a database runs, to see what it reads.
class _Selects extends QueryInterceptor {
  final statements = <String>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements.add(statement);
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  final available = ensureSqlite3();

  test('MemoryCacheStore merges previews as the database does',
      () => _previewsMerge(MemoryCacheStore()));

  test('MemoryCacheStore renames over leftovers as the database does',
      () => _renameOntoLeftovers(MemoryCacheStore()));

  test('MemoryCacheStore prunes as the database does',
      () => _pruneToListing(MemoryCacheStore()));

  test('MemoryCacheStore suggests the copied as the database does',
      () => _copiedAreSuggested(MemoryCacheStore()));

  test('MemoryCacheStore counts who was written to as the database does',
      () => _historyCounted(MemoryCacheStore()));

  test('MemoryCacheStore keeps replies and forwards as the database does',
      () => _repliedAndForwarded(MemoryCacheStore()));

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

      test('whether previews were asked for is kept with the state', () async {
        await store.writeFolderState(
          'a',
          'INBOX',
          FolderSyncState(
            uidValidity: 7,
            lastSync: DateTime(2026, 9, 14),
            previewsChecked: true,
          ),
        );
        final state = await store.readFolderState('a', 'INBOX');
        expect(state!.previewsChecked, isTrue);
      });

      test('when a message arrived is kept, and not lost to a header without',
          () async {
        final arrived = DateTime(2026, 9, 2, 8, 30);
        await store.upsertMessages('a', 'INBOX', [
          CachedMessage(
            uid: 1,
            subject: 'Late',
            from: const MailAddress(email: 'x@example.com'),
            to: const [],
            date: DateTime(2026, 9, 1),
            arrived: arrived,
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
          ),
        ]);
        expect((await store.readMessage('a', 'INBOX', 1))!.arrived, arrived);

        await store.upsertMessages('a', 'INBOX', [_msg(1)]);
        final row = await store.readMessage('a', 'INBOX', 1);
        expect(row!.arrived, arrived);
        expect(
          row.toMailMessage(accountId: 'a', folderId: 'a:INBOX').arrived,
          arrived,
        );
      });

      test('the sync reads numbers, dates and whether there is a preview',
          () async {
        await store.upsertMessages('a', 'INBOX', [
          _msg(1).copyWith(sizeBytes: 4096),
          _msg(2).copyWith(preview: 'Hello'),
        ]);
        await store.upsertMessages('a', 'Other', [_msg(3)]);

        final rows = await store.readSyncRows('a', 'INBOX');

        expect(rows, [
          (
            uid: 2,
            date: _msg(2).date,
            hasPreview: true,
            hasConversation: false,
            hasSize: false,
          ),
          (
            uid: 1,
            date: _msg(1).date,
            hasPreview: false,
            hasConversation: false,
            hasSize: true,
          ),
        ]);
      });

      test('and not bodies, for that or for address suggestions', () async {
        // Both used to read whole rows, and a whole row is mostly its body.
        final seen = _Selects();
        final watched =
            MailDatabase(NativeDatabase.memory().interceptWith(seen));
        addTearDown(watched.close);
        final watchedStore = DriftCacheStore(watched);
        await watchedStore.upsertMessages('a', 'INBOX', [_msg(1)]);
        seen.statements.clear();

        await watchedStore.readSyncRows('a', 'INBOX');
        await watchedStore.addressHistory(
          mine: const {'me@example.com'},
          now: DateTime(2026, 10),
        );

        expect(seen.statements, hasLength(2));
        for (final sql in seen.statements) {
          expect(sql, isNot(contains('body_html')));
          expect(sql, isNot(contains('body_text')));
          expect(sql, isNot(contains('*')));
        }
      });

      test('address suggestions include the copied',
          () => _copiedAreSuggested(store));

      test('who was written to is counted across the whole cache',
          () => _historyCounted(store));

      test('replied to and forwarded are kept, and a sync replaces them',
          () => _repliedAndForwarded(store));

      test('a rename lands over what a vanished folder left',
          () => _renameOntoLeftovers(store));

      test('a fresh listing prunes folders the server no longer has',
          () => _pruneToListing(store));

      test('an emoji in the name does not cut its subfolders short', () async {
        // SQLite counts an emoji as one character and Dart as two, and the
        // children's paths were cut by Dart's count.
        await store.upsertMessages('a', '\u{1F4C1}Bills', [_msg(1)]);
        await store.upsertMessages('a', '\u{1F4C1}Bills/2024', [_msg(2)]);
        await store.writeFolderState('a', '\u{1F4C1}Bills/2024',
            FolderSyncState(uidValidity: 1, lastSync: DateTime(2026)));

        await store.renameFolder('a', '\u{1F4C1}Bills', 'New');

        expect(await store.countMessages('a', 'New'), 1);
        expect(await store.countMessages('a', 'New/2024'), 1);
        expect(await store.readFolderState('a', 'New/2024'), isNotNull);
      });

      test('a folder differing only in case is left alone', () async {
        // LIKE ignores case: renaming 'Work' moved 'work/...' too, and
        // deleting it took that folder's cache.
        await store.upsertMessages('a', 'Work', [_msg(1)]);
        await store.upsertMessages('a', 'work/Notes', [_msg(2)]);

        await store.renameFolder('a', 'Work', 'Office');
        expect(await store.countMessages('a', 'work/Notes'), 1);

        await store.upsertMessages('a', 'Work', [_msg(1)]);
        await store.deleteFolder('a', 'Work');
        expect(await store.countMessages('a', 'work/Notes'), 1);
      });

      test('a preview arriving later is written over an empty one',
          () => _previewsMerge(store));

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
          2: (
            isRead: true,
            isFlagged: true,
            isAnswered: false,
            isForwarded: false,
          ),
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
