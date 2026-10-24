import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_sort.dart';
import 'package:myemail/ui/messages/list_groups.dart';

import 'fakes/fake_imap_transport.dart';

/// Importance: the red ! on mail marked high, the blue arrow on mail marked
/// low, and the list arranged by it.
void main() {
  CachedMessage cached(int uid, {Importance? importance}) => CachedMessage(
        uid: uid,
        subject: 'S $uid',
        from: const MailAddress(email: 'x@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime(2026, 10, 1).add(Duration(hours: uid)),
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
        importance: importance,
      );

  group('the cache', () {
    Future<void> kept(CacheStore store) async {
      await store.upsertMessages('a', 'INBOX', [
        cached(1, importance: Importance.high),
        cached(2),
      ]);
      // An IMAP header read again says nothing of it.
      await store.upsertMessages('a', 'INBOX', [cached(1)]);
      expect((await store.readMessage('a', 'INBOX', 1))!.importance,
          Importance.high);
      final rows = await store.readSyncRows('a', 'INBOX');
      expect({for (final r in rows) r.uid: r.needsImportance},
          {1: false, 2: true});

      await store.updateImportance('a', 'INBOX', {2: Importance.low});
      final message = (await store.readMessage('a', 'INBOX', 2))!
          .toMailMessage(accountId: 'a', folderId: 'a:INBOX');
      expect(message.importance, Importance.low);
      expect(
        (await store.readSyncRows('a', 'INBOX')).any((r) => r.needsImportance),
        isFalse,
      );
    }

    test('in memory', () => kept(MemoryCacheStore()));

    test('in the database', () async {
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await kept(DriftCacheStore(db));
    });

    test('a row not yet asked about reads as normal', () async {
      final store = MemoryCacheStore();
      await store.upsertMessages('a', 'INBOX', [cached(1)]);
      final message = (await store.readMessage('a', 'INBOX', 1))!
          .toMailMessage(accountId: 'a', folderId: 'a:INBOX');
      expect(message.importance, Importance.normal);
    });
  });

  group('the sync', () {
    test('asks how important new mail is where the header did not say, once',
        () async {
      final server = FakeImapTransport();
      final store = MemoryCacheStore();
      final sync = FolderSync(transport: server, store: store, accountId: 'a');
      final inbox = server.folder('INBOX');
      final urgent = inbox.deliver()..importance = null;
      inbox.deliver().importance = null;
      server.importanceAnswers[urgent.uid] = Importance.high;

      await sync.sync('INBOX');

      expect((await store.readMessage('a', 'INBOX', urgent.uid))!.importance,
          Importance.high);
      expect((await store.readMessage('a', 'INBOX', 2))!.importance,
          Importance.normal);
      expect(server.calls.where((c) => c.endsWith('IMPORTANCE')), hasLength(1));

      server.calls.clear();
      await sync.sync('INBOX');
      expect(server.calls.where((c) => c.endsWith('IMPORTANCE')), isEmpty);
    });
  });

  group('arranged by it', () {
    MailMessage m(int uid, Importance importance) => MailMessage(
          id: 'a:INBOX#$uid',
          accountId: 'a',
          folderId: 'a:INBOX',
          uid: uid,
          subject: 'S',
          from: const MailAddress(email: 'x@example.com'),
          to: const [],
          date: DateTime(2026, 10, uid),
          preview: '',
          importance: importance,
        );

    test('high first, then normal, then low, each newest first', () {
      final sorted = sortMessages([
        m(1, Importance.low),
        m(2, Importance.normal),
        m(3, Importance.high),
        m(4, Importance.normal),
      ], MessageSort.importance);
      expect(sorted.map((x) => x.uid), [3, 4, 2, 1]);
      expect(MessageSort.importance.hasBars, isTrue);
    });

    test('with a bar over each', () {
      expect(
        listGroupOf(m(1, Importance.high), MessageSort.importance)!.label,
        'High importance',
      );
      expect(
        listGroupOf(m(1, Importance.low), MessageSort.importance)!.label,
        'Low importance',
      );
    });
  });
}
