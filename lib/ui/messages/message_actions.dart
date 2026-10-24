import 'dart:async';

import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/message_move.dart';
import '../../state/folder_tree.dart';
import '../../state/follow_ups.dart';
import '../../state/list_filter.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/search_providers.dart';
import '../../state/sync_providers.dart' show backgroundSchedulerProvider;
import 'move_to_sheet.dart';

/// Move and delete, shared by the swipe gestures, the message menu and the
/// drop-onto-a-folder gesture, so all three behave the same.
///
/// Each reports what happened in a snackbar, because the message leaves the
/// list and there is otherwise nothing to see. Failures put the row back and
/// say why.
///
/// Where the whole thing can be put back, the snackbar offers Undo. A delete
/// is a move into Trash, so both are undone the same way: a move back to
/// where each message came from, using the ids the server gave them on the
/// way out. Undo is offered only when every message is accounted for — a
/// batch that was half moved and half deleted for good would come back half
/// its size, and an Undo that quietly does less than it says is worse than
/// none.
class MessageActions {
  MessageActions(WidgetRef ref, this.listId)
      : container = ProviderScope.containerOf(ref.context, listen: false);

  /// The app's container, taken while the widget is still there. Nothing
  /// here reads through the widget's own ref after that: an action outlives
  /// the widget that started it. Deleting from the reading pane on a tablet
  /// takes the pane away, since the pane is keyed by its message and the
  /// message leaves the list before the server has answered, and a ref
  /// belonging to a widget that has gone throws the moment it is read. A
  /// delete that had gone through was reported as "Could not delete: Bad
  /// state: Using "ref" when a widget is about to or has been unmounted is
  /// unsafe", with no Undo, and Ron saw it as "Bad ref".
  final ProviderContainer container;

  /// The list the message is being acted on from: a folder, or the unified
  /// inbox. Not necessarily the folder the message lives in.
  final String listId;

  /// True when anything moved. The sheet closed without a choice, or a
  /// move that failed outright, is false, so a selection can stay ticked
  /// for another try rather than be lost with nothing done to it.
  Future<bool> moveWithPrompt(
    BuildContext context,
    List<MailMessage> messages,
  ) async {
    if (messages.isEmpty) return false;
    // Opened on the first one's mailbox. Messages from several accounts,
    // ticked in the unified inbox, can go anywhere together all the same.
    final target = await showMoveToSheet(
      context,
      accountId: messages.first.accountId,
      fromFolderId: messages.first.folderId,
      messageCount: messages.length,
    );
    if (target == null || !context.mounted) return false;
    return moveTo(context, messages, target);
  }

  /// True when anything moved, as for [moveWithPrompt].
  Future<bool> moveTo(
    BuildContext context,
    List<MailMessage> messages,
    String toFolderId,
  ) async {
    if (messages.isEmpty) return false;
    final to = _reporterFor(context);
    final name = _destination(messages, toFolderId);
    final (held, elsewhere) = _split(messages);
    final moves = <MessageMove>[];
    try {
      if (held.isNotEmpty) {
        moves.addAll(await container
            .read(messagesProvider(listId).notifier)
            .move([for (final m in held) m.id], toFolderId));
        _refreshSearch();
      }
      if (elsewhere.isNotEmpty) {
        moves.addAll(await container
            .read(mailEngineProvider)
            .moveMessages([for (final m in elsewhere) m.id], toFolderId));
        _afterEngineChange(elsewhere, touched: [
          for (final m in moves) ...m.landedIn,
          toFolderId,
        ]);
      }
      container.read(recentMoveTargetsProvider.notifier).record(toFolderId);
      _say(
        to,
        '${_count(messages.length)} moved to $name',
        undo: moves,
        of: messages.length,
      );
      return true;
    } on PartialMove catch (part) {
      // Some went: say how many, and offer those back. Those from elsewhere
      // that went are in lists here all the same, which the list's own move
      // would have re-read and the engine's does not.
      final done = [...moves, ...part.done];
      if (elsewhere.isNotEmpty) {
        _afterEngineChange(elsewhere, touched: [
          for (final m in done) ...m.landedIn,
          toFolderId,
        ]);
      }
      final n = done.fold(0, (sum, m) => sum + m.count);
      _say(to, 'Moved $n of ${messages.length}. ${part.message}',
          undo: done, of: n);
      return true;
    } catch (e) {
      _say(to, 'Could not move: $e');
      return moves.isNotEmpty;
    }
  }

  /// Into each account's archive, as Outlook's Archive: the Archive folder
  /// on a Microsoft account, and on Gmail out of this folder into All Mail,
  /// which takes the folder's label off as Gmail's own Archive does (out
  /// of the Inbox, the Inbox label). Messages from several accounts go to
  /// each one's own, with one report and one Undo. True when anything went.
  Future<bool> archive(
    BuildContext context,
    List<MailMessage> messages,
  ) =>
      _toEach(
        context,
        messages,
        targetFor: archiveTargetFor,
        done: (n) => n == 1 ? 'Message archived' : '$n messages archived',
        partly: 'Archived',
        failed: 'Could not archive',
        nowhere: 'This account has no Archive folder.',
        already: 'Already in the archive.',
      );

  /// Snooze [messages] until [until]: off the list now, back in its folder,
  /// unread, then; see [MailEngine.snooze]. [said] is the report, with an
  /// Undo that puts them back at once. True when anything went.
  Future<bool> snooze(
    BuildContext context,
    List<MailMessage> messages,
    DateTime until, {
    required String said,
  }) async {
    if (messages.isEmpty) return false;
    final to = _reporterFor(context);
    final (held, elsewhere) = _split(messages);
    final engine = container.read(mailEngineProvider);
    final moves = <MessageMove>[];
    try {
      if (held.isNotEmpty) {
        moves.addAll(await container
            .read(messagesProvider(listId).notifier)
            .snooze([for (final m in held) m.id], until));
        _refreshSearch();
      }
      if (elsewhere.isNotEmpty) {
        moves.addAll(
            await engine.snooze([for (final m in elsewhere) m.id], until));
        _afterEngineChange(elsewhere, touched: [
          for (final m in moves) ...m.landedIn,
        ]);
      }
    } catch (e) {
      _say(to, 'Could not snooze: $e');
      return moves.isNotEmpty;
    }
    // The background brings it back at its time, as the app does in front.
    try {
      await container
          .read(backgroundSchedulerProvider)
          .scheduleWake(await engine.nextSnoozeWake());
    } catch (_) {
      // The regular passes bring it back all the same.
    }
    final went = moves.fold(0, (int n, m) => n + m.count);
    if (went == 0) {
      _say(to, 'That has no Message-ID to find it by again, so it cannot be '
          'snoozed.');
      return false;
    }
    _say(to, said, undo: moves, of: went);
    return true;
  }

  /// Into each account's Junk folder: Block Sender's first half. [said] is
  /// what the report says when all went, and [alsoUndo] runs with its Undo.
  Future<bool> junk(
    BuildContext context,
    List<MailMessage> messages, {
    String? said,
    VoidCallback? alsoUndo,
  }) =>
      _toEach(
        context,
        messages,
        targetFor: (folders, accountId) =>
            folderWithRole(folders, accountId, FolderRole.junk),
        done: (n) =>
            said ?? (n == 1 ? 'Moved to Junk' : '$n messages moved to Junk'),
        partly: 'Moved',
        failed: 'Could not move to Junk',
        nowhere: 'This account has no Junk folder.',
        already: 'Already in Junk.',
        alsoUndo: alsoUndo,
      );

  /// Out of Junk into each account's Inbox: Not Junk's first half. As
  /// [junk] for [said] and [alsoUndo].
  Future<bool> toInbox(
    BuildContext context,
    List<MailMessage> messages, {
    String? said,
    VoidCallback? alsoUndo,
  }) =>
      _toEach(
        context,
        messages,
        targetFor: (folders, accountId) =>
            folderWithRole(folders, accountId, FolderRole.inbox),
        done: (n) => said ?? (n == 1 ? 'Moved to Inbox' : '$n moved to Inbox'),
        partly: 'Moved',
        failed: 'Could not move to the Inbox',
        nowhere: 'This account has no Inbox.',
        already: 'Already in the Inbox.',
        alsoUndo: alsoUndo,
      );

  /// [messages] into the folder [targetFor] names for each one's account,
  /// with one report and one Undo for them all. True when anything went.
  Future<bool> _toEach(
    BuildContext context,
    List<MailMessage> messages, {
    required String? Function(
      Map<String, List<MailFolder>> folders,
      String accountId,
    ) targetFor,
    required String Function(int n) done,
    required String partly,
    required String failed,
    required String nowhere,
    required String already,
    VoidCallback? alsoUndo,
  }) async {
    if (messages.isEmpty) return false;
    final to = _reporterFor(context);
    final folders = container.read(foldersProvider).value ?? const {};
    final groups = <String, List<MailMessage>>{};
    var none = false;
    for (final m in messages) {
      final target = targetFor(folders, m.accountId);
      if (target == null) {
        none = true;
      } else if (m.folderId != target) {
        (groups[target] ??= []).add(m);
      }
    }
    if (groups.isEmpty) {
      _say(to, none ? nowhere : already);
      return false;
    }
    final moves = <MessageMove>[];
    var count = 0;
    try {
      for (final MapEntry(key: target, value: some) in groups.entries) {
        moves.addAll(await _moveAll(some, target));
        count += some.length;
      }
      _say(to, done(count), undo: moves, of: count, alsoUndo: alsoUndo);
      return true;
    } on PartialMove catch (part) {
      final went = [...moves, ...part.done];
      final n = went.fold(0, (sum, m) => sum + m.count);
      _say(to, '$partly $n of ${messages.length}. ${part.message}',
          undo: went, of: n, alsoUndo: alsoUndo);
      return true;
    } catch (e) {
      _say(to, '$failed: $e');
      return moves.isNotEmpty;
    }
  }

  /// [messages] into [toFolderId], through the list for the ones it holds
  /// and the engine for the rest, every list that shows them read again.
  /// A failure after some went is a [PartialMove] naming all that did.
  Future<List<MessageMove>> _moveAll(
    List<MailMessage> messages,
    String toFolderId,
  ) async {
    final (held, elsewhere) = _split(messages);
    final moves = <MessageMove>[];
    try {
      if (held.isNotEmpty) {
        moves.addAll(await container
            .read(messagesProvider(listId).notifier)
            .move([for (final m in held) m.id], toFolderId));
        _refreshSearch();
      }
      if (elsewhere.isNotEmpty) {
        moves.addAll(await container
            .read(mailEngineProvider)
            .moveMessages([for (final m in elsewhere) m.id], toFolderId));
        _afterEngineChange(elsewhere, touched: [
          for (final m in moves) ...m.landedIn,
          toFolderId,
        ]);
      }
      return moves;
    } on PartialMove catch (part) {
      final done = [...moves, ...part.done];
      if (elsewhere.isNotEmpty) {
        _afterEngineChange(elsewhere, touched: [
          for (final m in done) ...m.landedIn,
          toFolderId,
        ]);
      }
      throw PartialMove(done: done, moved: part.moved, cause: part.cause);
    } catch (e) {
      if (moves.isEmpty) rethrow;
      throw PartialMove(done: moves, moved: const [], cause: e);
    }
  }

  Future<void> delete(
    BuildContext context,
    List<MailMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    final to = _reporterFor(context);
    final (held, elsewhere) = _split(messages);
    final moves = <MessageMove>[];
    try {
      if (held.isNotEmpty) {
        moves.addAll(await container
            .read(messagesProvider(listId).notifier)
            .delete([for (final m in held) m.id]));
        _refreshSearch();
      }
      if (elsewhere.isNotEmpty) {
        final gone = await container
            .read(mailEngineProvider)
            .deleteMessages([for (final m in elsewhere) m.id]);
        moves.addAll(gone);
        _afterEngineChange(
          elsewhere,
          touched: [for (final m in gone) m.toFolderId],
        );
      }
      _say(
        to,
        '${_count(messages.length)} deleted',
        undo: moves,
        of: messages.length,
      );
    } on PartialMove catch (part) {
      final done = [...moves, ...part.done];
      final n = part.moved.length +
          moves.fold<int>(0, (sum, m) => sum + m.count);
      _say(to, 'Deleted $n of ${messages.length}. ${part.message}',
          undo: done, of: n);
    } catch (e) {
      _say(to, 'Could not delete: $e');
    }
  }

  /// Read or unread, for several at once.
  Future<void> setRead(
    BuildContext context,
    List<MailMessage> messages,
    bool isRead,
  ) =>
      _setEach(
        context,
        messages,
        held: (n, ids) => n.setMessagesRead(ids, isRead),
        engine: (e, ids) => e.setMessagesRead(ids, isRead),
        what: isRead ? 'mark read' : 'mark unread',
      );

  Future<void> setFlagged(
    BuildContext context,
    List<MailMessage> messages,
    bool isFlagged,
  ) {
    // The flag off takes its day and its reminder with it.
    if (!isFlagged) container.read(followUpsProvider.notifier).forget(messages);
    return _setEach(
      context,
      messages,
      held: (n, ids) => n.setMessagesFlagged(ids, isFlagged),
      engine: (e, ids) => e.setMessagesFlagged(ids, isFlagged),
      what: isFlagged ? 'flag' : 'unflag',
    );
  }

  /// Outlook's Follow Up: flagged for [due] (no date where it is null), or
  /// with [complete] marked complete; see [MailEngine.setFollowUp]. The day
  /// is kept on this device as well, for the accounts that keep none;
  /// complete forgets it, and the reminder with it.
  Future<void> followUp(
    BuildContext context,
    List<MailMessage> messages, {
    DateTime? due,
    bool complete = false,
  }) {
    final store = container.read(followUpsProvider.notifier);
    if (complete) {
      store.forget(messages);
    } else {
      for (final m in messages) {
        store.setDue(m, due);
      }
    }
    return _setEach(
      context,
      messages,
      held: (n, ids) => n.setFollowUp(ids, due: due, complete: complete),
      engine: (e, ids) => e.setFollowUp(ids, due: due, complete: complete),
      what: complete ? 'mark complete' : 'flag',
    );
  }

  /// Read, because it was opened, as Outlook does: [setRead] without a word
  /// said, whatever happens, since it is not something the person did.
  ///
  /// The reading pane did this on its own, through the list alone or the
  /// engine alone, and a search hit opened stayed bold in the results with
  /// the pane offering "Mark as read". It also used the pane's ref after
  /// the server answered, by when the pane may have gone to the next
  /// message, so the folder the hit lives in was not read again either.
  Future<void> markOpened(MailMessage message) async {
    final (held, elsewhere) = _split([message]);
    try {
      if (held.isNotEmpty) {
        await container
            .read(messagesProvider(listId).notifier)
            .setRead(message.id, true);
        _refreshSearch();
      } else {
        await container.read(mailEngineProvider).setRead(message.id, true);
        _afterEngineChange(elsewhere);
      }
    } catch (_) {
      // Offline or refused: the message simply stays unread. Nothing to tell
      // the user about an action they did not take.
    }
  }

  /// One change, on every message, whatever happens to any one of them.
  ///
  /// It stopped at the first that failed and said nothing, leaving the rest
  /// untouched and the ticks in place. Now each is tried, and what failed is
  /// counted and said.
  ///
  /// They go to the engine together rather than one by one, so a Microsoft
  /// account sends twenty to a request: sixty flagged were sixty requests
  /// end to end, seconds on a phone.
  Future<void> _setEach(
    BuildContext context,
    List<MailMessage> messages, {
    required Future<void> Function(Messages, List<String>) held,
    required Future<void> Function(MailEngine, List<String>) engine,
    required String what,
  }) async {
    if (messages.isEmpty) return;
    final to = _reporterFor(context);
    final (here, elsewhere) = _split(messages);
    var failed = 0;
    Object? why;
    Future<void> change(
      List<MailMessage> some,
      Future<void> Function(List<String>) apply,
    ) async {
      try {
        await apply([for (final m in some) m.id]);
      } on PartialFlagChange catch (part) {
        failed += part.failed.length;
        why ??= part;
      } catch (e) {
        failed += some.length;
        why ??= e;
      }
    }

    if (here.isNotEmpty) {
      final notifier = container.read(messagesProvider(listId).notifier);
      await change(here, (ids) => held(notifier, ids));
    }
    if (elsewhere.isNotEmpty) {
      final mail = container.read(mailEngineProvider);
      await change(elsewhere, (ids) => engine(mail, ids));
      _afterEngineChange(elsewhere);
    } else {
      _refreshSearch();
    }
    if (failed > 0) {
      _say(to, messages.length == 1
          ? 'Could not $what it: $why'
          : 'Could not $what $failed of ${messages.length}: $why');
    }
  }

  /// A search on screen shows the messages just changed, so it is asked
  /// again. It was only asked for a hit from another folder: one the open
  /// list also held stayed in the results as it was, deleted or not.
  void _refreshSearch() {
    if (container.read(searchQueryProvider).trim().isNotEmpty) {
      container.invalidate(searchResultsProvider);
    }
    // And what a filter found on the server, which is from before this:
    // a message deleted from the list would come back from it.
    container.invalidate(filterHitsProvider);
  }

  /// The messages this list holds, and the rest.
  ///
  /// A search hit can live in any folder of any account, and the list's
  /// notifier only knows the rows it is showing: asked about a message it
  /// does not hold, it does nothing, quietly. Those go to the engine
  /// directly, and every list that might show them is re-read afterwards.
  (List<MailMessage>, List<MailMessage>) _split(List<MailMessage> messages) {
    final held = {
      for (final m in container.read(messagesProvider(listId)).value ?? const [])
        m.id,
    };
    return (
      [for (final m in messages) if (held.contains(m.id)) m],
      [for (final m in messages) if (!held.contains(m.id)) m],
    );
  }

  /// Every list that might show [changed] read again, and the folder counts
  /// of every account they touched.
  ///
  /// The counts follow without anything waiting for them, as they do after
  /// the list's own delete: refreshing an account is a full folder listing
  /// over the network, two for a move across accounts. Awaited, the report
  /// and its Undo came only after those, and a listing that failed (a
  /// sign-in to renew, a server's NO) made a delete that had gone through
  /// read "Could not delete", with no Undo, and escaped a flag altogether.
  void _afterEngineChange(
    List<MailMessage> changed, {
    List<String> touched = const [],
  }) {
    for (final folderId in {
      ...changed.map((m) => m.folderId),
      ...touched,
      kUnifiedInboxId,
      kFlaggedId,
    }) {
      container.invalidate(messagesProvider(folderId));
    }
    container.invalidate(searchResultsProvider);
    container.invalidate(filterHitsProvider);
    final index = container.read(folderIndexProvider);
    for (final accountId in {
      ...changed.map((m) => m.accountId),
      for (final id in touched) ?index[id]?.accountId,
    }) {
      unawaited(container
          .read(foldersProvider.notifier)
          .refreshAccount(accountId)
          .catchError((Object _) {}));
    }
  }

  static String _count(int n) => n == 1 ? 'Message' : '$n messages';

  /// The folder's name, and its mailbox's after it where that is not where
  /// the messages were: "Receipts in Gmail".
  String _destination(List<MailMessage> messages, String toFolderId) {
    final folder = container.read(folderIndexProvider)[toFolderId];
    if (folder == null) return '';
    if (messages.every((m) => m.accountId == folder.accountId)) {
      return folder.displayName;
    }
    final account = (container.read(accountsProvider).value ?? const [])
        .where((a) => a.id == folder.accountId)
        .firstOrNull;
    return account == null
        ? folder.displayName
        : '${folder.displayName} in ${account.displayName}';
  }

  /// [undo] and [of] together decide whether the Undo link appears: the
  /// moves must cover every one of the [of] messages acted on.
  ///
  /// The link's work is done through the [ProviderContainer], as is
  /// everything else here: a snackbar outlives the widget that raised it,
  /// and so does the action itself. See [container].
  void _say(
    _Reporter to,
    String message, {
    List<MessageMove>? undo,
    int of = 0,
    VoidCallback? alsoUndo,
  }) {
    final messenger = to.messenger;
    final offer = undo != null && canUndoAll(undo, of);
    final container = offer ? to.container : null;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, persist: false,
        content: Text(message),
        action: offer
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () {
                  alsoUndo?.call();
                  undoMoves(container!, messenger, undo, listId);
                },
              )
            : null,
      ));
  }

  /// Everything saying something needs, taken while the widget is still
  /// there to take it from.
  ///
  /// A swipe is why this exists. The row that was swiped is dismissed
  /// before the delete finishes, so by the time there is anything to
  /// report its `BuildContext` is gone — and the report was guarded by
  /// `context.mounted`, so it simply never appeared. No message, and no
  /// Undo with it, on the one gesture people use most.
  _Reporter _reporterFor(BuildContext context) => _Reporter(
        messenger: ScaffoldMessenger.of(context),
        container: container,
      );
}

class _Reporter {
  const _Reporter({required this.messenger, required this.container});

  final ScaffoldMessengerState messenger;
  final ProviderContainer container;
}

/// [accountId]'s folder of [role], or null where it has none or its
/// folders are not known yet.
String? folderWithRole(
  Map<String, List<MailFolder>> folders,
  String accountId,
  FolderRole role,
) {
  for (final f in folders[accountId] ?? const <MailFolder>[]) {
    if (f.role == role) return f.id;
  }
  return null;
}

/// Where Archive puts [accountId]'s mail: an Archive folder that takes
/// mail, as Microsoft's does, or else Gmail's All Mail, which a message
/// reaches by losing the folder's label. Null for an account with neither,
/// or whose folders are not known yet.
String? archiveTargetFor(
  Map<String, List<MailFolder>> folders,
  String accountId,
) {
  final archives = [
    for (final f in folders[accountId] ?? const <MailFolder>[])
      if (f.role == FolderRole.archive) f,
  ];
  return (archives.where((f) => f.capabilities.canAcceptMessages).firstOrNull ??
          archives.firstOrNull)
      ?.id;
}

/// Put back what a move or a delete took away.
///
/// Free of any widget on purpose: see [MessageActions._say]. The ids used
/// are the ones the messages have now, in the folder they landed in, or
/// their Message-IDs where the server never said.
Future<void> undoMoves(
  ProviderContainer container,
  ScaffoldMessengerState messenger,
  List<MessageMove> moves,
  String listId,
) async {
  try {
    try {
      await container.read(mailEngineProvider).undoMoves(moves);
    } finally {
      // Whether or not all of it went. An undo across two accounts can put
      // the first back and then fail on the second, and the lists, left
      // alone, showed neither the messages restored nor Trash without them.
      final index = container.read(folderIndexProvider);
      for (final folderId in {
        listId,
        kUnifiedInboxId,
        kFlaggedId,
        for (final m in moves) ...[m.fromFolderId, ...m.landedIn],
      }) {
        container.invalidate(messagesProvider(folderId));
      }
      container.invalidate(searchResultsProvider);
      for (final accountId in {
        for (final m in moves) ...[
          ?index[m.fromFolderId]?.accountId,
          ?index[m.toFolderId]?.accountId,
        ],
      }) {
        // Not allowed to hide why the undo itself failed.
        await container
            .read(foldersProvider.notifier)
            .refreshAccount(accountId)
            .catchError((Object _) {});
      }
    }
    final total = moves.fold(0, (int n, m) => n + m.count);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, 
        content: Text('${total == 1 ? 'Message' : '$total messages'} put back'),
      ));
  } catch (e) {
    // Whatever went wrong, the messages are still where the move left them.
    // Saying so is more use than failing silently.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not undo: $e')));
  }
}
