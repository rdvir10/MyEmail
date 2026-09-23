import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A notification button that has been pressed but not yet carried out.
class PendingAction {
  const PendingAction({
    required this.actionId,
    required this.messageId,
    this.typed,
    this.attempts = 0,
  });

  final String actionId;
  final String messageId;

  /// What was typed into the notification, for a reply.
  final String? typed;

  /// How many times it has been tried and failed for a reason other than
  /// being offline.
  final int attempts;

  PendingAction tried() => PendingAction(
        actionId: actionId,
        messageId: messageId,
        typed: typed,
        attempts: attempts + 1,
      );

  Map<String, Object?> toJson() => {
        'action': actionId,
        'message': messageId,
        if (typed != null) 'typed': typed,
        if (attempts > 0) 'attempts': attempts,
      };

  static PendingAction? fromJson(Object? value) {
    if (value is! Map) return null;
    final action = value['action'];
    final message = value['message'];
    if (action is! String || message is! String) return null;
    if (action.isEmpty || message.isEmpty) return null;
    return PendingAction(
      actionId: action,
      messageId: message,
      typed: value['typed'] is String ? value['typed'] as String : null,
      attempts: value['attempts'] is int ? value['attempts'] as int : 0,
    );
  }
}

/// One press, claimed by one drain.
class ClaimedAction {
  ClaimedAction._(this.action, this._file);

  final PendingAction action;
  final File _file;
}

/// The queue of pressed notification buttons, waiting to be carried out.
///
/// This exists because of how short a life Android gives the isolate it
/// starts for a notification action. The plugin's callback returns `void`,
/// so nothing waits for the work inside it, and deleting a message means a
/// round trip to the mail server — a second or two, which the isolate does
/// not reliably survive. Pressing Delete therefore appeared to do nothing:
/// the notification went away, because Android dismisses it, and the message
/// stayed where it was.
///
/// So the press is written down first, which takes no time and cannot fail
/// halfway, and the work is done by something with a proper lifetime: the
/// WorkManager job, or the app the next time it is opened.
///
/// One file per press, claimed by renaming it. Three isolates use this —
/// the one Android starts for a button, the WorkManager job and the app —
/// and it used to be one list in preferences, read, changed and written
/// back. Two drains at once could both act on a press, so a reply went
/// twice; a press written while a drain ran was wiped, typed reply and all.
/// A rename either happens or does not, so exactly one drain gets each
/// press, and writing a new one touches nothing else.
///
/// A drain that cannot carry a press out puts it back ([putBack]) rather
/// than dropping it, so what was typed into a reply is not lost to a
/// moment without a connection.
class PendingActions {
  PendingActions({Directory? directory, this._prefs}) : _given = directory;

  final Directory? _given;
  final SharedPreferencesAsync? _prefs;

  /// Where an earlier version kept the whole queue as one list.
  static const legacyKey = 'notify.pending.v1';

  /// A claim held this long belongs to a drain that was killed part way:
  /// the press goes back in the queue.
  static const abandonedAfter = Duration(minutes: 30);

  static final _random = Random();

  Future<Directory> _directory() async {
    final dir = _given ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}pending-actions',
        );
    await dir.create(recursive: true);
    return dir;
  }

  static String _unique() => '${DateTime.now().microsecondsSinceEpoch}-'
      '${_random.nextInt(1 << 32).toRadixString(16)}';

  String _in(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<void> add(PendingAction action) async {
    final dir = await _directory();
    await _write(dir, _unique(), action);
  }

  /// Written aside, then renamed into place, so a drain never reads half.
  Future<void> _write(Directory dir, String name, PendingAction action) async {
    final temp = File(_in(dir, '$name.tmp'));
    await temp.writeAsString(jsonEncode(action.toJson()), flush: true);
    await temp.rename(_in(dir, '$name.json'));
  }

  /// Everything waiting, oldest first, each claimed for this caller alone.
  ///
  /// Hand each one back with [done] or [putBack].
  Future<List<ClaimedAction>> take() async {
    final dir = await _directory();
    await _bringInLegacy(dir);
    await _reclaimAbandoned(dir);

    final token = _unique();
    final waiting = [
      for (final entity in await dir.list().toList())
        if (entity is File && entity.path.endsWith('.json')) entity,
    ]..sort((a, b) => a.path.compareTo(b.path));

    final claimed = <ClaimedAction>[];
    for (final file in waiting) {
      final File mine;
      try {
        mine = await file.rename('${file.path}.$token.taken');
        // A rename keeps the time the press was written. Stamped with the
        // time it was claimed, or one that waited half an hour would look
        // abandoned the moment it was taken, and be taken again.
        await mine.setLastModified(DateTime.now());
      } on FileSystemException {
        continue; // Another drain got there first.
      }
      PendingAction? action;
      try {
        action = PendingAction.fromJson(jsonDecode(await mine.readAsString()));
      } on FormatException {
        action = null;
      }
      if (action == null) {
        // Unreadable: carried around it would be tried for ever.
        await _delete(mine);
        continue;
      }
      claimed.add(ClaimedAction._(action, mine));
    }
    return claimed;
  }

  /// Carried out, or given up on: gone from the queue.
  Future<void> done(ClaimedAction claim) => _delete(claim._file);

  /// Not carried out, and worth another try later: back in the queue, in
  /// its old place. [counted] adds to its attempts; being offline is not
  /// counted, because it says nothing about whether the press can work.
  Future<void> putBack(ClaimedAction claim, {bool counted = true}) async {
    final dir = await _directory();
    await _write(
      dir,
      _nameOf(claim._file),
      counted ? claim.action.tried() : claim.action,
    );
    await _delete(claim._file);
  }

  static String _nameOf(File claimed) {
    final base = claimed.uri.pathSegments.last;
    return base.substring(0, base.indexOf('.json'));
  }

  Future<void> _reclaimAbandoned(Directory dir) async {
    final cutoff = DateTime.now().subtract(abandonedAfter);
    for (final entity in await dir.list().toList()) {
      if (entity is! File || !entity.path.endsWith('.taken')) continue;
      try {
        if ((await entity.lastModified()).isAfter(cutoff)) continue;
        await entity.rename(_in(dir, '${_nameOf(entity)}.json'));
      } on FileSystemException {
        // Reclaimed by someone else in the meantime.
      }
    }
  }

  /// Presses written by an earlier version, as one list in preferences.
  Future<void> _bringInLegacy(Directory dir) async {
    final prefs = _prefs ?? SharedPreferencesAsync();
    final String? raw;
    try {
      raw = await prefs.getString(legacyKey);
    } catch (_) {
      return;
    }
    if (raw == null) return;
    await prefs.remove(legacyKey);
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final entry in list) {
        final action = PendingAction.fromJson(entry);
        if (action != null) await _write(dir, _unique(), action);
      }
    } on FormatException {
      // Nothing readable to bring in.
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
