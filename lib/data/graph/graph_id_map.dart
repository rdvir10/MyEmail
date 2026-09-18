import 'package:drift/drift.dart';

import '../cache/mail_database.dart';

/// Gives each Graph message a number, and remembers which is which.
///
/// Graph has nothing like an IMAP UID. Its message ids are long opaque
/// strings, while the cache, the sync and the notification watermarks are all
/// keyed on an integer that only ever increases. This is the join between the
/// two.
///
/// Numbers are handed out in the order messages are first seen, which is the
/// rule IMAP uses for UIDs, so "a higher number arrived later" holds and every
/// piece of sync arithmetic above keeps working. They are never reused, even
/// after the message they belonged to is deleted: reusing one would make a
/// stale cache row point at a different message, which is precisely what
/// UIDVALIDITY exists to prevent.
abstract class GraphIdMap {
  /// The number for this Graph id, assigning one if it has not been seen.
  ///
  /// [remoteIds] in the order they should be numbered — oldest first — because
  /// the numbers come out in the order given.
  Future<Map<String, int>> uidsFor(
    String accountId,
    String path,
    List<String> remoteIds,
  );

  /// The Graph ids for numbers already assigned. Missing entries are messages
  /// this device has never seen, or has forgotten.
  Future<Map<int, String>> remoteIdsFor(
    String accountId,
    String path,
    List<int> uids,
  );

  /// The highest number handed out in this folder, or 0 for an empty one.
  Future<int> highestUid(String accountId, String path);

  /// Drop a folder's numbering, for a folder that is gone.
  Future<void> forgetFolder(String accountId, String path);

  /// Forget particular numbers, for messages that have left this folder.
  ///
  /// Only the mapping goes. The counter does not move back, so the numbers
  /// are never handed out again: a cache row that still mentions one must
  /// resolve to nothing rather than to whatever message came next.
  Future<void> forgetMoved(String accountId, String path, List<int> uids);

  Future<void> forgetAccount(String accountId);
}

class DriftGraphIdMap implements GraphIdMap {
  DriftGraphIdMap(this.db);

  final MailDatabase db;

  @override
  Future<Map<String, int>> uidsFor(
    String accountId,
    String path,
    List<String> remoteIds,
  ) async {
    if (remoteIds.isEmpty) return const {};

    final known = await _lookUp(accountId, path, remoteIds);
    final missing = [
      for (final id in remoteIds)
        if (!known.containsKey(id)) id,
    ];
    if (missing.isEmpty) return known;

    // One transaction for the read of the high-water mark and the writes that
    // follow it. Two folders syncing at once would otherwise both read the
    // same highest number and hand out the same ones, and the second write
    // would collide on the primary key.
    await db.transaction(() async {
      var next = await highestUid(accountId, path) + 1;
      await db.batch((batch) {
        for (final id in missing) {
          known[id] = next;
          batch.insert(
            db.graphIds,
            GraphIdsCompanion.insert(
              accountId: accountId,
              path: path,
              uid: next,
              remoteId: id,
            ),
            // A concurrent sync may have inserted the same id already. Its
            // number is as good as ours; the reconciling read below settles
            // which one everyone uses.
            mode: InsertMode.insertOrIgnore,
          );
          next++;
        }
      });
    });

    // Read back rather than trusting what was just written: insertOrIgnore
    // means a row that was already there kept its own number, and handing
    // back the one we would have used would point the cache at nothing.
    return _lookUp(accountId, path, remoteIds);
  }

  Future<Map<String, int>> _lookUp(
    String accountId,
    String path,
    List<String> remoteIds,
  ) async {
    final rows = await (db.select(db.graphIds)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.path.equals(path) &
              t.remoteId.isIn(remoteIds)))
        .get();
    return {for (final r in rows) r.remoteId: r.uid};
  }

  @override
  Future<Map<int, String>> remoteIdsFor(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return const {};
    final rows = await (db.select(db.graphIds)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.path.equals(path) &
              t.uid.isIn(uids)))
        .get();
    return {for (final r in rows) r.uid: r.remoteId};
  }

  @override
  Future<int> highestUid(String accountId, String path) async {
    final highest = db.graphIds.uid.max();
    final row = await (db.selectOnly(db.graphIds)
          ..addColumns([highest])
          ..where(db.graphIds.accountId.equals(accountId) &
              db.graphIds.path.equals(path)))
        .getSingle();
    return row.read(highest) ?? 0;
  }

  @override
  Future<void> forgetFolder(String accountId, String path) =>
      (db.delete(db.graphIds)
            ..where((t) => t.accountId.equals(accountId) & t.path.equals(path)))
          .go();

  @override
  Future<void> forgetMoved(String accountId, String path, List<int> uids) {
    if (uids.isEmpty) return Future.value();
    return (db.delete(db.graphIds)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.path.equals(path) &
              t.uid.isIn(uids)))
        .go();
  }

  @override
  Future<void> forgetAccount(String accountId) =>
      (db.delete(db.graphIds)..where((t) => t.accountId.equals(accountId)))
          .go();
}

/// For tests and anything without a database.
class MemoryGraphIdMap implements GraphIdMap {
  /// Keyed by a record rather than by a joined string. The two halves are an
  /// account id and a folder path, and any separator chosen for them is a
  /// character a folder name might legitimately contain; a record compares by
  /// value and cannot be confused that way.
  final Map<(String, String), Map<String, int>> _byFolder = {};
  final Map<(String, String), int> _next = {};

  @override
  Future<Map<String, int>> uidsFor(
    String accountId,
    String path,
    List<String> remoteIds,
  ) async {
    final key = (accountId, path);
    final folder = _byFolder.putIfAbsent(key, () => {});
    for (final id in remoteIds) {
      if (folder.containsKey(id)) continue;
      final next = (_next[key] ?? 0) + 1;
      _next[key] = next;
      folder[id] = next;
    }
    return {
      for (final id in remoteIds)
        if (folder.containsKey(id)) id: folder[id]!,
    };
  }

  @override
  Future<Map<int, String>> remoteIdsFor(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    final folder = _byFolder[(accountId, path)] ?? const <String, int>{};
    final byUid = {for (final e in folder.entries) e.value: e.key};
    return {
      for (final uid in uids)
        if (byUid.containsKey(uid)) uid: byUid[uid]!,
    };
  }

  @override
  Future<int> highestUid(String accountId, String path) async =>
      _next[(accountId, path)] ?? 0;

  @override
  Future<void> forgetMoved(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    final folder = _byFolder[(accountId, path)];
    if (folder == null) return;
    final doomed = uids.toSet();
    folder.removeWhere((_, uid) => doomed.contains(uid));
  }

  @override
  Future<void> forgetFolder(String accountId, String path) async {
    _byFolder.remove((accountId, path));
    // The counter stays. Numbers are never reused, and a folder emptied and
    // refilled must not hand out numbers a stale cache row still points at.
  }

  @override
  Future<void> forgetAccount(String accountId) async {
    _byFolder.removeWhere((key, _) => key.$1 == accountId);
  }
}
