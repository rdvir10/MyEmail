import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/domain/mail_message.dart';

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
    if (file.existsSync()) file.deleteSync();
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

  /// A database as it stood at schema 2: everything the app had then, and
  /// none of what version 3 added.
  Future<void> buildVersion2() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
    // Roll it back to what a device on the previous release actually has.
    await db.customStatement('DROP TABLE IF EXISTS graph_ids');
    await db.customStatement('ALTER TABLE messages DROP COLUMN calendar');
    await db.customStatement('PRAGMA user_version = 2');
    await db.close();
  }

  /// A database as it stood at schema 3: Graph numbering, no invitations.
  Future<void> buildVersion3() async {
    final db = MailDatabase(NativeDatabase(file));
    await DriftCacheStore(db).upsertMessages('acct-1', 'INBOX', [message(11)]);
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
    await db.customStatement('PRAGMA user_version = 4');
    await db.close();
  }

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
