import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A notification button that has been pressed but not yet carried out.
class PendingAction {
  const PendingAction({
    required this.actionId,
    required this.messageId,
    this.typed,
    this.attempts = 0,
    this.queuedAt,
    this.sendStarted = false,
  });

  final String actionId;
  final String messageId;

  /// What was typed into the notification, for a reply.
  final String? typed;

  /// How many times it has been tried and failed for a reason other than
  /// being offline.
  final int attempts;

  /// When it was pressed, so a press that has waited a day for a connection
  /// is given up on and said, rather than retried for ever.
  final DateTime? queuedAt;

  /// A reply whose send was begun and never heard back from: the drain was
  /// killed while sending. It may have gone, so it is never sent again; the
  /// person is told, with what they wrote.
  final bool sendStarted;

  PendingAction _with({int? attempts, DateTime? queuedAt, bool? sendStarted}) =>
      PendingAction(
        actionId: actionId,
        messageId: messageId,
        typed: typed,
        attempts: attempts ?? this.attempts,
        queuedAt: queuedAt ?? this.queuedAt,
        sendStarted: sendStarted ?? this.sendStarted,
      );

  PendingAction tried() => _with(attempts: attempts + 1);

  Map<String, Object?> toJson() => {
        'action': actionId,
        'message': messageId,
        if (typed != null) 'typed': typed,
        if (attempts > 0) 'attempts': attempts,
        if (queuedAt != null) 'queued': queuedAt!.millisecondsSinceEpoch,
        if (sendStarted) 'sending': true,
      };

  static PendingAction? fromJson(Object? value) {
    if (value is! Map) return null;
    final action = value['action'];
    final message = value['message'];
    if (action is! String || message is! String) return null;
    if (action.isEmpty || message.isEmpty) return null;
    final queued = value['queued'];
    return PendingAction(
      actionId: action,
      messageId: message,
      typed: value['typed'] is String ? value['typed'] as String : null,
      attempts: value['attempts'] is int ? value['attempts'] as int : 0,
      queuedAt:
          queued is int ? DateTime.fromMillisecondsSinceEpoch(queued) : null,
      sendStarted: value['sending'] == true,
    );
  }
}

/// One press, claimed by one drain.
class ClaimedAction {
  ClaimedAction._(this.action, this._file, this._claim, this._token);

  final PendingAction action;
  final File _file;
  final File _claim;

  /// What this drain wrote into the claim, to know it is still its own.
  final String _token;

  ClaimedAction _as(PendingAction action) =>
      ClaimedAction._(action, _file, _claim, _token);
}

/// The claim on a press was taken over by another drain while this one was
/// frozen or asleep: the press is theirs now, and must not be sent, finished
/// or put back from here.
class LostClaim implements Exception {
  const LostClaim();

  @override
  String toString() => 'Another drain has taken this press over.';
}

/// The queue of pressed notification buttons, waiting to be carried out.
///
/// The press is written down first, which takes no time and cannot fail
/// halfway, and the work is done by something with a proper lifetime: the
/// WorkManager job, or the app when it opens. (Until 2.66.0 no press ever
/// reached here: the app did not declare the plugin's receiver, so Android
/// had nowhere to deliver one. This was built for a cause that was not the
/// cause, but it is still the right shape.)
///
/// One file per press, claimed by creating a `.claim` file beside it that
/// must not already exist. Three isolates use this — the one Android starts
/// for a button, the WorkManager job and the app — and creating a file that
/// must be new either happens or does not, on every system, so exactly one
/// drain gets each press. (A rename is not enough: on Windows two drains can
/// both rename the same file.)
///
/// Presses are claimed one at a time, as each is carried out, and a drain
/// keeps its claim fresh with [touch] while it works. A drain killed part
/// way, by Android stopping the job or the process dying, then strands one
/// press, not everything behind it, and only until its claim goes stale.
/// It used to claim them all up front and hold them for half an hour, while
/// the job that retried found nothing to do and called that success.
class PendingActions {
  PendingActions({Directory? directory, this._prefs}) : _given = directory;

  final Directory? _given;
  final SharedPreferencesAsync? _prefs;

  /// Where an earlier version kept the whole queue as one list.
  static const legacyKey = 'notify.pending.v1';

  /// How often a drain freshens the claim on the press it is working on.
  static const heartbeat = Duration(seconds: 20);

  /// A claim not freshened for this long belongs to a drain that died: the
  /// press goes back in the queue. Several heartbeats, so a busy moment is
  /// not taken for a death. A drain that was only frozen or asleep can be
  /// taken for dead too, which is safe: it finds its claim gone before it
  /// sends or finishes anything ([LostClaim]). A claim from another process
  /// is let go at once: every isolate of this app shares one process, so a
  /// different one means the owner died with it.
  static const abandonedAfter = Duration(minutes: 2);

  /// A half-written press older than this was left by a write that never
  /// finished; see [_recoverUnfinished].
  static const unfinishedAfter = Duration(minutes: 1);

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
    await _write(
      dir,
      _unique(),
      action.queuedAt == null ? action._with(queuedAt: DateTime.now()) : action,
    );
  }

  /// Written aside, then renamed into place, so a drain never reads half.
  /// The rename replaces a press already there in one step: the old one is
  /// never deleted first, so there is no moment with neither on disk.
  Future<void> _write(Directory dir, String name, PendingAction action) async {
    final temp = File(_in(dir, '$name.tmp'));
    await temp.writeAsString(jsonEncode(action.toJson()), flush: true);
    await temp.rename(_in(dir, '$name.json'));
  }

  /// The presses waiting, oldest first. Claim each with [claim] as it is
  /// about to be carried out.
  Future<List<File>> waiting() async {
    final dir = await _directory();
    await _bringInLegacy(dir);
    await _recoverUnfinished(dir);
    await _releaseAbandoned(dir);
    return [
      for (final entity in await dir.list().toList())
        if (entity is File && entity.path.endsWith('.json')) entity,
    ]..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Claim [file] for this caller alone.
  ///
  /// Null when it cannot be had. [held] says whether that is because another
  /// drain is working on it, as against it being gone or unreadable: a press
  /// held by a drain that then dies must be tried again later by someone.
  Future<({ClaimedAction? claimed, bool held})> claim(File file) async {
    final claim = File('${file.path}.claim');
    try {
      await claim.create(exclusive: true);
    } on FileSystemException {
      return (claimed: null, held: true); // Another drain has it.
    }
    final token = '$pid:${_unique()}';
    try {
      await claim.writeAsString(token, flush: true);
    } on FileSystemException {
      // Let go of under us, which only a stale-claim sweep does: someone
      // else has it now.
      return (claimed: null, held: true);
    }
    PendingAction? action;
    try {
      action = PendingAction.fromJson(jsonDecode(await file.readAsString()));
    } on FileSystemException {
      // Carried out and removed by another drain on the way here.
      await _delete(claim);
      return (claimed: null, held: false);
    } on FormatException {
      action = null;
    }
    if (action == null) {
      // Unreadable: carried around it would be tried for ever.
      await _delete(file);
      await _delete(claim);
      return (claimed: null, held: false);
    }
    return (claimed: ClaimedAction._(action, file, claim, token), held: false);
  }

  /// Whether [claim] is still this drain's: not let go of as stale and taken
  /// by another while this one was frozen or asleep.
  Future<bool> _stillMine(ClaimedAction claim) async {
    try {
      return await claim._claim.readAsString() == claim._token;
    } on FileSystemException {
      return false;
    }
  }

  /// Everything waiting, each claimed for this caller alone. For tests,
  /// which look at what is in the queue; a drain claims one at a time.
  @visibleForTesting
  Future<List<ClaimedAction>> take() async {
    final claimed = <ClaimedAction>[];
    for (final file in await waiting()) {
      final c = (await claim(file)).claimed;
      if (c != null) claimed.add(c);
    }
    return claimed;
  }

  /// Still working on it: keep the claim from going stale. Not a claim that
  /// has become someone else's, whose freshness is theirs to keep.
  Future<void> touch(ClaimedAction claim) async {
    if (!await _stillMine(claim)) return;
    try {
      await claim._claim.setLastModified(DateTime.now());
    } on FileSystemException {
      // Let go of already; nothing to keep fresh.
    }
  }

  /// Written down before a reply is sent, so that a drain killed during the
  /// send cannot lead to a second copy: see [PendingAction.sendStarted].
  ///
  /// Throws [LostClaim] if the press is no longer this drain's, checked on
  /// both sides of the write. Before, so a press another drain has finished
  /// is not written back into the queue; after, so a drain that takes it
  /// over from here on reads the mark and does not send it too.
  Future<ClaimedAction> markSending(ClaimedAction claim) async {
    if (!await _stillMine(claim)) throw const LostClaim();
    final marked = claim._as(claim.action._with(sendStarted: true));
    await _write(await _directory(), _baseOf(claim), marked.action);
    if (!await _stillMine(claim)) {
      // Finished by the other drain in between: what was just written would
      // be a press nobody made.
      if (!await claim._claim.exists()) await _delete(claim._file);
      throw const LostClaim();
    }
    return marked;
  }

  /// Carried out, or given up on: gone from the queue. The press first and
  /// then its claim, so no other drain can claim it in between. Nothing, if
  /// another drain has taken it over.
  Future<void> done(ClaimedAction claim) async {
    if (!await _stillMine(claim)) return;
    await _delete(claim._file);
    await _delete(claim._claim);
  }

  /// Not carried out, and worth another try later: back in the queue, in
  /// its old place. [counted] adds to its attempts; being offline is not
  /// counted, because it says nothing about whether the press can work.
  ///
  /// A reply put back was not sent, so the mark [markSending] made comes
  /// off, unless [keepSendMark] says the send may have gone.
  Future<void> putBack(
    ClaimedAction claim, {
    bool counted = true,
    bool keepSendMark = false,
  }) async {
    if (!await _stillMine(claim)) return;
    var action = counted ? claim.action.tried() : claim.action;
    if (!keepSendMark) action = action._with(sendStarted: false);
    // Replaced in place, and only then let go of: see _write.
    await _write(await _directory(), _baseOf(claim), action);
    await _delete(claim._claim);
  }

  static String _baseOf(ClaimedAction claim) {
    final name = claim._file.uri.pathSegments.last;
    return name.substring(0, name.length - '.json'.length);
  }

  /// Claims whose drain died: let go, so the press can be taken again. One
  /// written by another process at once; one of this process's once it has
  /// not been freshened for [abandonedAfter].
  Future<void> _releaseAbandoned(Directory dir) async {
    final cutoff = DateTime.now().subtract(abandonedAfter);
    for (final entity in await dir.list().toList()) {
      if (entity is! File || !entity.path.endsWith('.claim')) continue;
      try {
        final owner = int.tryParse((await entity.readAsString()).split(':').first);
        final elsewhere = owner != null && owner != pid;
        if (!elsewhere && (await entity.lastModified()).isAfter(cutoff)) {
          continue;
        }
        await entity.delete();
      } on FileSystemException {
        // Let go of by someone else in the meantime.
      }
    }
  }

  /// A write cut off between writing aside and renaming into place leaves a
  /// `.tmp` that nothing reads, and with it the press, typed reply and all.
  /// Once old enough that no write can still be under way, it is put where
  /// it was going; it is the newer of the two if both are there. Unless it
  /// was cut off before its contents were written: then the `.json` beside
  /// it, if any, is the last good copy, and the `.tmp` goes.
  Future<void> _recoverUnfinished(Directory dir) async {
    final cutoff = DateTime.now().subtract(unfinishedAfter);
    for (final entity in await dir.list().toList()) {
      if (entity is! File || !entity.path.endsWith('.tmp')) continue;
      try {
        if ((await entity.lastModified()).isAfter(cutoff)) continue;
        PendingAction? readable;
        try {
          readable =
              PendingAction.fromJson(jsonDecode(await entity.readAsString()));
        } on FormatException {
          readable = null;
        }
        if (readable == null) {
          await _delete(entity);
          continue;
        }
        final path = entity.path;
        await entity.rename('${path.substring(0, path.length - 4)}.json');
      } on FileSystemException {
        // Finished or cleared by someone else in the meantime.
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
