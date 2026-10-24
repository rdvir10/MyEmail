import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../domain/message_sort.dart';
import '../../state/conversation_extras.dart';
import '../../state/conversations.dart';
import '../../state/display_providers.dart';
import '../../state/list_filter.dart';
import '../../state/list_navigation.dart';
import '../../state/message_providers.dart';
import '../../state/message_transfer.dart';
import '../../state/pinned_messages.dart';
import '../../state/search_providers.dart';
import '../shell/pane_focus.dart';
import 'list_groups.dart';
import 'message_actions.dart';

/// Keyboard control of the message list, and landing somewhere sensible when
/// a folder opens.
///
/// The two belong together: a list that can be driven from the keyboard needs
/// somewhere to start from, and a starting position is only worth having if
/// something can be done from there.
///
/// Landing on a message does not mark it read. That rule lives in the reading
/// pane, which only marks read when the person chose the message; arriving
/// here by opening a folder is not choosing. Pressing a key is, which is why
/// every handler below claims the selection first.
class MessageListKeyboard extends ConsumerStatefulWidget {
  const MessageListKeyboard({
    super.key,
    required this.listId,
    required this.child,
    this.landOnOpen = true,
    this.onOpen,
    this.onScreen,
    this.rows,
  });

  final String listId;
  final Widget child;

  /// The rows on screen when they are not the list's own: search results.
  /// The keys walked the folder's list behind them, so Down from a hit
  /// opened a message that was not in the results at all.
  final List<MailMessage> Function()? rows;

  /// Off where there is no reading pane. On a phone a message opens as its own
  /// screen, so landing on one would mean walking into a folder and finding a
  /// message already open on top of it.
  final bool landOnOpen;

  /// Enter, where the layout wants opening to do something more than select.
  final void Function(MailMessage)? onOpen;

  /// The messages whose rows are on screen, for Ctrl+A. What is on screen
  /// rather than the whole folder, for the same reason the selection bar's
  /// button stops there: a delete one press away from thousands of
  /// messages nobody can see the size of.
  final List<String> Function()? onScreen;

  @override
  ConsumerState<MessageListKeyboard> createState() =>
      _MessageListKeyboardState();
}

class _MessageListKeyboardState extends ConsumerState<MessageListKeyboard> {
  ListRows get _list =>
      ListRows(ref, widget.listId, search: widget.rows?.call());

  List<MailMessage> get _all => _list.all;

  /// What the arrows move through: see [ListRows.shown].
  List<MailMessage> get _messages => _list.shown;

  List<MailMessage> get _rows => _list.unfolded;

  String? get _selectedRow => _list.rowOf(_selected);

  String? get _selected => ref.read(selectedMessageIdProvider);

  /// The rows as they were the last time the selection was among them,
  /// and the row it was, for when it goes: see [rowInPlaceOf].
  ({String listId, String selected, String row, List<MailMessage> rows})?
      _seen;

  void _land() {
    if (!widget.landOnOpen) return;
    final messages = _messages;
    if (messages.isEmpty) return;

    // A selection folded into a thread just closed is still here, as that
    // thread's row. Taken for gone, it moved to the top of the folder. So
    // is one under a date bar just closed: closing Today over the message
    // being read swapped the reading pane for one of yesterday's.
    final row = _selectedRow;
    final rows = _rows;
    if (row != null && rows.any((m) => m.id == row)) {
      _seen = (
        listId: widget.listId,
        selected: _selected!,
        row: row,
        rows: rows,
      );
      return;
    }
    final target = _inPlace(messages) ??
        messageToLandOn(
          messages: messages,
          lastOpened: _list
              .rowOf(ref.read(lastOpenedInFolderProvider)[widget.listId]),
          current: _selected,
        );
    if (target == null || target == _selected) return;
    // byPerson: false — this is the app landing somewhere, not a choice, so
    // the message is shown without being marked read.
    ref.read(selectedMessageIdProvider.notifier).select(target, byPerson: false);
  }

  /// Where a selection that has gone from under this list lands: deleted
  /// from the reading pane, moved, swiped. Null for one this list was not
  /// showing, which is a folder just opened, and that starts at the top.
  String? _inPlace(List<MailMessage> messages) {
    final seen = _seen;
    if (seen == null ||
        seen.listId != widget.listId ||
        seen.selected != _selected) {
      return null;
    }
    return rowInPlaceOf(seen.rows, seen.row, {for (final m in messages) m.id});
  }

  void _move(int delta) {
    final next = _list.step(_selected, delta);
    if (next == null) return;
    _goTo(next);
  }

  void _goTo(String id) {
    // A key press is a choice, so from here the message counts as opened.
    ref.read(selectedMessageIdProvider.notifier).select(id);
    ref.read(lastOpenedInFolderProvider.notifier).remember(widget.listId, id);
  }

  /// Shift with an arrow: tick where you are and where you land, so holding
  /// it down ticks a run, the way every file list does it.
  void _extend(int delta) {
    final from = _selected;
    _move(delta);
    final to = _selected;
    final ticks = ref.read(selectedMessageIdsProvider.notifier);
    ticks.addAll([?from, ?to]);
  }

  /// Open or close the conversation the current message is in. Nothing
  /// happens on a message that is not in a thread, or with conversations
  /// off, where there is nothing to open.
  void _setThreadOpen(bool open) {
    final id = _selected;
    if (id == null || !ref.read(displayProvider).conversations) return;
    for (final c in groupIntoConversations(_all)) {
      if (!c.isThread || !c.messages.any((m) => m.id == id)) continue;
      final expanded = ref.read(expandedConversationsProvider);
      if (expanded.contains(c.id) != open) {
        ref.read(expandedConversationsProvider.notifier).toggle(c.id);
      }
      return;
    }
  }

  /// Delete is being held after it went as far as it should. A held Delete
  /// goes on deleting a message a repeat, but once it has taken the ticked
  /// messages the next one would be the message under the cursor, which
  /// nobody ticked, and once it has taken the last row the next would be
  /// the one above where the person started, which they meant to keep.
  bool _holdStopped = false;

  MailMessage? get _current {
    final id = _selected;
    if (id == null) return null;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final control = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    // Ctrl+A is the one Ctrl combination that is about the list itself;
    // the rest (Ctrl+R, Ctrl+N, ...) bubble up to the shell's commands.
    if (control) {
      if (event.logicalKey == LogicalKeyboardKey.keyA) {
        final onScreen = widget.onScreen?.call() ?? const <String>[];
        if (onScreen.isEmpty) return KeyEventResult.ignored;
        ref.read(selectedMessageIdsProvider.notifier).addAll(onScreen);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        final message = _current;
        if (message == null) return KeyEventResult.ignored;
        copyMessage(ref, context, message);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        shift ? _extend(1) : _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        shift ? _extend(-1) : _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        _move(10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        _move(-10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        if (_messages.isNotEmpty) _goTo(_messages.first.id);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        if (_messages.isNotEmpty) _goTo(_messages.last.id);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _setThreadOpen(true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _setThreadOpen(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final message = _current;
        if (message == null) return KeyEventResult.ignored;
        ref.read(selectedMessageIdProvider.notifier).claim();
        ref
            .read(lastOpenedInFolderProvider.notifier)
            .remember(widget.listId, message.id);
        widget.onOpen?.call(message);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        final message = _current;
        if (message == null) return KeyEventResult.ignored;
        // Ticks rather than opens, which is what space does in every list
        // that has checkboxes.
        ref.read(selectedMessageIdsProvider.notifier).toggle(message.id);
        return KeyEventResult.handled;
      // Delete deletes; Backspace archives, as in Outlook on the PC.
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        final archive = event.logicalKey == LogicalKeyboardKey.backspace;
        if (event is KeyDownEvent) {
          _holdStopped = false;
        } else if (_holdStopped) {
          return KeyEventResult.handled;
        }
        // What is ticked, when anything is, as the selection bar's Delete:
        // the cursor is only where the person is looking. It took the
        // message under the cursor, ticked or not, and left the ticks.
        final ticked = ref.read(selectedMessageIdsProvider);
        if (ticked.isNotEmpty) {
          if (event is KeyDownEvent) {
            final chosen = [
              for (final m in _all)
                if (ticked.contains(m.id)) m,
            ];
            final actions = MessageActions(ref, widget.listId);
            archive
                ? actions.archive(context, chosen)
                : actions.delete(context, chosen);
            ref.read(selectedMessageIdsProvider.notifier).clear();
          }
          _holdStopped = true;
          return KeyEventResult.handled;
        }
        final message = _current;
        if (message == null) return KeyEventResult.ignored;
        // Move first, so the list does not leave the person on nothing once
        // the row under them disappears.
        _move(1);
        if (_selected == message.id) {
          // The last row, so up instead, as Outlook does: staying put there
          // left the list to land at the top of the folder. A held key
          // stops here. Going on up would take the mail above where the
          // person started, and the last row is often only the end of
          // what has loaded, with more of the folder still to come.
          _move(-1);
          _holdStopped = true;
        }
        final actions = MessageActions(ref, widget.listId);
        archive
            ? actions.archive(context, [message])
            : actions.delete(context, [message]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        ref.read(selectedMessageIdsProvider.notifier).clear();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Watched rather than listened to. A listener only fires on a change, and
    // moving to a folder whose mail is already cached is not one: the new
    // provider hands over its value with nothing to report, and the list
    // would sit there still pointing at a message from the folder just left.
    final messages = ref.watch(messagesProvider(widget.listId));

    // Landing happens as the list settles, not during a build: selecting from
    // inside build would be changing state while reading it. Asking on every
    // build is safe because landing on where you already are does nothing.
    if (messages.hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _land();
      });
    }

    return Focus(
      // The shell's node for the list, so F6 can come back to it.
      focusNode: ref.watch(paneFocusProvider).list,
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}

/// A list's rows as it draws them, for walking them from the keyboard.
///
/// The list's own arrows and Ctrl+. and Ctrl+, from anywhere both walk
/// these, so the two cannot go different ways. Ctrl+. walked the folder's
/// list as the engine had it: by date whatever the sort, into messages
/// folded inside threads or under closed date bars, and through the folder
/// behind the search results rather than the results.
class ListRows {
  ListRows(this.ref, this.listId, {this.search});

  /// The rows of [listId]'s list as the screen has them now: the search
  /// hits while a search is showing.
  ListRows.onScreen(this.ref, this.listId) : search = searchRows(ref);

  final WidgetRef ref;
  final String listId;

  /// The rows on screen when they are not the folder's own: search
  /// results, which are never threaded.
  final List<MailMessage>? search;

  /// Every message in the list, whether it has a row of its own or not.
  List<MailMessage> get all =>
      search ?? ref.read(sortedMessagesProvider(listId));

  /// The rows on screen, in order: what the arrows move through. A message
  /// folded into a closed thread is not one of them, nor one under a
  /// closed date bar.
  List<MailMessage> get shown => search ?? folderRows(ref, listId);

  /// [shown] with the rows under closed date bars put back: still in the
  /// folder, only out of sight.
  List<MailMessage> get unfolded =>
      search ?? folderRows(ref, listId, unfolding: true);

  /// Where [id] is, as a row: itself, or the row of the thread it is
  /// folded into, so closing a thread and pressing Down moves on from the
  /// thread rather than from the top of the list.
  String? rowOf(String? id) {
    if (id == null) return null;
    if (unfolded.any((m) => m.id == id)) return id;
    if (search == null) {
      for (final c in groupIntoConversations(all)) {
        if (c.messages.any((m) => m.id == id)) return c.newest.id;
      }
    }
    return id;
  }

  /// The row [delta] rows on from [id]'s: see [neighbourOf].
  String? step(String? id, int delta) => neighbourOf(
        unfolded,
        rowOf(id),
        delta,
        shown: {for (final m in shown) m.id},
      );
}

/// The search hits in the order the list draws them, while a search is
/// what it shows; null while it shows the folder.
List<MailMessage>? searchRows(WidgetRef ref) {
  if (ref.read(searchQueryProvider).trim().isEmpty) return null;
  return sortMessages(
    ref.read(searchResultsProvider).value ?? const [],
    ref.read(displayProvider).sort,
    accountRank: ref.read(accountRankProvider),
  );
}

/// A folder's rows as the list draws them, top to bottom: see
/// [visibleMessages]. With [unfolding], the rows under closed date bars as
/// well, which are still in the folder and only out of sight.
List<MailMessage> folderRows(
  WidgetRef ref,
  String listId, {
  bool unfolding = false,
}) {
  final display = ref.read(displayProvider);
  final closed = ref.read(collapsedDateGroupsProvider)[listId];
  return visibleMessages(
    ref.read(sortedMessagesProvider(listId)),
    conversations: display.conversations,
    expandedIds: ref.read(expandedConversationsProvider),
    sort: display.sort,
    folded: unfolding
        ? null
        : foldedUnder(
            closed,
            display.sort,
            accountNames: ref.read(accountNamesProvider),
          ),
    pinned: ref.read(pinnedMessagesProvider),
    // The Pinned bar is drawn only where the list has bars at all.
    pinnedClosed: !unfolding &&
        display.sort.hasBars &&
        (closed?.contains(ListGroup.pinned.key) ?? false),
    accountRank: ref.read(accountRankProvider),
    others: ref.read(conversationExtrasProvider(listId)).value ?? const [],
  );
}
