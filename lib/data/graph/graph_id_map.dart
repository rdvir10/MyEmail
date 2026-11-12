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
///
/// A message that has left a folder is remembered as gone from it for a
/// while ([goneFor]), by the id it had there. A sync lists the folder and
/// numbers what it finds, and a list read a moment before a delete landed
/// still names the deleted message: its id, forgotten outright, read as one
/// never seen, so it was given a new number and stored again, and the
/// message came back on screen until the next sync noticed it was not
/// there. The app's own sync did that, and so did the background one, which
/// asks every minute from an isolate of its own.
abstract class GraphIdMap {
  /// The number for this Graph id, assigning one if it has not been seen.
  ///
  /// [remoteIds] in the order they should be numbered — oldest first — because
  /// the numbers come out in the order given.
  ///
  /// An id that left this folder within [goneFor] gets no number and is
  /// left out of the answer: what named it was read before it left. Unless
  /// [here], for ids the server has just said are in the folder (where a
  /// move landed), which are numbered whatever went before.
  Future<Map<String, int>> uidsFor(
    String accountId,
    String path,
    List<String> remoteIds, {
    bool here = false,
  });

  /// How long an id is remembered as gone from a folder. Longer than any
  /// answer can be in coming, a throttled one waited out included, and
  /// than the search index takes to hear of a move; short enough that a
  /// message put back from somewhere else under its old id, if Microsoft
  /// ever gave one back, would not be missed for long.
  static const goneFor = Duration(minutes: 5);

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
  /// resolve to nothing rather than to whatever message came next. The ids
  /// they had are remembered as gone for [goneFor]; see [uidsFor].
  Future<void> forgetMoved(String accountId, String path, List<int> uids);

  /// What a forgotten number's remote id reads as: nothing.
  ///
  /// A real Graph id is a long opaque string and is never empty, so this can
  /// never be mistaken for one.
  static const forgotten = '';

  Future<void> forgetAccount(String accountId);
}

class DriftGraphIdMap implements GraphIdMap {
  DriftGraphIdMap(this.db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final MailDatabase db;

  /// The time, for what has gone and how long ago. Set by tests.
  final DateTime Function() _clock;

  @override
  Future<Map<String, int>> uidsFor(
    String accountId,
    String path,
    List<String> remoteIds, {
    bool here = false,
  }) async {
    if (remoteIds.isEmpty) return const {};

    final known = await _lookUp(accountId, path, remoteIds);
    if (known.length == remoteIds.toSet().length) return known;

    // One transaction for the look-up, the read of the high-water mark and
    // the writes that follow them. Two syncs of this folder at once, a
    // refresh and a load-more or the app and the worker, each used to find
    // a new message missing before either had numbered it, and each gave it
    // a number of its own: the message showed twice. Looked up again in
    // here, the second finds the first's number. Across connections the
    // unique index on the remote id makes a second insert a no-op instead.
    await db.transaction(() async {
      final rows = await _rows(accountId, path, remoteIds);
      // Gone from here and named again. By a list read before it went,
      // which is left without a number; or, long enough after or on the
      // server's own word, by the message back in the folder, whose old
      // number is spent like any other and makes way for a new one.
      final since =
          _clock().subtract(GraphIdMap.goneFor).millisecondsSinceEpoch;
      final back = [
        for (final r in rows)
          if (r.goneAt case final at? when here || at < since) r.uid,
      ];
      if (back.isNotEmpty) {
        await (db.update(db.graphIds)
              ..where((t) =>
                  t.accountId.equals(accountId) &
                  t.path.equals(path) &
                  t.uid.isIn(back)))
            .write(const GraphIdsCompanion(
              remoteId: Value(GraphIdMap.forgotten),
            ));
      }
      final held = {
        for (final r in rows)
          if (!back.contains(r.uid)) r.remoteId,
      };
      final missing = {
        for (final id in remoteIds)
          if (!held.contains(id)) id,
      };
      if (missing.isEmpty) return;
      var next = await highestUid(accountId, path) + 1;
      await db.batch((batch) {
        for (final id in missing) {
          batch.insert(
            db.graphIds,
            GraphIdsCompanion.insert(
              accountId: accountId,
              path: path,
              uid: next,
              remoteId: id,
            ),
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

  /// The numbers of the ids in the folder now: not one that has left it.
  Future<Map<String, int>> _lookUp(
    String accountId,
    String path,
    List<String> remoteIds,
  ) async =>
      {
        for (final r in await _rows(accountId, path, remoteIds))
          if (r.goneAt == null) r.remoteId: r.uid,
      };

  /// Every row holding one of [remoteIds], gone from the folder or not.
  /// Never a spent number's, whose id is blank.
  Future<List<GraphIdRow>> _rows(
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
    return [
      for (final r in rows)
        if (r.remoteId != GraphIdMap.forgotten) r,
    ];
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
        // caller holding a stale one has to be told. So does the number of
        // a message that has left.
        if (r.remoteId != GraphIdMap.forgotten && r.goneAt == null)
          r.uid: r.remoteId,
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
    final from = folderSubtree(oldPath);
    final to = folderSubtree(newPath);
    await db.transaction(() async {
      // Anything left at the destination belongs to no folder that exists
      // now, and would collide with the rows arriving.
      await db.customStatement(
        'DELETE FROM graph_ids WHERE account_id = ? AND ${to.sql} '
        'AND NOT ${from.sql}',
        [accountId, ...to.args, ...from.args],
      );
      // The same prefix swap the cache makes for its messages.
      await db.customStatement(
        'UPDATE graph_ids SET path = ? || substr(path, ?) '
        'WHERE account_id = ? AND ${from.sql}',
        [newPath, sqlLength(oldPath) + 1, accountId, ...from.args],
      );
    });
  }

  @override
  Future<void> forgetMoved(
    String accountId,
    String path,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return;
    final now = _clock();
    await db.transaction(() async {
      // Marked as gone, not deleted. Deleting let the number be handed out
      // again to the next message to arrive, and a cache row still carrying
      // it then described one message while holding another's body. The id
      // stays beside the mark, for [uidsFor] to know it by.
      await (db.update(db.graphIds)
            ..where((t) =>
                t.accountId.equals(accountId) &
                t.path.equals(path) &
                t.uid.isIn(uids) &
                t.goneAt.isNull()))
          .write(GraphIdsCompanion(
            goneAt: Value(now.millisecondsSinceEpoch),
          ));
      // Only the highest spent number has to survive to keep the count
      // moving forward. The rest are swept up once they have been gone
      // long enough, so the table does not grow a row for every message
      // ever deleted.
      await db.customStatement(
        'DELETE FROM graph_ids WHERE account_id = ? AND path = ? '
        'AND (remote_id = ? OR gone_at < ?) AND uid < '
        '(SELECT MAX(uid) FROM graph_ids WHERE account_id = ? AND path = ?)',
        [
          accountId,
          path,
          GraphIdMap.forgotten,
          now.subtract(GraphIdMap.goneFor).millisecondsSinceEpoch,
          accountId,
          path,
        ],
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
  MemoryGraphIdMap({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Keyed by a record rather than by a joined string. The two halves are an
  /// account id and a folder path, and any separator chosen for them is a
  /// character a folder name might legitimately contain; a record compares by
  /// value and cannot be confused that way.
  final Map<(String, String), Map<String, int>> _byFolder = {};
  final Map<(String, String), int> _next = {};

  /// The ids that have left each folder, and when.
  final Map<(String, String), Map<String, DateTime>> _gone = {};

  @override
  Future<Map<String, int>> uidsFor(
    String accountId,
    String path,
    List<String> remoteIds, {
    bool here = false,
  }) async {
    final key = (accountId, path);
    final folder = _byFolder.putIfAbsent(key, () => {});
    final gone = _gone.putIfAbsent(key, () => {});
    final since = _clock().subtract(GraphIdMap.goneFor);
    for (final id in remoteIds) {
      if (folder.containsKey(id)) continue;
      // Left a moment ago, and named by a list read before it did.
      if (gone[id] case final at? when !here && !at.isBefore(since)) continue;
      gone.remove(id);
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
    final now = _clock();
    final gone = _gone.putIfAbsent((accountId, path), () => {})
      ..removeWhere((_, at) => at.isBefore(now.subtract(GraphIdMap.goneFor)));
    folder.removeWhere((id, uid) {
      if (!doomed.contains(uid)) return false;
      gone[id] = now;
      return true;
    });
  }

  @override
  Future<void> forgetFolder(String accountId, String path) async {
    _byFolder.remove((accountId, path));
    _gone.remove((accountId, path));
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
      final left = _gone.remove(key);
      if (left != null) _gone[target] = left;
      final counter = _next.remove(key);
      if (counter != null) _next[target] = counter;
    }
  }

  @override
  Future<void> forgetAccount(String accountId) async {
    _byFolder.removeWhere((key, _) => key.$1 == accountId);
    _gone.removeWhere((key, _) => key.$1 == accountId);
  }
}
