import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'fakes/fake_imap_transport.dart';

/// Upgrading the database that is already on someone's device.
///
/// Every other test opens a fresh database, which runs createAll and never
/// touches the migration. That is the wrong half to cover: a bad createAll
/// fails on the first run and is obvious, while a bad migration fails only
/// for people who already had the app — everyone, in other words — and takes
/// the cache for every account with it, whichever provider they use.
void main() {
  late File file;

  setUp(() {
    file = File(
      '${Directory.systemTemp.path}/myemail-migration-'
      '${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
  });

  tearDown(() {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('${file.path}$suffix');
      if (f.existsSync()) f.deleteSync();
    }
  });

  CachedMessage message(int uid) => CachedMessage(
        uid: uid,
        subject: 'Cached before the upgrade',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime.utc(2026, 9, 1),
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
        bodyHtml: '<p>A body worth keeping</p>',
      );

  // Each fixture is today's database with everything later versions added
  // taken back out, so the upgrade has real work to do. They used to keep
  // schema 6's columns, so its step never ran: it could have been deleted
  // and every test here would still have passed, while every device
  // upgrading from 2.35 or earlier failed on every cache read.

  /// What schema 9 added: whether a message was replied to or forwarded.
  Future<void> dropSchema9(MailDatabase db) async {
    for (final column in ['is_answered', 'is_forwarded']) {
      await db.customStatement('ALTER TABLE messages DROP COLUMN $column');
    }
  }

  /// What schema 8 added: when a message arrived, whether a folder's
  /// previews were asked for, and one number per Graph message. And the
  /// lookup index, which a database created at schema 3 or later never had.
  /// And everything after it.
  Future<void> dropSchema8(MailDatabase db) async {
    await dropSchema9(db);
    await db.customStatement('ALTER TABLE messages DROP COLUMN arrived');
    await db.customStatement(
      'ALTER TABLE folder_states DROP COLUMN previews_checked',
    );
    await db.customStatement('DROP INDEX IF EXISTS graph_ids_one_per_remote');
    await db.customStatement('DROP INDEX IF EXISTS graph_ids_by_remote');
  }

  /// What schema 7 added: Reply-To. And everything after it.
  Future<void> dropSchema7(MailDatabase db) async {
    await dropSchema8(db);
    await db.customStatement('ALTER TABLE messages DROP COLUMN reply_to_json');
  }

  /// What schema 6 added: who else a message went to, what its files weigh,
  /// and whether it is a meeting request. And everything after it.
  Future<void> dropSchema6(MailDatabase db) async {
    await dropSchema7(db);
    for (final column in ['copied_json', 'attachment_bytes', 'is_meeting']) {
      await db.customStatement('ALTER TABLE messages DROP COLUMN $column');
    }
  }

  /// A database as it stood at schema 1: before threading headers.
  Future<void> buildVersion1() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    await dropSchema6(db);
    await db.customStatement('DROP TABLE IF EXISTS graph_ids');
    for (final column in ['calendar', 'message_id', 'in_reply_to']) {
      await db.customStatement('ALTER TABLE messages DROP COLUMN $column');
    }
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();
  }

  /// A database as it stood at schema 2: everything the app had then, and
  /// none of what version 3 added.
  Future<void> buildVersion2() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    // Roll it back to what a device on the previous release actually has.
    await dropSchema6(db);
    await db.customStatement('DROP TABLE IF EXISTS graph_ids');
    await db.customStatement('ALTER TABLE messages DROP COLUMN calendar');
    await db.customStatement('PRAGMA user_version = 2');
    await db.close();
  }

  /// A database as it stood at schema 3: Graph numbering, no invitations.
  Future<void> buildVersion3() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    await dropSchema6(db);
    await db.customStatement('ALTER TABLE messages DROP COLUMN calendar');
    await db.customStatement('PRAGMA user_version = 3');
    await db.close();
  }

  /// A database as it stood at schema 4, with or without a Microsoft
  /// account having ever numbered anything in it.
  Future<void> buildVersion4({required bool withGraph}) async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    if (withGraph) {
      await DriftGraphIdMap(db).uidsFor('acct-1', 'INBOX', ['g-11']);
    }
    await dropSchema6(db);
    await db.customStatement('PRAGMA user_version = 4');
    await db.close();
  }

  /// A database as it stood at schema 5, the one most devices upgrade from.
  Future<void> buildVersion5() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    await dropSchema6(db);
    await db.customStatement('PRAGMA user_version = 5');
    await db.close();
  }

  /// A database as it stood at schema 7, the one every device upgrades from:
  /// created at 3 or later, so without the Graph lookup index, and with a
  /// message two syncs numbered twice.
  Future<void> buildVersion7() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    await DriftCacheStore(db).writeFolderState('acct-1', 'INBOX',
        FolderSyncState(uidValidity: 1, lastSync: DateTime.utc(2026, 9, 1)));
    await dropSchema8(db);
    for (final (uid, remoteId) in [
      (1, 'g-1'),
      (2, 'g-2'),
      (3, 'g-2'), // the same message, numbered again
      (4, ''), // spent
      (5, ''),
    ]) {
      await db.customStatement(
        'INSERT INTO graph_ids (account_id, path, uid, remote_id) '
        "VALUES ('acct-1', 'Work', ?, ?)",
        [uid, remoteId],
      );
    }
    await db.customStatement('PRAGMA user_version = 7');
    await db.close();
  }

  /// A database as it stood at schema 8, the release before this one: a
  /// Gmail Inbox synced with CONDSTORE, so its place in the folder is
  /// recorded, and a message cached before replies were read.
  Future<void> buildVersion8() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    await DriftCacheStore(db).writeFolderState(
      'acct-1',
      'INBOX',
      FolderSyncState(
        uidValidity: 1000,
        uidNext: 12,
        highestModSeq: 2,
        lastSync: DateTime.utc(2026, 9, 1),
      ),
    );
    await dropSchema9(db);
    await db.customStatement('PRAGMA user_version = 8');
    await db.close();
  }

  /// A database as it stood at schema 6.
  Future<void> buildVersion6() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    await dropSchema7(db);
    await db.customStatement('PRAGMA user_version = 6');
    await db.close();
  }

  Future<Set<String>> indexes(MailDatabase db) async => {
        for (final row in await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .get())
          row.read<String>('name'),
      };

  test('a version 8 database gains replied and forwarded, and keeps its rows',
      () async {
    await buildVersion8();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    final cached = (await store.readMessages('acct-1', 'INBOX')).single;

    expect(cached.bodyHtml, '<p>A body worth keeping</p>');
    expect(cached.isAnswered, isFalse, reason: 'cached before it was read');
    expect(cached.isForwarded, isFalse);

    await store.updateFlags('acct-1', 'INBOX', {
      11: (
        isRead: true,
        isFlagged: false,
        isAnswered: true,
        isForwarded: true,
      ),
    });
    final after = await store.readMessage('acct-1', 'INBOX', 11);
    expect(after!.isAnswered, isTrue);
    expect(after.isForwarded, isTrue);
    expect(after.bodyHtml, '<p>A body worth keeping</p>');
  });

  test('a reply made before the update shows once its folder syncs',
      () async {
    // Gmail's sync asks only for flags changed since the last (CONDSTORE),
    // and a message answered before the update has not changed since, so
    // its mark would never have been read. The upgrade drops each folder's
    // place instead: its next sync reads every flag, once.
    await buildVersion8();
    final server = FakeImapTransport();
    final inbox = server.folder('INBOX')..nextUid = 11;
    inbox.deliver(subject: 'Cached before the upgrade').isAnswered = true;
    expect(inbox.highestModSeq, 2, reason: 'where the device last left it');

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    final sync =
        FolderSync(transport: server, store: store, accountId: 'acct-1');
    Iterable<String> sinceCalls() =>
        server.calls.where((c) => c.contains('CHANGEDSINCE'));

    await sync.sync('INBOX');

    final row = await store.readMessage('acct-1', 'INBOX', 11);
    expect(row!.isAnswered, isTrue);
    expect(sinceCalls(), isEmpty, reason: 'every flag in the window');

    await sync.sync('INBOX');
    expect(sinceCalls(), hasLength(1),
        reason: 'once: after it, only what changed');
  });

  test('a version 7 database gains the schema 8 columns and keeps its rows',
      () async {
    await buildVersion7();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    final cached = await store.readMessages('acct-1', 'INBOX');

    expect(cached.single.bodyHtml, '<p>A body worth keeping</p>');
    expect(cached.single.arrived, isNull, reason: 'cached before it was read');
    final state = await store.readFolderState('acct-1', 'INBOX');
    expect(state!.previewsChecked, isFalse,
        reason: 'asked about once more after the update');

    final arrived = DateTime.utc(2026, 9, 2, 9).toLocal();
    await store.upsertMessages('acct-1', 'INBOX', [
      CachedMessage(
        uid: 12,
        subject: 'Arrived late',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [],
        date: DateTime.utc(2026, 9, 1),
        arrived: arrived,
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
      ),
    ]);
    expect((await store.readMessage('acct-1', 'INBOX', 12))!.arrived, arrived);
  });

  test('a version 7 database gains the Graph lookup index', () async {
    // Made only by the step up from schema 2, so a database created at 3 or
    // later, which is any reinstall, scanned the table on every lookup.
    await buildVersion7();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await indexes(db),
        containsAll(['graph_ids_by_remote', 'graph_ids_one_per_remote']));
  });

  test('a message numbered twice keeps its first number', () async {
    await buildVersion7();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final ids = DriftGraphIdMap(db);

    expect(await ids.remoteIdsFor('acct-1', 'Work', [1, 2, 3]),
        {1: 'g-1', 2: 'g-2'});
    expect((await ids.uidsFor('acct-1', 'Work', ['g-2']))['g-2'], 2);
    expect(await ids.highestUid('acct-1', 'Work'), 5,
        reason: 'the second number is spent, not handed back');
    expect((await ids.uidsFor('acct-1', 'Work', ['g-3']))['g-3'], 6);
  });

  test('two connections opening an old database at once both come up',
      () async {
    // The app and a background job, on the first launch after an update.
    // Both ran the upgrade; the second failed on a column the first had
    // just added, and drift kept the error, so every cache read on that
    // connection failed until the process was killed. A few rounds, since
    // it is a race.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
    for (var round = 0; round < 5; round++) {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('${file.path}$suffix');
        if (f.existsSync()) f.deleteSync();
      }
      await buildVersion1();
      // As the file is on a device since 2.43.0.
      sqlite3.open(file.path)
        ..execute('PRAGMA journal_mode = WAL')
        ..close();

      MailDatabase open() => MailDatabase(NativeDatabase.createInBackground(
            file,
            setup: MailDatabase.configureConnection,
          ));
      final app = open();
      final worker = open();
      try {
        final both = await Future.wait([
          DriftCacheStore(app).readMessages('acct-1', 'INBOX'),
          DriftCacheStore(worker).readMessages('acct-1', 'INBOX'),
        ]);
        expect(both[0].single.bodyHtml, '<p>A body worth keeping</p>');
        expect(both[1].single.bodyHtml, '<p>A body worth keeping</p>');
      } finally {
        await app.close();
        await worker.close();
      }
    }
  });

  test('a version 6 database gains Reply-To and keeps its rows', () async {
    await buildVersion6();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    final cached = await store.readMessages('acct-1', 'INBOX');

    expect(cached.single.bodyHtml, '<p>A body worth keeping</p>');
    expect(cached.single.replyTo, isEmpty,
        reason: 'cached before Reply-To was kept, so a reply goes to From');

    await store.upsertMessages('acct-1', 'INBOX', [
      CachedMessage(
        uid: 12,
        subject: 'Your ticket',
        from: const MailAddress(email: 'noreply@vendor.example'),
        to: const [MailAddress(email: 'me@example.com')],
        replyTo: const [MailAddress(email: 'ticket-4411@vendor.example')],
        date: DateTime.utc(2026, 9, 2),
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
      ),
    ]);
    final after = await store.readMessage('acct-1', 'INBOX', 12);
    expect(after!.replyTo.single.email, 'ticket-4411@vendor.example');
  });

  test('a version 5 database gains the schema 6 columns and keeps its rows',
      () async {
    await buildVersion5();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    final cached = await store.readMessages('acct-1', 'INBOX');

    expect(cached, hasLength(1));
    expect(cached.single.bodyHtml, '<p>A body worth keeping</p>');
    expect(cached.single.cc, isEmpty, reason: 'cached before Cc was kept');
    expect(cached.single.attachmentBytes, 0);
    expect(cached.single.isMeeting, isFalse);

    // And the new columns take what a sync writes.
    await store.upsertMessages('acct-1', 'INBOX', [
      CachedMessage(
        uid: 12,
        subject: 'After the upgrade',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        cc: const [MailAddress(email: 'sam@example.com')],
        date: DateTime.utc(2026, 9, 2),
        isRead: false,
        isFlagged: false,
        hasAttachments: true,
        attachmentBytes: 2048,
        isMeeting: true,
      ),
    ]);
    final after = await store.readMessage('acct-1', 'INBOX', 12);
    expect(after!.cc.single.email, 'sam@example.com');
    expect(after.attachmentBytes, 2048);
    expect(after.isMeeting, isTrue);
  });

  test('a version 1 database comes all the way up and keeps its rows',
      () async {
    // Every step, from before the threading headers.
    await buildVersion1();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final cached = await DriftCacheStore(db).readMessages('acct-1', 'INBOX');

    expect(cached.single.subject, 'Cached before the upgrade');
    expect(cached.single.bodyHtml, '<p>A body worth keeping</p>');
    expect(cached.single.messageId, isNull);
  });

  test('a Microsoft account gives up its cached bodies once', () async {
    // Until version 5 a deleted message's number could be handed out again,
    // and the row keyed on it kept the old body under the new header. There
    // is no telling afterwards which rows those are, so they all go and come
    // back as messages are opened. Headers stay, so no list changes.
    await buildVersion4(withGraph: true);

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final cached = await DriftCacheStore(db).readMessages('acct-1', 'INBOX');

    expect(cached, hasLength(1));
    expect(cached.single.subject, 'Cached before the upgrade');
    expect(cached.single.bodyHtml, isNull);
  });

  test('a Gmail account keeps every body it had', () async {
    // IMAP hands out its own UIDs and never reuses one inside a UIDVALIDITY,
    // so Gmail was never at risk and must not pay for the repair.
    await buildVersion4(withGraph: false);

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final cached = await DriftCacheStore(db).readMessages('acct-1', 'INBOX');

    expect(cached.single.bodyHtml, '<p>A body worth keeping</p>');
  });

  test('a version 3 database gains the calendar column and keeps its rows',
      () async {
    await buildVersion3();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    final cached = await store.readMessages('acct-1', 'INBOX');
    expect(cached.single.bodyHtml, '<p>A body worth keeping</p>');
    expect(cached.single.calendar, isNull, reason: 'cached before invitations');

    await store.writeBody('acct-1', 'INBOX', 11,
        text: 'x', calendar: 'BEGIN:VCALENDAR', preview: 'x');
    final again = await store.readMessage('acct-1', 'INBOX', 11);
    expect(again!.calendar, 'BEGIN:VCALENDAR');
  });

  test('a version 2 database upgrades without losing anything', () async {
    await buildVersion2();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final cached = await DriftCacheStore(db).readMessages('acct-1', 'INBOX');

    expect(cached, hasLength(1));
    expect(cached.single.subject, 'Cached before the upgrade');
    expect(
      cached.single.bodyHtml,
      '<p>A body worth keeping</p>',
      reason: 'a migration that drops bodies makes every account redownload '
          'its mail, whichever provider it uses',
    );
  });

  test('the upgraded database can number Graph messages', () async {
    // The table the upgrade exists to add. Created but unusable would fail
    // only once a Microsoft account synced.
    await buildVersion2();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final ids = DriftGraphIdMap(db);

    final assigned = await ids.uidsFor('acct-1', 'INBOX', ['g-1', 'g-2']);

    expect(assigned, hasLength(2));
    expect(assigned['g-1']!, lessThan(assigned['g-2']!));
  });

  test('reopening an already upgraded database changes nothing', () async {
    // The migration must be idempotent in the sense that matters: opening
    // again must not re-run it and fail on a table that is already there.
    await buildVersion2();

    final first = MailDatabase(NativeDatabase(file));
    await DriftGraphIdMap(first).uidsFor('acct-1', 'INBOX', ['g-1']);
    await first.close();

    final second = MailDatabase(NativeDatabase(file));
    addTearDown(second.close);
    final again = await DriftGraphIdMap(second)
        .uidsFor('acct-1', 'INBOX', ['g-1', 'g-2']);

    expect(again['g-1'], 1, reason: 'a number already handed out must stand');
    expect(again['g-2'], 2);
  });

  test('a brand new database has the table too', () async {
    // createAll and the migration are two separate paths to the same schema,
    // and it is easy to add a table to one and forget the other.
    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final assigned = await DriftGraphIdMap(db).uidsFor('a', 'INBOX', ['g-1']);

    expect(assigned['g-1'], 1);
  });

  test('and its indexes, which createAll does not know about', () async {
    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await indexes(db),
        containsAll(['graph_ids_by_remote', 'graph_ids_one_per_remote']));
  });

  test('a Gmail account still reads its cache after the upgrade', () async {
    // The question this test exists to answer: the schema moved for a
    // Microsoft feature, and nothing about that may touch an account that
    // has never been near Graph.
    await buildVersion2();

    final db = MailDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = DriftCacheStore(db);
    await store.upsertMessages('gmail-acct', 'INBOX', [message(12)]);

    final cached = await store.readMessages('gmail-acct', 'INBOX');

    expect(cached.single.uid, 12);
  });
}
