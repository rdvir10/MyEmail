import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/mail_database.dart';

/// The mail cache opened from two places at once, as the app and the sync
/// worker do. With SQLite's defaults the second writer failed at once with
/// "database is locked".
void main() {
  late File file;

  setUp(() {
    file = File(
      '${Directory.systemTemp.path}/myemail-locking-'
      '${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
  });

  tearDown(() {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('${file.path}$suffix');
      if (f.existsSync()) f.deleteSync();
    }
  });

  MessagesCompanion row(int uid) => MessagesCompanion.insert(
        accountId: 'a',
        path: 'INBOX',
        uid: uid,
        subject: 'M$uid',
        fromEmail: 'dana@example.com',
        recipientsJson: '[]',
        date: DateTime.utc(2026, 9, 23),
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
      );

  test('a write waits for another rather than failing', () async {
    final app = MailDatabase(
      NativeDatabase(file, setup: MailDatabase.configureConnection),
    );
    final worker = MailDatabase(
      NativeDatabase.createInBackground(
        file,
        setup: MailDatabase.configureConnection,
      ),
    );
    addTearDown(() async {
      await app.close();
      await worker.close();
    });
    await app.into(app.messages).insert(row(1)); // creates the tables

    final holding = app.transaction(() async {
      await app.into(app.messages).insert(row(2));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // The worker's write lands while the app's transaction still holds the
    // lock, and waits for it.
    await worker.into(worker.messages).insert(row(3));
    await holding;

    final uids = await (app.select(app.messages)
          ..orderBy([(m) => OrderingTerm.asc(m.uid)]))
        .map((m) => m.uid)
        .get();
    expect(uids, [1, 2, 3]);
  });

  test('and the log lets reading go on meanwhile', () async {
    final db = MailDatabase(
      NativeDatabase(file, setup: MailDatabase.configureConnection),
    );
    addTearDown(db.close);

    final mode = await db.customSelect('PRAGMA journal_mode').getSingle();
    final wait = await db.customSelect('PRAGMA busy_timeout').getSingle();

    expect(mode.data.values.single, 'wal');
    expect(wait.data.values.single, 5000);
  });
}
