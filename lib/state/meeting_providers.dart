import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../data/ui_state_store.dart';
import '../domain/meeting.dart';
import 'folder_tree.dart' show kUnifiedInboxId;
import 'providers.dart';

/// The account of the folder on screen, or null in the unified Inbox, where
/// there is no single answer.
///
/// What a new meeting is from unless it was started from a message: the
/// account whose mail is in front of the person is the one they mean, the
/// way a new message from the same folder is.
final accountOnScreenProvider = Provider<String?>((ref) {
  final folderId = ref.watch(effectiveSelectedFolderIdProvider);
  if (folderId == null || folderId == kUnifiedInboxId) return null;
  return ref.watch(folderIndexProvider)[folderId]?.accountId;
});

/// The online meetings the new-meeting screen made ahead of Send and has
/// not yet sent or undone, kept on the device.
///
/// The screen deletes its own when it is left, but an app closed with the
/// screen open leaves one on the calendar: an event with nobody on it, in
/// Ron's Outlook under whatever title was typed. The next start deletes
/// those ([dropLeftovers]). Only events: a Meet link made for a Microsoft
/// account has nothing to delete.
///
/// Each is kept with the process that made it. An app started again is a
/// new process, so what an earlier one kept is left over, however little
/// time has passed; what this one kept belongs to a screen still open,
/// perhaps in another window, and is left alone.
class PreparedMeetingLedger {
  PreparedMeetingLedger(
    this.store, {
    DateTime Function()? now,
    int? processId,
  })  : _now = now ?? DateTime.now,
        _process = processId ?? pid;

  final UiStateStore store;
  final DateTime Function() _now;
  final int _process;

  static const key = UiStateKeys.preparedMeetings;

  /// Each kept meeting, when it was made, and by which process (0 where
  /// that was not kept).
  List<({PreparedMeeting meeting, DateTime at, int process})> read() {
    final raw = store.readString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final kept = <({PreparedMeeting meeting, DateTime at, int process})>[];
      for (final entry in list) {
        final meeting = PreparedMeeting.fromJson(entry);
        if (meeting == null || meeting.eventId == null) continue;
        final at = (entry as Map)['at'];
        final process = entry['pid'];
        kept.add((
          meeting: meeting,
          // Past a date's range (8.64e15 ms either way) reads as long ago.
          at: DateTime.fromMillisecondsSinceEpoch(
            at is int && at.abs() <= 8640000000000000 ? at : 0,
          ),
          process: process is int ? process : 0,
        ));
      }
      return kept;
    } on FormatException {
      return const [];
    }
  }

  Future<void> _write(
    List<({PreparedMeeting meeting, DateTime at, int process})> all,
  ) =>
      store.writeString(
        key,
        all.isEmpty
            ? null
            : jsonEncode([
                for (final e in all)
                  {
                    ...e.meeting.toJson(),
                    'at': e.at.millisecondsSinceEpoch,
                    'pid': e.process,
                  },
              ]),
      );

  /// Keep [meeting] until it is sent or undone. Read again first: another
  /// window may have kept one since this one last looked, and writing back
  /// an old copy would lose it.
  Future<void> record(PreparedMeeting meeting) async {
    if (meeting.eventId == null) return;
    await store.reload();
    await _write([
      ...read().where((e) => !_same(e.meeting, meeting)),
      (meeting: meeting, at: _now(), process: _process),
    ]);
  }

  /// Sent or undone: nothing more to do about it.
  Future<void> forget(PreparedMeeting meeting) async {
    await store.reload();
    final all = read();
    final rest = all.where((e) => !_same(e.meeting, meeting)).toList();
    if (rest.length != all.length) await _write(rest);
  }

  /// Delete what an earlier run of the app left behind, however recently:
  /// what this run kept belongs to a screen still open, perhaps in another
  /// window, and is left alone. Each is deleted only while nobody is on it
  /// (see `MailEngine.discardPreparedMeeting`). One that could not be
  /// deleted now, the app started offline, is kept for the next start, up
  /// to [giveUpAfter].
  Future<void> dropLeftovers(
    MailEngine engine, {
    Duration giveUpAfter = const Duration(days: 7),
  }) async {
    await store.reload();
    final now = _now();
    for (final e in read()) {
      if (e.process == _process) continue;
      var done = false;
      try {
        done = await engine.discardPreparedMeeting(e.meeting);
      } catch (error) {
        debugPrint('[myemail] could not delete a meeting left made: $error');
      }
      if (done || e.at.isBefore(now.subtract(giveUpAfter))) {
        await forget(e.meeting);
      }
    }
  }

  static bool _same(PreparedMeeting a, PreparedMeeting b) =>
      a.accountId == b.accountId && a.eventId == b.eventId;
}

final preparedMeetingLedgerProvider = Provider<PreparedMeetingLedger>(
  (ref) => PreparedMeetingLedger(ref.watch(uiStateStoreProvider)),
);
