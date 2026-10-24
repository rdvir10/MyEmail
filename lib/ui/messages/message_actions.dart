import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart';
import '../../domain/mail_message.dart';
import '../../domain/message_move.dart';
import '../../state/folder_tree.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/search_providers.dart';
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
        await _afterEngineChange(elsewhere, touched: [
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
      // Some went: say how many, and offer those back.
      final done = [...moves, ...part.done];
      final n = done.fold(0, (sum, m) => sum + m.count);
      _say(to, 'Moved $n of ${messages.length}. ${part.message}',
          undo: done, of: n);
      return true;
    } catch (e) {
      _say(to, 'Could not move: $e');
      return moves.isNotEmpty;
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
        await _afterEngineChange(
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
  ) =>
      _setEach(
        context,
        messages,
        held: (n, ids) => n.setMessagesFlagged(ids, isFlagged),
        engine: (e, ids) => e.setMessagesFlagged(ids, isFlagged),
        what: isFlagged ? 'flag' : 'unflag',
      );

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
      await _afterEngineChange(elsewhere);
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

  Future<void> _afterEngineChange(
    List<MailMessage> changed, {
    List<String> touched = const [],
  }) async {
    for (final folderId in {
      ...changed.map((m) => m.folderId),
      ...touched,
      kUnifiedInboxId,
    }) {
      container.invalidate(messagesProvider(folderId));
    }
    container.invalidate(searchResultsProvider);
    final index = container.read(folderIndexProvider);
    for (final accountId in {
      ...changed.map((m) => m.accountId),
      for (final id in touched) ?index[id]?.accountId,
    }) {
      await container.read(foldersProvider.notifier).refreshAccount(accountId);
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
                onPressed: () => undoMoves(container!, messenger, undo, listId),
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
