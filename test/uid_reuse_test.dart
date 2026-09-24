import 'package:drift/drift.dart' show InsertMode;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/domain/mail_message.dart';

/// A number, once spent, stays spent.
///
/// This is the bug that showed a Paylocity notice under the subject of an
/// invoice chase. The highest number handed out in a folder was read back as
/// `MAX(uid)` over the numbering table, and forgetting a message deleted its
/// row — so deleting the newest message in a folder, which is what anyone
/// does with mail they have just read, dropped the maximum by one and handed
/// that number straight to the next message to arrive. The cache row keyed on
/// it then held one message's header and another's body.
///
/// Against the real database on purpose. The in-memory stand-in keeps its own
/// counter and never had the fault, which is why every test passed while the
/// phone showed the wrong message.
void main() {
  late MailDatabase db;
  late DriftGraphIdMap ids;
  late DriftCacheStore cache;

  setUp(() {
    db = MailDatabase(NativeDatabase.memory());
    ids = DriftGraphIdMap(db);
    cache = DriftCacheStore(db);
  });

  tearDown(() => db.close());

  CachedMessage header(int uid, String subject, {String? messageId}) =>
      CachedMessage(
        uid: uid,
        subject: subject,
        from: const MailAddress(email: 'dana@example.com'),
        to: const [],
        date: DateTime(2026, 9, 22, 8),
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
        messageId: messageId,
      );

  group('numbering', () {
    test('a forgotten number is never handed out again', () async {
      final first = await ids.uidsFor('a', 'INBOX', ['g-1', 'g-2', 'g-3']);
      expect(first.values, containsAll(<int>[1, 2, 3]));

      // The newest is deleted, which is what a move to Trash does.
      await ids.forgetMoved('a', 'INBOX', [first['g-3']!]);
      final next = await ids.uidsFor('a', 'INBOX', ['g-4']);

      expect(next['g-4'], 4, reason: 'not 3, which message three had');
    });

    test('holds when the whole folder is emptied', () async {
      await ids.uidsFor('a', 'INBOX', ['g-1', 'g-2', 'g-3']);
      await ids.forgetMoved('a', 'INBOX', [1, 2, 3]);

      final next = await ids.uidsFor('a', 'INBOX', ['g-4']);

      expect(next['g-4'], 4);
      expect(await ids.highestUid('a', 'INBOX'), 4);
    });

    test('a spent number resolves to no message at all', () async {
      await ids.uidsFor('a', 'INBOX', ['g-1', 'g-2']);
      await ids.forgetMoved('a', 'INBOX', [2]);

      expect(await ids.remoteIdsFor('a', 'INBOX', [1, 2]), {1: 'g-1'});
    });

    test('forgetting does not pile up a row per deleted message', () async {
      await ids.uidsFor('a', 'INBOX', [for (var i = 1; i <= 20; i++) 'g-$i']);
      await ids.forgetMoved('a', 'INBOX', [for (var i = 1; i <= 19; i++) i]);

      final rows = await db.select(db.graphIds).get();

      // The live message, and one marker holding the count where it is.
      expect(rows, hasLength(lessThanOrEqualTo(2)));
      expect(await ids.highestUid('a', 'INBOX'), 20);
    });

    test('each folder counts on its own', () async {
      await ids.uidsFor('a', 'INBOX', ['g-1']);
      await ids.forgetMoved('a', 'INBOX', [1]);

      expect((await ids.uidsFor('a', 'Archive', ['g-2']))['g-2'], 1);
      expect((await ids.uidsFor('a', 'INBOX', ['g-3']))['g-3'], 2);
    });

    test('two syncs meeting one new message give it one number', () async {
      // A refresh and a load-more, or the app and the worker, both finding
      // it unnumbered. Each used to number it, and it showed twice.
      await ids.uidsFor('a', 'INBOX', ['g-1']);

      final both = await Future.wait([
        ids.uidsFor('a', 'INBOX', ['g-2']),
        ids.uidsFor('a', 'INBOX', ['g-2']),
      ]);

      expect(both[0]['g-2'], both[1]['g-2']);
      final rows = await (db.select(db.graphIds)
            ..where((t) => t.remoteId.equals('g-2')))
          .get();
      expect(rows, hasLength(1));
    });

    test('the database will not hold one message under two numbers',
        () async {
      // What a second connection writing at the same moment runs into.
      await ids.uidsFor('a', 'INBOX', ['g-1']);

      await db.into(db.graphIds).insert(
            GraphIdsCompanion.insert(
              accountId: 'a',
              path: 'INBOX',
              uid: 9,
              remoteId: 'g-1',
            ),
            mode: InsertMode.insertOrIgnore,
          );

      expect(await ids.remoteIdsFor('a', 'INBOX', [9]), isEmpty);
    });

    test('while spent numbers, all blank, may be several at once', () async {
      await ids.uidsFor('a', 'INBOX', ['g-1', 'g-2', 'g-3']);

      await ids.forgetMoved('a', 'INBOX', [2, 3]);

      expect(await ids.highestUid('a', 'INBOX'), 3);
    });

    test('a rename carries the numbering of an emoji-named folder', () async {
      // Cut by Dart's count of the name, which is one more than SQLite's.
      await ids.uidsFor('a', '\u{1F4C1}Bills/2024', ['g-1']);

      await ids.renameFolder('a', '\u{1F4C1}Bills', 'New');

      expect(await ids.remoteIdsFor('a', 'New/2024', [1]), {1: 'g-1'});
    });

    test('and leaves a folder differing only in case alone', () async {
      await ids.uidsFor('a', 'Work', ['g-1']);
      await ids.uidsFor('a', 'work/Notes', ['g-2']);

      await ids.renameFolder('a', 'Work', 'Office');

      expect(await ids.remoteIdsFor('a', 'work/Notes', [1]), {1: 'g-2'});
    });
  });

  group('a number that changed hands', () {
    test('does not keep the old message body under the new header', () async {
      // The belt to the braces above: whatever lets a number change hands,
      // the body that was cached under it is not this message's body.
      await cache.upsertMessages('a', 'INBOX', [
        header(7, 'Outstanding invoices', messageId: '<invoice@example.com>'),
      ]);
      await cache.writeBody('a', 'INBOX', 7,
          text: 'Please settle the attached.',
          html: '<p>Please settle the attached.</p>',
          preview: 'Please settle the attached.');

      await cache.upsertMessages('a', 'INBOX', [
        header(7, 'Time off request', messageId: '<paylocity@example.com>'),
      ]);

      final row = (await cache.readMessages('a', 'INBOX')).single;
      expect(row.subject, 'Time off request');
      expect(row.bodyText, isNull, reason: 'the old body went with the header');
      expect(row.preview, isEmpty);
    });

    test('the same message re-read keeps the body it already had', () async {
      // The whole reason the upsert keeps bodies: a sync re-reads headers
      // constantly and must not make every message fetch its body again.
      await cache.upsertMessages('a', 'INBOX', [
        header(7, 'Outstanding invoices', messageId: '<invoice@example.com>'),
      ]);
      await cache.writeBody('a', 'INBOX', 7,
          text: 'Please settle the attached.', preview: 'Please settle');

      await cache.upsertMessages('a', 'INBOX', [
        header(7, 'RE: Outstanding invoices',
            messageId: '<invoice@example.com>'),
      ]);

      final row = (await cache.readMessages('a', 'INBOX')).single;
      expect(row.subject, 'RE: Outstanding invoices');
      expect(row.bodyText, 'Please settle the attached.');
    });

    test('a header with no Message-ID leaves the body alone', () async {
      // Plenty of mail has none, and throwing away good bodies on a guess
      // would cost a fetch per message for nothing.
      await cache.upsertMessages('a', 'INBOX', [header(7, 'First')]);
      await cache.writeBody('a', 'INBOX', 7, text: 'Body', preview: 'Body');

      await cache.upsertMessages('a', 'INBOX', [header(7, 'Second')]);

      expect((await cache.readMessages('a', 'INBOX')).single.bodyText, 'Body');
    });
  });
}
