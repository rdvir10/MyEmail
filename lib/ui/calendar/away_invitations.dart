import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar/answered_invitations.dart';
import '../../data/calendar/away_run.dart';
import '../../domain/away.dart';
import '../../domain/mail_message.dart';
import '../../domain/message_move.dart';
import '../../state/calendar_view_providers.dart' show calendarPrefsProvider;
import '../../state/providers.dart';
import '../../state/waiting_changes.dart' show waitingToSync;
import '../../state/window_providers.dart';
import '../common/bottom_message.dart';
import '../messages/message_actions.dart';

/// The invitations to the meetings I am away declined (calendar idea #53),
/// cleared from the Inbox as Decline on a meeting's sheet clears one (#51),
/// where Settings, Calendar says an answered invitation goes to Deleted
/// Items: only an invitation the calendar ties to a meeting declined (a
/// series' never for one of its meetings), only once its decline went, and
/// said in one line with one Undo, never a bar for each.
///
/// Each is looked for before the press sends anything ([lookUp]): Exchange
/// takes a declined meeting off its calendar, and then has nothing to tie
/// its invitation to. Mail is moved from here, so anything uncertain stays:
/// a look that fails, or a move that fails, leaves the invitations where
/// they are, and the line says so.
class AwayInvitations {
  AwayInvitations._(this._container, this._sayOn);

  final ProviderContainer _container;

  /// Where it is said: the app's own, which outlasts the Away screen.
  final BuildContext _sayOn;

  /// Taken from [context], the Away screen, before the press. Null where
  /// Settings, Calendar keeps answered invitations in the Inbox.
  static AwayInvitations? before(BuildContext context, WidgetRef ref) {
    if (!ref.read(calendarPrefsProvider).deleteAnsweredInvites) return null;
    return AwayInvitations._(
      ProviderScope.containerOf(context, listen: false),
      Navigator.of(context, rootNavigator: true).context,
    );
  }

  /// Each decline's invitations as found, or null where looking failed.
  final Map<AwayItem, Future<List<PlacedInvitation>?>> _looked = {};

  /// The invitations of each decline among [items], and of its copies on
  /// Ron's other accounts, looked for now, before anything goes. Waited
  /// for, for [wait] at most: a decline sent before its look is done may
  /// leave its invitation, never take another.
  Future<void> lookUp(
    Iterable<AwayItem> items, {
    Duration wait = const Duration(seconds: 15),
  }) async {
    final engine = _container.read(mailEngineProvider);
    for (final item in items) {
      for (final one in [item, ...item.copies]) {
        if (one.action != AwayAction.decline || !one.open) continue;
        _looked[one] = placedInvitations(engine, one.event!).then(
          (placed) => placed,
          onError: (Object e) {
            debugPrint('[myemail] away: invitations not looked for: $e');
            return null;
          },
        );
      }
    }
    if (_looked.isEmpty) return;
    await Future.wait(_looked.values)
        .timeout(wait, onTimeout: () => <List<PlacedInvitation>?>[]);
  }

  /// Once the press is over: the invitations of the declines that went
  /// into Deleted Items, and said.
  Future<void> clear() async {
    final found = <String, MailMessage>{};
    var unsure = false;
    for (final MapEntry(key: item, value: look) in _looked.entries) {
      if (item.state != AwayState.done) continue;
      final placed = await look.timeout(const Duration(seconds: 5),
          onTimeout: () => null);
      if (placed == null) {
        unsure = true;
        continue;
      }
      for (final m in invitationsTo(item.event!, placed, wholeSeries: false)) {
        found[m.id] = m;
      }
    }
    const left = 'Some invitations could not be looked for: they are still '
        'in the Inbox.';
    if (found.isEmpty) {
      if (unsure) _say(left);
      return;
    }
    final messages = found.values.toList();
    final listId = _container.read(effectiveSelectedFolderIdProvider) ??
        messages.first.folderId;
    // One at a time: a delete of several that stops part way would leave
    // those already moved unsaid (the list's own go first, then the
    // rest), and they could not be put back.
    final actions = MessageActions.within(_container, listId);
    final moves = <MessageMove>[];
    var moved = 0;
    for (final m in messages) {
      try {
        moves.addAll(await actions.deleteQuietly([m]));
        moved++;
      } on PartialMove catch (e) {
        debugPrint('[myemail] away: an invitation moved part way: $e');
        moves.addAll(e.done);
        moved += e.moved.length;
      } catch (e) {
        debugPrint('[myemail] away: an invitation not deleted: $e');
      }
    }
    final n = messages.length;
    if (moved == 0) {
      _say('The invitations could not be moved to Deleted Items: they are '
          'still in the Inbox.');
      return;
    }
    _say(
      [
        if (moved < n)
          '$moved of $n invitations moved to Deleted Items; the rest are '
              'still in the Inbox.'
        else if (n == 1)
          '1 invitation moved to Deleted Items.'
        else
          '$n invitations moved to Deleted Items.',
        if (unsure) left,
        if (moves.any((m) => m.isWaiting)) waitingToSync,
      ].join(' '),
      moves: canUndoAll(moves, moved) ? moves : null,
      listId: listId,
    );
  }

  /// [text] along the bottom, with Undo where every invitation moved can
  /// be put back.
  void _say(String text, {List<MessageMove>? moves, String? listId}) {
    final messenger =
        _sayOn.mounted ? ScaffoldMessenger.maybeOf(_sayOn) : null;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('away-invitations'),
        duration: kBottomMessage,
        persist: false,
        content: Text(text),
        action: moves == null
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () => _container.read(workInFlightProvider).add(
                    undoMoves(_container, messenger, moves, listId!)),
              ),
      ));
  }
}
