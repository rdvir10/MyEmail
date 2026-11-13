import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../domain/pending_change.dart';
import 'folder_tree.dart';
import 'message_providers.dart';
import 'providers.dart';

/// Changes made here that are waiting for their server, by account: how
/// many, for the line over the list that says so, and the sending of them
/// while the app is in front. See [KeepsChangesForLater].
///
/// The background sends them too, in every pass and in a job of its own
/// that Android runs when it sees a network; this is so that someone
/// looking at the list sees them go as soon as the server answers.
class WaitingChanges extends Notifier<Map<String, int>> {
  Timer? _soon;
  Future<SentChanges?>? _sending;

  @override
  Map<String, int> build() {
    ref.onDispose(() => _soon?.cancel());
    // Changes kept before the app was last closed.
    unawaited(Future.microtask(refresh));
    return const {};
  }

  KeepsChangesForLater? get _keeps => switch (ref.read(mailEngineProvider)) {
        final KeepsChangesForLater keeps => keeps,
        _ => null,
      };

  /// How many are waiting, read again.
  Future<void> refresh() async {
    if (!ref.mounted) return;
    final keeps = _keeps;
    if (keeps == null) return;
    final now = await keeps.changesWaiting();
    if (ref.mounted && !mapEquals(now, state)) state = now;
  }

  /// After a move, a delete or a mark, any of which may have been kept for
  /// later: read again, and anything waiting sent once its Undo has run
  /// out, should the server be answering by then.
  Future<void> changed() async {
    await refresh();
    if (!ref.mounted || state.isEmpty) return;
    _soon?.cancel();
    _soon = Timer(
      changesHeldFor + const Duration(seconds: 2),
      () => unawaited(send()),
    );
  }

  /// [send] where anything is waiting, and otherwise only what the
  /// background gave up on said: for the app's minute, and coming back to
  /// it.
  Future<void> sendIfWaiting() async {
    await refresh();
    if (!ref.mounted) return;
    if (state.isNotEmpty) {
      await send();
    } else {
      await _tellGivenUp();
    }
  }

  /// Send what is waiting now, and show what came of it: the lists of the
  /// folders it touched read again, and their counts, and what was given
  /// up on said (see [failedChangesProvider]). One at a time: asked again
  /// meanwhile, it answers with the one under way. With [evenJustMade],
  /// for Try now, a change still held for its Undo goes too. Null where
  /// the engine keeps nothing for later, or the send could not be made.
  Future<SentChanges?> send({bool evenJustMade = false}) =>
      _sending ??= _send(evenJustMade: evenJustMade)
          .catchError((Object e) {
        // Never meant to happen: the engine's send does not throw. Said in
        // the log rather than lost in a timer.
        debugPrint('[myemail] changes waiting not sent: $e');
        return null;
      }).whenComplete(() => _sending = null);

  Future<SentChanges?> _send({required bool evenJustMade}) async {
    final keeps = _keeps;
    if (keeps == null) return null;
    final sent = await keeps.sendWaitingChanges(evenJustMade: evenJustMade);
    if (!ref.mounted) return sent;
    if (sent.sent > 0 || sent.failed > 0) {
      for (final id in {...sent.folders, kUnifiedInboxId, kFlaggedId}) {
        ref.invalidate(messagesProvider(id));
      }
      final index = ref.read(folderIndexProvider);
      for (final accountId in {
        for (final id in sent.folders) ?index[id]?.accountId,
      }) {
        unawaited(ref
            .read(foldersProvider.notifier)
            .refreshAccount(accountId)
            .catchError((Object _) {}));
      }
    }
    await _tellGivenUp();
    await refresh();
    return sent;
  }

  Future<void> _tellGivenUp() async {
    final keeps = _keeps;
    if (keeps == null) return;
    final failed = await keeps.takeFailedChanges();
    if (failed.isEmpty || !ref.mounted) return;
    ref.read(failedChangesProvider.notifier).add(failed);
    // Back in their folders: the lists show them again.
    for (final f in failed) {
      ref.invalidate(messagesProvider(f.fromFolderId));
    }
    ref.invalidate(messagesProvider(kUnifiedInboxId));
    ref.invalidate(messagesProvider(kFlaggedId));
  }
}

final waitingChangesProvider =
    NotifierProvider<WaitingChanges, Map<String, int>>(WaitingChanges.new);

/// Changes given up on, waiting to be said, oldest first. The app shell
/// takes them as they come and says each.
class FailedChanges extends Notifier<List<FailedChange>> {
  @override
  List<FailedChange> build() => const [];

  void add(List<FailedChange> more) => state = [...state, ...more];

  List<FailedChange> take() {
    final all = state;
    if (all.isNotEmpty) state = const [];
    return all;
  }
}

final failedChangesProvider =
    NotifierProvider<FailedChanges, List<FailedChange>>(FailedChanges.new);

/// What a change given up on comes to, in a sentence: what could not be
/// done, what the server said, and, for one that took mail out of a folder,
/// that it is back there. [from] and [to] name the folders.
String failedChangeSaid(FailedChange f, {required String from, String? to}) {
  final subject = f.subject?.trim();
  final what = f.count > 1
      ? '${f.count} messages'
      : subject == null || subject.isEmpty
          ? 'a message'
          : '"$subject"';
  final (verb, after) = switch (f.kind) {
    PendingKind.delete => ('delete', ''),
    PendingKind.move => ('move', to == null ? '' : ' to $to'),
    PendingKind.read => ('mark', f.wanted == false ? ' unread' : ' read'),
    PendingKind.flag => (f.wanted == false ? 'unflag' : 'flag', ''),
    PendingKind.followUp =>
      f.wanted == false ? ('mark', ' complete') : ('flag', ''),
  };
  final reason = f.reason.trim();
  final said = reason.endsWith('.') ? reason : '$reason.';
  final back = !f.kind.removes
      ? ''
      : f.count > 1
          ? ' They are back in $from.'
          : ' It is back in $from.';
  return 'Could not $verb $what$after: $said$back';
}

/// What a report of a move, a delete or Archive adds where it went no
/// further than this device: see [MessageMove.isWaiting].
const waitingToSync = 'It will sync when the connection is back.';
