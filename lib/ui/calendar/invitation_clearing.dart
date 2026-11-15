import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar/answered_invitations.dart';
import '../../domain/calendar_event.dart';
import '../../domain/mail_message.dart';
import '../../domain/message_move.dart';
import '../../state/calendar_view_providers.dart' show calendarPrefsProvider;
import '../../state/providers.dart';
import '../../state/waiting_changes.dart' show waitingToSync;
import '../../state/window_providers.dart';
import '../common/bottom_message.dart';
import '../messages/message_actions.dart';

/// A meeting answered in the calendar takes its invitation out of the Inbox
/// (#51), where Settings, Calendar says an answered invitation goes to
/// Deleted Items: as one answered from its own card goes, with the same
/// words and Undo. Only one the calendar ties to the meeting goes; see
/// [placedInvitations] and [invitationsTo].
///
/// The calendar is asked before the answer goes ([lookUp]), from the moment
/// Accept, Maybe or Decline is pressed: Exchange takes a declined meeting
/// off the calendar, and after that has nothing to tie its invitation to.
/// The answer never waits for it.
class InvitationClearing {
  const InvitationClearing._(this._container, this._sayOn);

  final ProviderContainer _container;

  /// Where it is said: the app's own, which outlasts the screen the answer
  /// was given on.
  final BuildContext _sayOn;

  /// Taken from [context], the screen the answer is given on, before the
  /// answer goes, since that screen may be gone by the time it has. Null
  /// where Settings, Calendar keeps answered invitations in the Inbox.
  static InvitationClearing? before(BuildContext context, WidgetRef ref) {
    if (!ref.read(calendarPrefsProvider).deleteAnsweredInvites) return null;
    return InvitationClearing._(
      ProviderScope.containerOf(context, listen: false),
      Navigator.of(context, rootNavigator: true).context,
    );
  }

  /// [event]'s likely invitations looked for, and placed on the calendar,
  /// starting now, while it still has [event]: before its answer goes.
  InvitationLookup lookUp(CalendarEvent event) =>
      InvitationLookup._(_place(event));

  Future<List<PlacedInvitation>> _place(CalendarEvent event) async {
    try {
      final engine = _container.read(mailEngineProvider);
      return await placedInvitations(engine, event);
    } catch (e) {
      debugPrint('[myemail] invitations not looked for: $e');
      return const [];
    }
  }

  /// [event] answered, [said] the answer's words (with [wholeSeries], for
  /// every meeting of its series), and [lookup] what was looked for before
  /// it went.
  ///
  /// Looked through by now, as it mostly is, and its invitation goes: one
  /// bar, the answer's words and where the invitation went, with Undo, as
  /// from the invitation's card. Still looking: the answer's words at once,
  /// and once its invitation has gone, that said over them while they are
  /// still up, or else on a line of its own naming the meeting, which waits
  /// behind whatever is up and never takes its place. Where nothing is sure
  /// to be [event]'s invitation, or it cannot be deleted, the answer's
  /// words stand alone.
  Future<void> answered(
    CalendarEvent event, {
    required String said,
    required InvitationLookup lookup,
    bool wholeSeries = false,
  }) async {
    try {
      final ready = lookup.found;
      if (ready != null) {
        final sure = invitationsTo(event, ready, wholeSeries: wholeSeries);
        final gone = sure.isEmpty ? null : await _delete(sure);
        if (gone == null) {
          _say(said);
        } else {
          _say('$said ${_whereFor(sure)}', gone: gone, count: sure.length);
        }
        return;
      }
      final own = _say(said);
      final sure = invitationsTo(event, await lookup.done,
          wholeSeries: wholeSeries);
      if (sure.isEmpty) return;
      final gone = await _delete(sure);
      if (gone == null) return;
      if (own.onScreen) {
        _say('$said ${_whereFor(sure)}', gone: gone, count: sure.length);
        return;
      }
      final name = event.title.trim();
      _say(
        sure.length == 1
            ? 'The invitation to $name is in Deleted Items.'
            : 'The invitations to $name are in Deleted Items.',
        gone: gone,
        count: sure.length,
        behind: true,
      );
    } catch (e) {
      debugPrint('[myemail] an answered invitation was not cleared: $e');
    }
  }

  static String _whereFor(List<MailMessage> sure) => sure.length == 1
      ? 'The invitation is in Deleted Items.'
      : 'The invitations are in Deleted Items.';

  /// [found] into Deleted Items, saying nothing yet, through the list on
  /// screen, as the reading pane deletes: where it holds the invitation,
  /// the row goes from it at once. The moves and that list, for Undo; null
  /// where they could not be deleted.
  Future<({List<MessageMove> moves, String listId})?> _delete(
    List<MailMessage> found,
  ) async {
    try {
      final listId = _container.read(effectiveSelectedFolderIdProvider) ??
          found.first.folderId;
      final moves = await MessageActions.within(_container, listId)
          .deleteQuietly(found);
      return (moves: moves, listId: listId);
    } catch (e) {
      debugPrint('[myemail] an answered invitation was not deleted: $e');
      return null;
    }
  }

  /// [text] along the bottom, with Undo where all [count] invitations
  /// [gone] can be put back: in place of the bar on screen, as every
  /// action's report takes it, or with [behind], after it. What it answers
  /// says whether it is up.
  _Bar _say(
    String text, {
    ({List<MessageMove> moves, String listId})? gone,
    int count = 0,
    bool behind = false,
  }) {
    final bar = _Bar();
    final messenger =
        _sayOn.mounted ? ScaffoldMessenger.maybeOf(_sayOn) : null;
    if (messenger == null) return bar;
    final moves = gone?.moves ?? const <MessageMove>[];
    final waiting = moves.any((m) => m.isWaiting);
    void undo() => _container.read(workInFlightProvider).add(
        undoMoves(_container, messenger, moves, gone!.listId));
    if (!behind) messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(SnackBar(
          duration: kBottomMessage,
          persist: false,
          content: Text(waiting ? '$text $waitingToSync' : text),
          action: gone != null && canUndoAll(moves, count)
              ? SnackBarAction(label: 'Undo', onPressed: undo)
              : null,
        ))
        .closed
        .then((_) => bar.closed = true);
    return bar;
  }
}

/// A bar said along the bottom: whether it is still up. Any other bar
/// said since in its place has closed it; one said behind it waits.
/// (Flutter's onVisible is not told again when a bar moves to another
/// screen's Scaffold, as when the calendar is left, so it is not asked.)
class _Bar {
  bool closed = false;

  bool get onScreen => !closed;
}

/// A meeting's invitations being looked for ahead of its answer (see
/// [InvitationClearing.lookUp]): what was found, once it is.
class InvitationLookup {
  InvitationLookup._(this.done) {
    done.then((placed) => _found = placed);
  }

  /// Done when the looking is; never fails.
  final Future<List<PlacedInvitation>> done;

  List<PlacedInvitation>? _found;

  /// What was found, once the looking is done; null while it goes on.
  List<PlacedInvitation>? get found => _found;
}
