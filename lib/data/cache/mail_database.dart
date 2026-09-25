import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import '../../domain/mail_message.dart';
import 'cache_store.dart';

part 'mail_database.g.dart';

/// Per-folder sync bookkeeping. See [FolderSyncState].
@DataClassName('FolderStateRow')
class FolderStates extends Table {
  TextColumn get accountId => text()();
  TextColumn get path => text()();
  IntColumn get uidValidity => integer()();
  IntColumn get uidNext => integer().nullable()();
  IntColumn get highestModSeq => integer().nullable()();
  DateTimeColumn get lastSync => dateTime()();

  /// Whether the cached rows' previews have been asked of the server. See
  /// [FolderSyncState.previewsChecked]. Added in schema 8; false on folders
  /// synced before, which asks once more and then never again.
  BoolColumn get previewsChecked =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {accountId, path};
}

/// Cached message headers, plus the body once it has been opened.
@DataClassName('MessageRow')
class Messages extends Table {
  TextColumn get accountId => text()();
  TextColumn get path => text()();
  IntColumn get uid => integer()();
  TextColumn get subject => text()();
  TextColumn get fromEmail => text()();
  TextColumn get fromName => text().nullable()();

  /// JSON list of `{"email": ..., "name": ...}`.
  TextColumn get recipientsJson => text()();

  /// The same, for everyone copied openly. Added in schema 6; null on rows
  /// cached before, which read as nobody copied until the folder syncs.
  TextColumn get copiedJson => text().nullable()();

  /// The same, for Reply-To where it names someone besides the sender.
  /// Added in schema 7; null on rows cached before, and on most messages.
  TextColumn get replyToJson => text().nullable()();
  DateTimeColumn get date => dateTime()();

  /// When the server took the message in. See [CachedMessage.arrived].
  /// Added in schema 8; null on rows cached before, and on Microsoft rows,
  /// whose [date] is already the arrival.
  DateTimeColumn get arrived => dateTime().nullable()();
  BoolColumn get isRead => boolean()();
  BoolColumn get isFlagged => boolean()();
  BoolColumn get hasAttachments => boolean()();
  TextColumn get preview => text().withDefault(const Constant(''))();

  /// What the files on it add up to. Added in schema 6, 0 where unknown.
  IntColumn get attachmentBytes =>
      integer().withDefault(const Constant(0))();

  /// An invitation, a change to one, or a cancellation. Added in schema 6;
  /// false on rows cached before, until that folder next syncs.
  BoolColumn get isMeeting => boolean().withDefault(const Constant(false))();

  /// Whether it was replied to, and whether forwarded. Added in schema 9;
  /// false on rows cached before, until that folder next syncs.
  BoolColumn get isAnswered => boolean().withDefault(const Constant(false))();
  BoolColumn get isForwarded => boolean().withDefault(const Constant(false))();
  TextColumn get bodyText => text().nullable()();
  TextColumn get bodyHtml => text().nullable()();

  /// The invitation inside the message (iCalendar text), added in schema
  /// 4. Null on rows cached before, and on every message with none.
  TextColumn get calendar => text().nullable()();

  /// Threading, added in schema 2. Nullable because plenty of real mail has
  /// no `Message-ID`, and because every row cached before schema 2 has
  /// neither until the folder is next synced.
  TextColumn get messageId => text().nullable()();
  TextColumn get inReplyTo => text().nullable()();

  @override
  Set<Column> get primaryKey => {accountId, path, uid};
}

/// What a Graph message id is called locally.
///
/// Graph has no equivalent of an IMAP UID: its message ids are long opaque
/// strings, and everything above the transport — the cache, the sync, the
/// notification watermarks — is keyed on an integer that only ever goes up.
/// Rather than reshape all of that, each Graph message is given a number the
/// first time it is seen, and this table remembers which is which.
///
/// The numbers are handed out in the order messages are seen, which is the
/// same rule IMAP uses for UIDs, so "a higher number is a message that
/// arrived later" holds and the sync's arithmetic keeps working unchanged.
///
/// Rows are per folder, because a message moved between folders is a new
/// message to Graph and gets a new id.
@DataClassName('GraphIdRow')
class GraphIds extends Table {
  TextColumn get accountId => text()();
  TextColumn get path => text()();
  IntColumn get uid => integer()();
  TextColumn get remoteId => text()();

  @override
  Set<Column> get primaryKey => {accountId, path, uid};
}

@DriftDatabase(tables: [FolderStates, Messages, GraphIds])
class MailDatabase extends _$MailDatabase {
  MailDatabase(super.executor);

  /// The on-device database, in the app's documents directory.
  /// Still 'mailtree' after the rename to MyEmail: this is the filename on
  /// disk, and changing it orphans every cached message and body for a
  /// resync nobody asked for. Invisible either way.
  MailDatabase.open()
      : super(driftDatabase(
          name: 'mailtree',
          native: const DriftNativeOptions(setup: configureConnection),
        ));

  /// How every connection to the file is set up.
  ///
  /// Four things open it at once — the app, the sync worker, the job that
  /// carries out notification buttons, and the app's own drain of those —
  /// each in its own engine, so drift cannot share one connection between
  /// them. With SQLite's defaults a write that met another failed at once
  /// with "database is locked": a delete from a notification reported as
  /// failed after it had moved the message, a sync pass that gave up. Now a
  /// connection waits up to five seconds for the other, and the
  /// write-ahead log lets reading go on while one writes.
  static void configureConnection(CommonDatabase db) {
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA journal_mode = WAL;');
  }

  /// The lookup the transport does most: a Graph id in hand, wanting the
  /// number it was given. Without this it is a table scan per message, on
  /// every page of every folder.
  ///
  /// Not something drift's createAll knows about, so [migration] creates it
  /// by name. It used to be made only by the step up from schema 2, and a
  /// database created at 3 or later, which is any reinstall, never had it.
  Index get graphIdByRemote => Index(
        'graph_ids_by_remote',
        'CREATE INDEX IF NOT EXISTS graph_ids_by_remote ON graph_ids '
            '(account_id, path, remote_id)',
      );

  /// One number per Graph message in a folder.
  ///
  /// Two syncs of one folder at once, the app's and the worker's, could
  /// each find a new message unnumbered and each give it a number, and the
  /// message then showed twice. With this the second insert is ignored and
  /// both read back the first number. Spent numbers are left out: several
  /// read as the blank marker for a moment while they are swept up.
  Index get graphIdOnePerRemote => Index(
        'graph_ids_one_per_remote',
        'CREATE UNIQUE INDEX IF NOT EXISTS graph_ids_one_per_remote '
            "ON graph_ids (account_id, path, remote_id) WHERE remote_id <> ''",
      );

  @override
  int get schemaVersion => 9;

  /// Adding a column must not cost the user their cache.
  ///
  /// Drift's default for a version bump with no strategy is to do nothing,
  /// and the app then queries columns the table does not have. Adding them in
  /// place keeps every cached message and body; the new columns stay null
  /// on old rows until that folder is next synced, which is exactly what the
  /// nullable declarations above are for.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await m.createIndex(graphIdByRemote);
          await m.createIndex(graphIdOnePerRemote);
        },
        onUpgrade: (m, from, to) async {
          // All of it or none, and one connection at a time.
          //
          // The app and a background job can open the file together on the
          // first launch after an update, and both used to run the upgrade.
          // The second failed on a column the first had just added, and
          // drift keeps that error: every cache read on that connection
          // failed until the process died. IMMEDIATE takes the write lock
          // before anything is read, so the second waits for the first to
          // finish, then finds the version already moved on and does
          // nothing. It also means an upgrade cut short leaves the database
          // as it was, not half way.
          await customStatement('BEGIN IMMEDIATE');
          try {
            final row = await customSelect('PRAGMA user_version').getSingle();
            final current = row.read<int>('user_version');
            if (current < to) {
              await _upgrade(m, current);
              // Inside the transaction, so the version and the work behind
              // it land together. Drift writes it again afterwards.
              await customStatement('PRAGMA user_version = $to');
            }
            await customStatement('COMMIT');
          } catch (_) {
            await customStatement('ROLLBACK');
            rethrow;
          }
        },
      );

  Future<void> _upgrade(Migrator m, int from) async {
    if (from < 2) {
      await _addColumnIfMissing(m, messages, messages.messageId);
      await _addColumnIfMissing(m, messages, messages.inReplyTo);
    }
    if (from < 3) {
      // New in schema 3, for Microsoft accounts. Creating it empty
      // costs nothing: a Gmail account never writes to it, and a
      // Microsoft one fills it as it syncs.
      await m.createTable(graphIds);
    }
    if (from < 4) {
      // Invitations. A body cached before this has no calendar
      // column; opening such a message shows it without the card
      // until the body is fetched again.
      await _addColumnIfMissing(m, messages, messages.calendar);
    }
    if (from < 6) {
      // Who else a message went to, and what its files weigh. Both
      // are read with the header, so every folder fills them in on
      // its next sync; until then a message reads as copied to
      // nobody and its files as weighing nothing, which is what the
      // nullable and the default are for.
      await _addColumnIfMissing(m, messages, messages.copiedJson);
      await _addColumnIfMissing(m, messages, messages.attachmentBytes);
      await _addColumnIfMissing(m, messages, messages.isMeeting);
    }
    if (from < 7) {
      // Reply-To, read with the header like the rest. A message
      // cached before answers its From until its folder syncs again.
      await _addColumnIfMissing(m, messages, messages.replyToJson);
    }
    if (from < 8) {
      // When a Gmail message arrived, and whether a folder's previews
      // have been asked for. Both fill in as folders sync.
      await _addColumnIfMissing(m, messages, messages.arrived);
      await _addColumnIfMissing(m, folderStates, folderStates.previewsChecked);
      // The lookup index, for every database created at schema 3 or
      // later, which never had it.
      await m.createIndex(graphIdByRemote);
      // A message two syncs numbered twice keeps its first number. The
      // later one is spent rather than deleted, so the count never
      // moves back; its cache row goes at the next sync, as gone.
      await customStatement(
        "UPDATE graph_ids SET remote_id = '' WHERE remote_id <> '' "
        'AND EXISTS (SELECT 1 FROM graph_ids g WHERE '
        'g.account_id = graph_ids.account_id AND g.path = graph_ids.path '
        'AND g.remote_id = graph_ids.remote_id AND g.uid < graph_ids.uid)',
      );
      await m.createIndex(graphIdOnePerRemote);
    }
    if (from < 9) {
      // Whether a message was replied to or forwarded, read with its
      // flags. A sync where the server has CONDSTORE (Gmail) asks only for
      // what changed since the last, which a reply made before the update
      // did not, so it would never show. Each folder's place is dropped
      // instead, and its next sync reads every flag in its window, once.
      await _addColumnIfMissing(m, messages, messages.isAnswered);
      await _addColumnIfMissing(m, messages, messages.isForwarded);
      await customStatement('UPDATE folder_states SET highest_mod_seq = NULL');
    }
    if (from < 5) {
      // Throwing away every cached body on a Microsoft account, once.
      //
      // Until now a deleted message's number could be handed out again
      // to the next message to arrive, and the cache row keyed on that
      // number kept the old body under the new header. There is no way
      // to tell afterwards which rows those are: the header that
      // overwrote the old one also overwrote the Message-ID that would
      // have given it away. So the bodies go, and each comes back the
      // next time that message is opened. Headers, flags and previews
      // stay, so nothing visible in a list changes.
      //
      // Only folders with Graph numbering, which is what
      // [GraphIds] holds. IMAP hands out its own UIDs and never reuses
      // one inside a UIDVALIDITY, so a Gmail account was never at risk
      // and keeps every body it has cached.
      await customStatement(
        'UPDATE messages SET body_text = NULL, body_html = NULL, '
        'calendar = NULL WHERE EXISTS ('
        'SELECT 1 FROM graph_ids g WHERE g.account_id = '
        'messages.account_id AND g.path = messages.path)',
      );
    }
  }

  /// Checked first: a database that already has the column (an upgrade
  /// from before the steps ran in one transaction that was cut short, a
  /// test rolling the version back) must not fail on it and take the whole
  /// cache down with it.
  Future<void> _addColumnIfMissing(
    Migrator m,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    final columns =
        await customSelect('PRAGMA table_info(${table.actualTableName})').get();
    if (columns.any((c) => c.read<String>('name') == column.name)) return;
    await m.addColumn(table, column);
  }
}

/// [CacheStore] on SQLite via Drift. The real store on Android.
class DriftCacheStore implements CacheStore {
  DriftCacheStore(this.db);

  final MailDatabase db;

  Expression<bool> _folder($MessagesTable m, String accountId, String path) =>
      m.accountId.equals(accountId) & m.path.equals(path);

  @override
  Future<FolderSyncState?> readFolderState(String accountId, String path) async {
    final row = await (db.select(db.folderStates)
          ..where((t) => t.accountId.equals(accountId) & t.path.equals(path)))
        .getSingleOrNull();
    if (row == null) return null;
    return FolderSyncState(
      uidValidity: row.uidValidity,
      uidNext: row.uidNext,
      highestModSeq: row.highestModSeq,
      lastSync: row.lastSync,
      previewsChecked: row.previewsChecked,
    );
  }

  @override
  Future<void> writeFolderState(
    String accountId,
    String path,
    FolderSyncState state,
  ) {
    return db.into(db.folderStates).insertOnConflictUpdate(
          FolderStatesCompanion.insert(
            accountId: accountId,
            path: path,
            uidValidity: state.uidValidity,
            uidNext: Value(state.uidNext),
            highestModSeq: Value(state.highestModSeq),
            lastSync: state.lastSync,
            previewsChecked: Value(state.previewsChecked),
          ),
        );
  }

  @override
  Future<void> clearFolder(String accountId, String path) async {
    await db.transaction(() async {
      await (db.delete(db.messages)..where((m) => _folder(m, accountId, path)))
          .go();
      await (db.delete(db.folderStates)
            ..where((t) => t.accountId.equals(accountId) & t.path.equals(path)))
          .go();
    });
  }

  @override
  Future<List<CachedMessage>> readMessages(
    String accountId,
    String path, {
    int offset = 0,
    int limit = 50,
  }) async {
    final rows = await (db.select(db.messages)
          ..where((m) => _folder(m, accountId, path))
          ..orderBy([(m) => OrderingTerm.desc(m.uid)])
          ..limit(limit, offset: offset))
        .get();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<String>> messageIdsFor(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return const [];
    final rows = await (db.select(db.messages)
          ..where((m) =>
              _folder(m, accountId, path) & m.uid.isIn(uids) &
              m.messageId.isNotNull()))
        .get();
    final byUid = {for (final r in rows) r.uid: r.messageId};
    return [
      for (final uid in uids)
        if (byUid[uid] case final id? when id.isNotEmpty) id,
    ];
  }

  @override
  Future<List<int>> uidsForMessageIds(
    String accountId,
    String path,
    Set<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const [];
    final rows = await (db.select(db.messages)
          ..where((m) =>
              _folder(m, accountId, path) & m.messageId.isIn(messageIds)))
        .get();
    return [for (final r in rows) r.uid];
  }

  @override
  Future<List<SyncRow>> readSyncRows(String accountId, String path) async {
    // Whether there is a preview, not the preview: the sync only asks.
    final m = db.messages;
    final hasPreview = m.preview.equals('').not();
    final rows = await (db.selectOnly(m)
          ..addColumns([m.uid, m.date, hasPreview])
          ..where(_folder(m, accountId, path))
          ..orderBy([OrderingTerm.desc(m.uid)]))
        .get();
    return [
      for (final r in rows)
        (
          uid: r.read(m.uid)!,
          date: r.read(m.date)!,
          hasPreview: r.read(hasPreview)!,
        ),
    ];
  }

  @override
  Future<List<MailAddress>> recentAddresses({int limit = 2000}) async {
    // Across every account and folder: the person you write to from one
    // account is a person you might write to from another. Newest first,
    // so the name most recently used for an address is the one met first.
    // Only the address columns: the rest of a row is mostly its body.
    final m = db.messages;
    final rows = await (db.selectOnly(m)
          ..addColumns([m.fromEmail, m.fromName, m.recipientsJson, m.copiedJson])
          ..orderBy([OrderingTerm.desc(m.date)])
          ..limit(limit))
        .get();
    return [
      for (final r in rows) ...[
        MailAddress(email: r.read(m.fromEmail)!, name: r.read(m.fromName)),
        ..._decodeAddresses(r.read(m.recipientsJson)!),
        if (r.read(m.copiedJson) case final copied?)
          ..._decodeAddresses(copied),
      ],
    ];
  }

  @override
  Future<int> countMessages(String accountId, String path) async {
    final count = db.messages.uid.count();
    final row = await (db.selectOnly(db.messages)
          ..addColumns([count])
          ..where(_folder(db.messages, accountId, path)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  @override
  Future<({int min, int max})?> uidRange(String accountId, String path) async {
    final min = db.messages.uid.min();
    final max = db.messages.uid.max();
    final row = await (db.selectOnly(db.messages)
          ..addColumns([min, max])
          ..where(_folder(db.messages, accountId, path)))
        .getSingle();
    final lo = row.read(min);
    final hi = row.read(max);
    if (lo == null || hi == null) return null;
    return (min: lo, max: hi);
  }

  @override
  Future<CachedMessage?> readMessage(
    String accountId,
    String path,
    int uid,
  ) async {
    final row = await (db.select(db.messages)
          ..where((m) => _folder(m, accountId, path) & m.uid.equals(uid)))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<void> upsertMessages(
    String accountId,
    String path,
    List<CachedMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    await _dropBodiesOfReplacedMessages(accountId, path, messages);
    await db.batch((b) {
      for (final m in messages) {
        b.insert(
          db.messages,
          MessagesCompanion.insert(
            accountId: accountId,
            path: path,
            uid: m.uid,
            subject: m.subject,
            fromEmail: m.from.email,
            fromName: Value(m.from.name),
            recipientsJson: _encodeAddresses(m.to),
            copiedJson: Value(_encodeAddresses(m.cc)),
            replyToJson: Value(
              m.replyTo.isEmpty ? null : _encodeAddresses(m.replyTo),
            ),
            date: m.date,
            arrived: Value(m.arrived),
            isRead: m.isRead,
            isFlagged: m.isFlagged,
            isAnswered: Value(m.isAnswered),
            isForwarded: Value(m.isForwarded),
            hasAttachments: m.hasAttachments,
            attachmentBytes: Value(m.attachmentBytes),
            isMeeting: Value(m.isMeeting),
            preview: Value(m.preview),
            bodyText: Value(m.bodyText),
            bodyHtml: Value(m.bodyHtml),
            calendar: Value(m.calendar),
            messageId: Value(m.messageId),
            inReplyTo: Value(m.inReplyTo),
          ),
          // A re-fetched header must not wipe a body we already have, so on
          // conflict only the header columns are rewritten. The preview is
          // among them only when the header brought one: it is also written
          // from a fetched body, and an empty one must not erase that.
          onConflict: DoUpdate(
            (_) => MessagesCompanion(
              subject: Value(m.subject),
              fromEmail: Value(m.from.email),
              fromName: Value(m.from.name),
              recipientsJson: Value(_encodeAddresses(m.to)),
              copiedJson: Value(_encodeAddresses(m.cc)),
              replyToJson: Value(
                m.replyTo.isEmpty ? null : _encodeAddresses(m.replyTo),
              ),
              date: Value(m.date),
              // A header read without it (a Microsoft one) leaves it be.
              arrived:
                  m.arrived == null ? const Value.absent() : Value(m.arrived),
              messageId: Value(m.messageId),
              inReplyTo: Value(m.inReplyTo),
              isRead: Value(m.isRead),
              isFlagged: Value(m.isFlagged),
              isAnswered: Value(m.isAnswered),
              isForwarded: Value(m.isForwarded),
              hasAttachments: Value(m.hasAttachments),
              isMeeting: Value(m.isMeeting),
              // Only when the server said. A re-read header that carries no
              // size must not erase one that was found.
              attachmentBytes: m.attachmentBytes > 0
                  ? Value(m.attachmentBytes)
                  : const Value.absent(),
              preview:
                  m.preview.isEmpty ? const Value.absent() : Value(m.preview),
            ),
          ),
        );
      }
    });
  }

  /// Where a number now belongs to a different message, throw away what was
  /// cached under it.
  ///
  /// The upsert below keeps the body on purpose, so that re-reading a header
  /// does not cost a body already fetched. That is right while a number means
  /// the same message and catastrophic the moment it does not: the row ends
  /// up holding one message's header and another's body, and the reading pane
  /// shows the wrong message under the right subject.
  ///
  /// The `Message-ID` is what tells them apart. It belongs to the message and
  /// follows it everywhere, so a number whose Message-ID has changed is a
  /// number that has changed hands. Only acted on where both are known: an
  /// older row may have none, and guessing there would throw away good
  /// bodies.
  Future<void> _dropBodiesOfReplacedMessages(
    String accountId,
    String path,
    List<CachedMessage> messages,
  ) async {
    final incoming = {
      for (final m in messages)
        if (m.messageId case final id? when id.isNotEmpty) m.uid: id,
    };
    if (incoming.isEmpty) return;
    final rows = await (db.select(db.messages)
          ..where((t) =>
              _folder(t, accountId, path) &
              t.uid.isIn(incoming.keys) &
              t.messageId.isNotNull()))
        .get();
    final changed = [
      for (final r in rows)
        if (r.messageId != null &&
            r.messageId!.isNotEmpty &&
            r.messageId != incoming[r.uid])
          r.uid,
    ];
    if (changed.isEmpty) return;
    await (db.update(db.messages)
          ..where((t) => _folder(t, accountId, path) & t.uid.isIn(changed)))
        .write(const MessagesCompanion(
          bodyText: Value(null),
          bodyHtml: Value(null),
          calendar: Value(null),
          preview: Value(''),
        ));
  }

  @override
  Future<void> updateFlags(
    String accountId,
    String path,
    Map<int, CachedFlags> flagsByUid,
  ) async {
    if (flagsByUid.isEmpty) return;
    await db.batch((b) {
      for (final e in flagsByUid.entries) {
        b.update(
          db.messages,
          MessagesCompanion(
            isRead: Value(e.value.isRead),
            isFlagged: Value(e.value.isFlagged),
            isAnswered: Value(e.value.isAnswered),
            isForwarded: Value(e.value.isForwarded),
          ),
          where: (m) => _folder(m, accountId, path) & m.uid.equals(e.key),
        );
      }
    });
  }

  @override
  Future<void> deleteUids(String accountId, String path, Set<int> uids) async {
    if (uids.isEmpty) return;
    await (db.delete(db.messages)
          ..where((m) => _folder(m, accountId, path) & m.uid.isIn(uids)))
        .go();
  }

  @override
  Future<void> writeBody(
    String accountId,
    String path,
    int uid, {
    required String text,
    String? html,
    String? calendar,
    required String preview,
  }) async {
    await (db.update(db.messages)
          ..where((m) => _folder(m, accountId, path) & m.uid.equals(uid)))
        .write(
      MessagesCompanion(
        bodyText: Value(text),
        bodyHtml: Value(html),
        calendar: Value(calendar),
        preview: Value(preview),
      ),
    );
  }

  @override
  Future<void> renameFolder(
    String accountId,
    String oldPath,
    String newPath,
  ) async {
    if (oldPath == newPath) return;
    final from = folderSubtree(oldPath);
    final to = folderSubtree(newPath);
    await db.transaction(() async {
      for (final table in ['messages', 'folder_states']) {
        // Left behind by a folder deleted or renamed on another device.
        // The rows arriving collided with it, and a rename the server had
        // already made was reported as failed. Never the folder being
        // moved, should the one name sit under the other.
        await db.customUpdate(
          'DELETE FROM $table WHERE account_id = ? AND ${to.sql} '
          'AND NOT ${from.sql}',
          variables: _variables([accountId, ...to.args, ...from.args]),
          updates: {db.messages, db.folderStates},
          updateKind: UpdateKind.delete,
        );
        // The folder itself and everything under it: replace the prefix.
        await db.customUpdate(
          'UPDATE $table SET path = ? || substr(path, ?) '
          'WHERE account_id = ? AND ${from.sql}',
          variables: _variables([
            newPath,
            sqlLength(oldPath) + 1,
            accountId,
            ...from.args,
          ]),
          updates: {db.messages, db.folderStates},
        );
      }
    });
  }

  @override
  Future<void> deleteFolder(String accountId, String path) async {
    final subtree = folderSubtree(path);
    await db.transaction(() async {
      for (final table in ['messages', 'folder_states']) {
        await db.customUpdate(
          'DELETE FROM $table WHERE account_id = ? AND ${subtree.sql}',
          variables: _variables([accountId, ...subtree.args]),
          updates: {db.messages, db.folderStates},
          updateKind: UpdateKind.delete,
        );
      }
    });
  }

  @override
  Future<void> pruneFolders(String accountId, Set<String> paths) async {
    await db.transaction(() async {
      await (db.delete(db.messages)
            ..where((m) =>
                m.accountId.equals(accountId) & m.path.isNotIn(paths)))
          .go();
      await (db.delete(db.folderStates)
            ..where((t) =>
                t.accountId.equals(accountId) & t.path.isNotIn(paths)))
          .go();
    });
  }

  @override
  Future<void> deleteAccount(String accountId) async {
    await db.transaction(() async {
      await (db.delete(db.messages)..where((m) => m.accountId.equals(accountId)))
          .go();
      await (db.delete(db.folderStates)
            ..where((t) => t.accountId.equals(accountId)))
          .go();
    });
  }

  // ---------------------------------------------------------------------------

  static CachedMessage _fromRow(MessageRow r) => CachedMessage(
        uid: r.uid,
        subject: r.subject,
        from: MailAddress(email: r.fromEmail, name: r.fromName),
        to: _decodeAddresses(r.recipientsJson),
        cc: r.copiedJson == null
            ? const []
            : _decodeAddresses(r.copiedJson!),
        replyTo: r.replyToJson == null
            ? const []
            : _decodeAddresses(r.replyToJson!),
        date: r.date,
        arrived: r.arrived,
        isRead: r.isRead,
        isFlagged: r.isFlagged,
        isAnswered: r.isAnswered,
        isForwarded: r.isForwarded,
        hasAttachments: r.hasAttachments,
        attachmentBytes: r.attachmentBytes,
        isMeeting: r.isMeeting,
        preview: r.preview,
        bodyText: r.bodyText,
        bodyHtml: r.bodyHtml,
        calendar: r.calendar,
        messageId: r.messageId,
        inReplyTo: r.inReplyTo,
      );

  static String _encodeAddresses(List<MailAddress> list) => jsonEncode([
        for (final a in list) {'email': a.email, 'name': a.name},
      ]);

  static List<MailAddress> _decodeAddresses(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return [
      for (final e in list.cast<Map<String, dynamic>>())
        MailAddress(email: e['email'] as String, name: e['name'] as String?),
    ];
  }

  static List<Variable> _variables(List<Object> values) => [
        for (final v in values)
          v is int ? Variable.withInt(v) : Variable.withString(v as String),
      ];
}

/// A folder and everything under it, as a condition on a `path` column, and
/// the arguments it takes.
///
/// Compared exactly. LIKE ignores case, so renaming 'Work' also moved a
/// separate 'work/…', and deleting it took that folder's cache too.
({String sql, List<Object> args}) folderSubtree(String path) => (
      sql: '(path = ? OR substr(path, 1, ?) = ?)',
      args: [path, sqlLength('$path/'), '$path/'],
    );

/// How long SQLite's substr takes [s] to be: in characters, where Dart's
/// length counts UTF-16 units. An emoji is one to SQLite and two to Dart,
/// and cutting a child's path at the Dart length turned '📁Bills/2024'
/// into 'Bills2024'.
int sqlLength(String s) => s.runes.length;
