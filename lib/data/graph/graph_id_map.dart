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
///
/// That last paragraph was a lie for three releases, and it is worth saying
/// how. The highest number handed out is read back as `MAX(uid)` over this
/// table, and forgetting a message deleted its row. Delete the newest message
/// in a folder — which is what anyone does with mail they have just read —
/// and the maximum dropped by one, so the next message to arrive was given
/// the number the deleted one had just given up. The cache row keyed on that
/// number then held one message's header and another's body, and the reading
/// pane showed exactly that: the wrong message under the right subject. A
/// spent number now stays spent; see [forgetMoved].
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

  /// Carry a folder's numbering, and every folder's under it, to a new path.
  ///
  /// For a rename or a move, which the cache follows by re-keying its rows
  /// under their old numbers. The numbering has to follow too. It used to be
  /// dropped, the folder was numbered from 1 again at its new path, and the
  /// cached rows' numbers then belonged to other messages: the wrong body
  /// under a subject, and a delete or a move landing on a different message.
  Future<void> renameFolder(String accountId, String oldPath, String newPath);

  /// Forget particular numbers, for messages that have left this folder.
  ///
  /// Only the mapping goes. The counter does not move back, so the numbers
  /// are never handed out again: a cache row that still mentions one must
  /// resolve to nothing rather than to whatever message came next.
  Future<void> forgetMoved(String accountId, String path, List<int> uids);

  /// What a forgotten number's remote id reads as: nothing.
  ///
  /// A real Graph id is a long opaque string and is never empty, so this can
  /// never be mistaken for one.
  static const forgotten = '';

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
    return {
      for (final r in rows)
        if (r.remoteId != GraphIdMap.forgotten) r.remoteId: r.uid,
    };
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
    return {
      for (final r in rows)
        // A number that has been spent resolves to nothing, which is what a
        // caller holding a stale one has to be told.
        if (r.remoteId != GraphIdMap.forgotten) r.uid: r.remoteId,
    };
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
  Future<void> renameFolder(
    String accountId,
    String oldPath,
    String newPath,
  ) async {
    if (oldPath == newPath) return;
    const scope = "WHERE account_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')";
    await db.transaction(() async {
      // Anything left at the destination belongs to no folder that exists
      // now, and would collide with the rows arriving.
      await db.customStatement('DELETE FROM graph_ids $scope', [
        accountId,
        newPath,
        '${_escapeLike(newPath)}/%',
      ]);
      // The same prefix swap the cache makes for its messages.
      await db.customStatement(
        'UPDATE graph_ids SET path = ? || substr(path, ?) $scope',
        [
          newPath,
          oldPath.length + 1,
          accountId,
          oldPath,
          '${_escapeLike(oldPath)}/%',
        ],
      );
    });
  }

  static String _escapeLike(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');

  @override
  Future<void> forgetMoved(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return;
    await db.transaction(() async {
      // Blanked, not deleted. Deleting let the number be handed out again to
      // the next message to arrive, and a cache row still carrying it then
      // described one message while holding another's body.
      await (db.update(db.graphIds)
            ..where((t) =>
                t.accountId.equals(accountId) &
                t.path.equals(path) &
                t.uid.isIn(uids)))
          .write(const GraphIdsCompanion(
            remoteId: Value(GraphIdMap.forgotten),
          ));
      // Only the highest spent number has to survive to keep the count
      // moving forward. The rest are swept up so the table does not grow a
      // row for every message ever deleted.
      await db.customStatement(
        'DELETE FROM graph_ids WHERE account_id = ? AND path = ? '
        'AND remote_id = ? AND uid < '
        '(SELECT MAX(uid) FROM graph_ids WHERE account_id = ? AND path = ?)',
        [accountId, path, GraphIdMap.forgotten, accountId, path],
      );
    });
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
  Future<void> renameFolder(
    String accountId,
    String oldPath,
    String newPath,
  ) async {
    if (oldPath == newPath) return;
    String? moved(String path) {
      if (path == oldPath) return newPath;
      if (path.startsWith('$oldPath/')) {
        return '$newPath${path.substring(oldPath.length)}';
      }
      return null;
    }

    for (final key in {..._byFolder.keys, ..._next.keys}) {
      if (key.$1 != accountId) continue;
      final to = moved(key.$2);
      if (to == null) continue;
      final target = (accountId, to);
      final numbers = _byFolder.remove(key);
      if (numbers != null) _byFolder[target] = numbers;
      final counter = _next.remove(key);
      if (counter != null) _next[target] = counter;
    }
  }

  @override
  Future<void> forgetAccount(String accountId) async {
    _byFolder.removeWhere((key, _) => key.$1 == accountId);
  }
}
