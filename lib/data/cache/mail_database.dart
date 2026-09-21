import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

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
  DateTimeColumn get date => dateTime()();
  BoolColumn get isRead => boolean()();
  BoolColumn get isFlagged => boolean()();
  BoolColumn get hasAttachments => boolean()();
  TextColumn get preview => text().withDefault(const Constant(''))();
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
  MailDatabase.open() : super(driftDatabase(name: 'mailtree'));

  /// The lookup the transport does most: a Graph id in hand, wanting the
  /// number it was given. Without this it is a table scan per message, on
  /// every page of every folder.
  Index get graphIdByRemote => Index(
        'graph_ids_by_remote',
        'CREATE INDEX IF NOT EXISTS graph_ids_by_remote ON graph_ids '
            '(account_id, path, remote_id)',
      );

  @override
  int get schemaVersion => 4;

  /// Adding a column must not cost the user their cache.
  ///
  /// Drift's default for a version bump with no strategy is to do nothing,
  /// and the app then queries columns the table does not have. Adding them in
  /// place keeps every cached message and body; the two new columns stay null
  /// on old rows until that folder is next synced, which is exactly what the
  /// nullable declaration above is for.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(messages, messages.messageId);
            await m.addColumn(messages, messages.inReplyTo);
          }
          if (from < 3) {
            // New in schema 3, for Microsoft accounts. Creating it empty
            // costs nothing: a Gmail account never writes to it, and a
            // Microsoft one fills it as it syncs.
            await m.createTable(graphIds);
            await m.createIndex(graphIdByRemote);
          }
          if (from < 4) {
            // Invitations. A body cached before this has no calendar
            // column; opening such a message shows it without the card
            // until the body is fetched again. Checked first: a database
            // that already has the column (an upgrade that was cut short
            // after this step, a test rolling the version back) must not
            // fail on it and take the whole cache down with it.
            final columns = await customSelect(
              'PRAGMA table_info(messages)',
            ).get();
            final has = columns.any((c) => c.read<String>('name') == 'calendar');
            if (!has) await m.addColumn(messages, messages.calendar);
          }
        },
      );
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
  Future<List<MailAddress>> recentAddresses({int limit = 2000}) async {
    // Across every account and folder: the person you write to from one
    // account is a person you might write to from another. Newest first,
    // so the name most recently used for an address is the one met first.
    final rows = await (db.select(db.messages)
          ..orderBy([(m) => OrderingTerm.desc(m.date)])
          ..limit(limit))
        .get();
    return [
      for (final r in rows) ...[
        MailAddress(email: r.fromEmail, name: r.fromName),
        ..._decodeAddresses(r.recipientsJson),
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
            date: m.date,
            isRead: m.isRead,
            isFlagged: m.isFlagged,
            hasAttachments: m.hasAttachments,
            preview: Value(m.preview),
            bodyText: Value(m.bodyText),
            bodyHtml: Value(m.bodyHtml),
            calendar: Value(m.calendar),
            messageId: Value(m.messageId),
            inReplyTo: Value(m.inReplyTo),
          ),
          // A re-fetched header must not wipe a body we already have, so on
          // conflict only the header columns are rewritten.
          onConflict: DoUpdate(
            (_) => MessagesCompanion(
              subject: Value(m.subject),
              fromEmail: Value(m.from.email),
              fromName: Value(m.from.name),
              recipientsJson: Value(_encodeAddresses(m.to)),
              date: Value(m.date),
              messageId: Value(m.messageId),
              inReplyTo: Value(m.inReplyTo),
              isRead: Value(m.isRead),
              isFlagged: Value(m.isFlagged),
              hasAttachments: Value(m.hasAttachments),
            ),
          ),
        );
      }
    });
  }

  @override
  Future<void> updateFlags(
    String accountId,
    String path,
    Map<int, ({bool isRead, bool isFlagged})> flagsByUid,
  ) async {
    if (flagsByUid.isEmpty) return;
    await db.batch((b) {
      for (final e in flagsByUid.entries) {
        b.update(
          db.messages,
          MessagesCompanion(
            isRead: Value(e.value.isRead),
            isFlagged: Value(e.value.isFlagged),
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
    // The folder itself and everything under it: replace the prefix.
    await db.transaction(() async {
      for (final table in ['messages', 'folder_states']) {
        await db.customUpdate(
          'UPDATE $table SET path = ? || substr(path, ?) '
          "WHERE account_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')",
          variables: [
            Variable.withString(newPath),
            Variable.withInt(oldPath.length + 1),
            Variable.withString(accountId),
            Variable.withString(oldPath),
            Variable.withString('${_escapeLike(oldPath)}/%'),
          ],
          updates: {db.messages, db.folderStates},
        );
      }
    });
  }

  @override
  Future<void> deleteFolder(String accountId, String path) async {
    final like = '${_escapeLike(path)}/%';
    await db.transaction(() async {
      for (final table in ['messages', 'folder_states']) {
        await db.customUpdate(
          'DELETE FROM $table '
          "WHERE account_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')",
          variables: [
            Variable.withString(accountId),
            Variable.withString(path),
            Variable.withString(like),
          ],
          updates: {db.messages, db.folderStates},
          updateKind: UpdateKind.delete,
        );
      }
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
        date: r.date,
        isRead: r.isRead,
        isFlagged: r.isFlagged,
        hasAttachments: r.hasAttachments,
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

  /// `_` and `%` are wildcards in LIKE; folder names can contain them.
  static String _escapeLike(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
}
