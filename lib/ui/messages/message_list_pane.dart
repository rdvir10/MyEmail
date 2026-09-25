import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display_settings.dart';
import '../../domain/message_sort.dart';
import '../../domain/draft.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_message.dart';
import '../../state/folder_drag.dart';
import '../../state/folder_tree.dart';
import '../../state/conversations.dart';
import '../../state/display_providers.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';
import '../../state/search_providers.dart';
import '../../state/sync_now.dart';
import '../../state/window_providers.dart';
import '../../state/message_transfer.dart';
import '../../state/calendar_providers.dart';
import '../../domain/window_handoff.dart';
import 'date_format.dart';
import '../quick_steps/quick_steps_screen.dart';
import 'forward_as_attachment.dart';
import 'message_actions.dart';
import '../compose/open_compose.dart';
import 'conversation_tile.dart';
import '../shell/app_shell.dart';
import '../shell/pane_focus.dart';
import 'list_keyboard.dart';
import 'message_tile.dart';
import 'rows_on_screen.dart';
import 'selection_bar.dart';
import 'search_bar.dart';

/// The list of messages in the selected folder.
///
/// Knows nothing about what happens when a message is opened: the phone
/// pushes a screen, the tablet fills the reading pane, and each host passes
/// the behaviour in through [onOpen].
///
/// Gestures per row: tap opens, swipe left deletes, swipe right moves (via
/// the Move-to sheet), long-press lifts the message so it can be dropped on
/// a folder in the tree, and a long-press menu is offered where there is no
/// tree to drop onto.
class MessageListPane extends ConsumerStatefulWidget {
  const MessageListPane({super.key, required this.onOpen});

  final void Function(MailMessage message) onOpen;

  @override
  ConsumerState<MessageListPane> createState() => _MessageListPaneState();
}

class _MessageListPaneState extends ConsumerState<MessageListPane> {
  /// The list's own box. Selecting what is on screen means measuring rows
  /// against something, and this is the something.
  final _listKey = GlobalKey();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Bring the selected row on screen.
  ///
  /// The arrow keys and Ctrl+. move the selection without touching the
  /// list, and a selection that has walked off the bottom looks like the
  /// keys have stopped working. A row the list has built is scrolled just
  /// far enough to show it; one it has not (End, Page Down: too far from
  /// what is on screen) gets a jump to about where it is, then a second
  /// look once the list has built that far.
  void _reveal(String id, {bool secondLook = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final row = _rowFor(id);
      if (row != null) {
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return;
      }
      if (secondLook) return;
      final folderId = ref.read(effectiveSelectedFolderIdProvider);
      if (folderId == null) return;
      final rows = _searching
          ? _searchRows()
          : visibleMessages(
              ref.read(sortedMessagesProvider(folderId)),
              conversations: ref.read(displayProvider).conversations,
              expandedIds: ref.read(expandedConversationsProvider),
              sort: ref.read(displayProvider).sort,
            );
      final at = rows.indexWhere((m) => m.id == id);
      if (at < 0 || rows.length < 2) return;
      final position = _scroll.position;
      position.jumpTo(
        (position.maxScrollExtent * at / (rows.length - 1)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      _reveal(id, secondLook: true);
    });
  }

  /// The built row showing [id]: its own tile, or the closed thread it is
  /// folded into.
  bool get _searching => ref.read(searchQueryProvider).trim().isNotEmpty;

  /// The search hits in the order they are drawn.
  List<MailMessage> _searchRows() => sortMessages(
        ref.read(searchResultsProvider).value ?? const [],
        ref.read(displayProvider).sort,
      );

  /// Whether [id]'s row is on screen now, not merely built.
  bool _isShowing(String id) {
    final row = _rowFor(id)?.findRenderObject();
    final list = _listKey.currentContext?.findRenderObject();
    if (row is! RenderBox || list is! RenderBox) return false;
    if (!row.attached || !list.attached) return false;
    final rowRect = row.localToGlobal(Offset.zero) & row.size;
    final listRect = list.localToGlobal(Offset.zero) & list.size;
    return rowRect.overlaps(listRect);
  }

  BuildContext? _rowFor(String id) {
    BuildContext? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is MessageTile && w.message.id == id) {
        found = e;
      } else if (w is ConversationTile &&
          !w.isExpanded &&
          w.conversation.messages.any((m) => m.id == id)) {
        found = e;
      } else {
        e.visitChildren(visit);
      }
    }

    _listKey.currentContext?.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folderId = ref.watch(effectiveSelectedFolderIdProvider);
    if (folderId == null) {
      return Center(
        child: Text('Select a folder', style: theme.textTheme.bodySmall),
      );
    }
    ref.listen<String?>(selectedMessageIdProvider, (_, id) {
      if (id != null) _reveal(id);
    });
    // Ticks made on search hits belong to that search: with the box
    // cleared or retyped, the rows they were on are gone, and a delete
    // that reached them anyway would be a trap.
    ref.listen<String>(searchQueryProvider, (_, _) {
      ref.read(selectedMessageIdsProvider.notifier).clear();
    });
    // A page arriving under the list can push the selected row about: the
    // unified Inbox merges the new page by date, and rows from the other
    // account land above it. Keep it on screen through that.
    ref.listen<AsyncValue<List<MailMessage>>>(messagesProvider(folderId), (
      prev,
      next,
    ) {
      final id = ref.read(selectedMessageIdProvider);
      if (id == null || !next.hasValue) return;
      // Only a row that was on screen is kept there. Brought back every time
      // the list grew, the list snapped back to it from wherever it had
      // been scrolled, once for each page loaded on the way down.
      if (prev?.value?.length != next.value?.length && _isShowing(id)) {
        _reveal(id);
      }
    });

    final folder = ref.watch(folderIndexProvider)[folderId];
    final isUnified = folderId == kUnifiedInboxId;
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final accountColors = {for (final a in accounts) a.id: Color(a.colorValue)};
    final selectedId = ref.watch(selectedMessageIdProvider);
    final actions = MessageActions(ref, folderId);
    final searching = ref.watch(searchQueryProvider).trim().isNotEmpty;

    final body = searching
        ? _searchResults(context, ref, actions, accountColors, selectedId)
        : _folderList(
            context,
            ref,
            folderId,
            folder,
            isUnified,
            accountColors,
            selectedId,
            actions,
          );

    return PaneFocusFrame(
      node: ref.watch(paneFocusProvider).list,
      child: Column(
        children: [
          // The selection bar takes the search bar's place while messages are
          // ticked. Both at once would be two rows of controls above a list
          // that has shrunk to make room for them, and searching is not what
          // anyone is doing mid-selection.
          if (ref.watch(isSelectingProvider)) ...[
            SelectionBar(
              listId: folderId,
              onScreen: () => messagesOnScreen(_listKey),
              // The rows on offer are the hits while searching, and hits can
              // live in any folder.
              messages: searching
                  ? ref.watch(searchResultsProvider).value ?? const []
                  : ref.watch(messagesProvider(folderId)).value ?? const [],
              selectAllIsEverything: searching,
            ),
            const Divider(height: 1),
          ] else if (ref.watch(searchShownProvider)) ...[
            const MessageSearchBar(),
            const Divider(height: 1),
          ],
          Expanded(
            child: MessageListKeyboard(
              listId: folderId,
              rows: searching ? _searchRows : null,
              onScreen: () => messagesOnScreen(_listKey),
              // Where there is no reading pane a message opens as its own
              // screen, so landing on one would mean walking into a folder and
              // finding a message already open on top of it.
              // Not while searching: the results are not this folder's list,
              // so landing would pick a message that is not on screen.
              landOnOpen:
                  !searching &&
                  AppShell.hasReadingPane(
                    MediaQuery.sizeOf(context).width,
                    ref.watch(displayProvider).readingPane,
                  ),
              onOpen: widget.onOpen,
              child: body,
            ),
          ),
        ],
      ),
    );
  }

  /// Search hits, which may come from any folder, so each row shows where it
  /// lives. Swipe and drag are deliberately not offered here: the row's list
  /// is the search, not a folder, and moving out of a result set reads as a
  /// bug rather than a feature.
  Widget _searchResults(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    Map<String, Color> accountColors,
    String? selectedId,
  ) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    return ref
        .watch(searchResultsProvider)
        .when(
          loading: () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Search failed.\n$e',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          data: (results) {
            if (results == null) return const SizedBox.shrink();
            if (results.isEmpty) {
              return Center(
                child: Text(
                  'No messages found',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            final ticked = ref.watch(selectedMessageIdsProvider);
            final selecting = ticked.isNotEmpty;
            // The order the list is in applies to what a search turns up
            // too: the same question asked of a smaller set.
            final ordered =
                sortMessages(results, ref.watch(displayProvider).sort);
            return ListView.separated(
              key: _listKey,
              // So a selection the keys move follows on screen here too.
              controller: _scroll,
              itemCount: ordered.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 28),
              itemBuilder: (context, i) {
                final m = ordered[i];
                return MessageTile(
                  key: ValueKey('search:${m.id}'),
                  message: m,
                  isSelected: m.id == selectedId,
                  isTicked: selecting ? ticked.contains(m.id) : null,
                  onTicked: (_) => ref
                      .read(selectedMessageIdsProvider.notifier)
                      .toggle(m.id),
                  density: ref.watch(listDensityProvider),
                  accountColor: accountColors[m.accountId],
                  folderLabel: index[m.folderId]?.displayName,
                  onTap: () {
                    ref.read(selectedMessageIdProvider.notifier).select(m.id);
                    widget.onOpen(m);
                  },
                  // No drag out of a search: the hits are not one folder's
                  // rows. A long press ticks, as it does in a folder.
                  onLongPress: () => ref
                      .read(selectedMessageIdsProvider.notifier)
                      .addAll([m.id]),
                  onContextMenu: (at) =>
                      _showMessageMenu(context, ref, actions, m, at),
                  onToggleFlag: () =>
                      actions.setFlagged(context, [m], !m.isFlagged),
                );
              },
            );
          },
        );
  }

  Widget _folderList(
    BuildContext context,
    WidgetRef ref,
    String folderId,
    dynamic folder,
    bool isUnified,
    Map<String, Color> accountColors,
    String? selectedId,
    MessageActions actions,
  ) {
    final theme = Theme.of(context);
    return ref
        .watch(messagesProvider(folderId))
        .when(
          // A reload keeps what is on screen. The list is refreshed on every
          // resume, after every delete and after every move, and replacing
          // a folder full of mail with a spinner each time is how a working
          // app comes to feel slow.
          skipLoadingOnReload: true,
          loading: () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load messages.\n$e',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          data: (fetched) {
            final messages = ref.watch(sortedMessagesProvider(folderId));
            if (messages.isEmpty) {
              return Center(
                child: Text(
                  'Nothing in ${folder?.displayName ?? 'this folder'}',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            final density = ref.watch(listDensityProvider);
            final ticked = ref.watch(selectedMessageIdsProvider);
            final selecting = ticked.isNotEmpty;
            final display = ref.watch(displayProvider);
            final ownAddresses = <String>{
              for (final a in ref.watch(accountsProvider).value ?? const [])
                a.emailAddress.trim().toLowerCase(),
            };
            final rows = display.conversations
                ? _conversationRows(
                    conversationsInOrder(messages, display.sort),
                    ref.watch(expandedConversationsProvider),
                  )
                : [for (final m in messages) _Row.message(m)];

            // Pulling down is the gesture every mail app answers with a
            // check, so this one does too. The same check as the ribbon's
            // Sync button, which on a phone is not there to press.
            // One more row than there are messages while the folder has
            // older mail: reaching it fetches the next page.
            // Sorted by sender or subject the rows are not in date order
            // at all, and a bar over them would name a grouping that is not
            // there.
            final byDate = display.sort == MessageSort.dateNewest ||
                display.sort == MessageSort.dateOldest;
            final hasMore = ref.watch(listHasMoreProvider(folderId));
            return RefreshIndicator(
              onRefresh: () => _pullToSync(context, folderId),
              child: ListView.separated(
                key: _listKey,
                controller: _scroll,
                itemCount: rows.length + (hasMore ? 1 : 0),
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 28),
                itemBuilder: (context, i) {
                  if (i == rows.length) {
                    return _LoadMoreRow(
                      key: ValueKey('more:$folderId'),
                      folderId: folderId,
                    );
                  }
                  final row = rows[i];
                  // A bar above the first row of each day, drawn as part of
                  // that row rather than as one of its own: the list's
                  // indices are load-bearing — paging, the keyboard's
                  // cursor, scrolling a selection into view — and slipping
                  // extra items between them would move every one of them.
                  // Compared with the row above it at its own level: under
                  // an open thread that is the thread, not its oldest
                  // message, which could be from days before and put a
                  // second "Today" in the middle of today's mail.
                  var above = i - 1;
                  while (above >= 0 && rows[above].indented) {
                    above--;
                  }
                  final bar = byDate &&
                          !row.indented &&
                          (above < 0 ||
                              startsNewDay(rows[above].date, row.date))
                      ? _DateBar(date: row.date)
                      : null;
                  final conversation = row.conversation;
                  if (conversation != null) {
                    final ids = [for (final m in conversation.messages) m.id];
                    return _under(bar, _SwipeableRow(
                      key: ValueKey('thread:${conversation.id}'),
                      messages: conversation.messages,
                      actions: actions,
                      child: ConversationTile(
                        key: ValueKey('tile-thread:${conversation.id}'),
                        conversation: conversation,
                        density: density,
                        isExpanded: row.isExpanded,
                        // Closed, the row stands for every message in it; if
                        // the open one is among them this is where it is.
                        isSelected:
                            !row.isExpanded &&
                            conversation.messages.any(
                              (m) => m.id == selectedId,
                            ),
                        tickedCount: selecting
                            ? ids.where(ticked.contains).length
                            : null,
                        onTicked: (all) {
                          final notifier = ref.read(
                            selectedMessageIdsProvider.notifier,
                          );
                          all ? notifier.addAll(ids) : notifier.removeAll(ids);
                        },
                        accountColor: isUnified
                            ? accountColors[conversation.newest.accountId]
                            : null,
                        onTap: () => ref
                            .read(expandedConversationsProvider.notifier)
                            .toggle(conversation.id),
                        // A long press ticks the thread, the way it ticks a
                        // message. The menu is on the right button.
                        onLongPress: () => ref
                            .read(selectedMessageIdsProvider.notifier)
                            .addAll(ids),
                        onContextMenu: (at) => _showConversationMenu(
                          context,
                          ref,
                          actions,
                          conversation,
                          at,
                        ),
                        onToggleFlag: () => actions.setFlagged(
                          context,
                          conversation.messages,
                          !anyFlagged(conversation.messages),
                        ),
                        ownAddresses: ownAddresses,
                      ),
                    ));
                  }

                  final m = row.message!;
                  final tile = MessageTile(
                    message: m,
                    isSelected: m.id == selectedId,
                    isTicked: selecting ? ticked.contains(m.id) : null,
                    onTicked: (_) => ref
                        .read(selectedMessageIdsProvider.notifier)
                        .toggle(m.id),
                    density: density,
                    accountColor: isUnified ? accountColors[m.accountId] : null,
                    onTap: () {
                      // A message in Drafts is something you were writing, so a
                      // tap continues it rather than opening a reading pane on
                      // your own words with a Reply button under them.
                      if (isDraftsFolder(ref, m.folderId)) {
                        openSavedDraft(context, ref, m);
                        return;
                      }
                      ref.read(selectedMessageIdProvider.notifier).select(m.id);
                      ref
                          .read(lastOpenedInFolderProvider.notifier)
                          .remember(folderId, m.id);
                      // Marked read here rather than left to the reading pane.
                      // The pane marks read as it opens, and it does not open
                      // again for a message the app had already landed on — so
                      // tapping the message the folder opened at would leave it
                      // unread, which is the one case this has to get right.
                      if (!m.isRead) {
                        ref
                            .read(messagesProvider(folderId).notifier)
                            .setRead(m.id, true);
                      }
                      widget.onOpen(m);
                    },
                    // No long press of its own: the draggable around this
                    // row owns the long press, and ticks on its behalf. Two
                    // long-press recognisers on one row and the inner one
                    // wins the gesture, which is a drag that never starts.
                    onContextMenu: (at) =>
                        _showMessageMenu(context, ref, actions, m, at),
                    onToggleFlag: () =>
                        actions.setFlagged(context, [m], !m.isFlagged),
                    key: ValueKey('tile:${m.id}'),
                  );
                  final swipeable = _SwipeableRow(
                    key: ValueKey(m.id),
                    messages: [m],
                    actions: actions,
                    child: LongPressDraggable<DraggedMessages>(
                      data: DraggedMessages([m]),
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      feedback: _DragFeedback(message: m),
                      childWhenDragging: Opacity(opacity: 0.35, child: tile),
                      // Sharing the screen, the pull becomes a drag out of the
                      // app — as .eml files the other window can take — and
                      // Android takes the finger, which ends this one. Every
                      // ticked message comes along if this row is one of them.
                      // A long press ticks: it is how selecting starts on a
                      // screen with no right button. Adds rather than starts,
                      // so a long press mid-selection takes one more. Held
                      // on and pulled, the row is being dragged, within the
                      // app or — sharing the screen — out of it.
                      onDragStarted: () {
                        final wasTicked = ticked.contains(m.id);
                        ref.read(selectedMessageIdsProvider.notifier).addAll([
                          m.id,
                        ]);
                        if (!ref.read(multiWindowModeProvider)) return;
                        final all = wasTicked
                            ? [
                                for (final x in messages)
                                  if (ticked.contains(x.id)) x,
                              ]
                            : [m];
                        dragMessages(ref, all);
                      },
                      child: tile,
                    ),
                  );
                  // Inside an open thread, indented so the run of replies reads
                  // as belonging to the row above it.
                  return _under(
                    bar,
                    row.indented
                        ? Padding(
                            padding: const EdgeInsets.only(left: 20),
                            child: swipeable,
                          )
                        : swipeable,
                  );
                },
              ),
            );
          },
        );
  }

  Future<void> _pullToSync(BuildContext context, String folderId) async {
    try {
      await syncNow(ref, folderId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not sync: $e')));
      }
    }
  }

  /// Threads in the list's order, judged by the message that stands for
  /// the row: the newest one, which is what the row shows.
  /// Conversations flattened into the rows a ListView draws.
  ///
  /// A conversation of one is a plain message row: a header with a "1" badge
  /// next to every ordinary message is noise. An open thread shows its
  /// messages newest first, matching the order of the list around it.
  static List<_Row> _conversationRows(
    List<Conversation> conversations,
    Set<String> expandedIds,
  ) {
    final rows = <_Row>[];
    for (final c in conversations) {
      if (!c.isThread) {
        rows.add(_Row.message(c.newest));
        continue;
      }
      final isExpanded = expandedIds.contains(c.id);
      rows.add(_Row.conversation(c, isExpanded: isExpanded));
      if (isExpanded) {
        for (final m in c.messages.reversed) {
          rows.add(_Row.message(m, indented: true));
        }
      }
    }
    return rows;
  }

  /// A row, with the day's bar above it where one belongs.
  ///
  /// Part of the row rather than an item of its own: the list's indices are
  /// load-bearing — paging, the keyboard's cursor, scrolling a selection
  /// into view — and slipping extra items between them would move every one.
  static Widget _under(Widget? bar, Widget row) => bar == null
      ? row
      : Column(
          mainAxisSize: MainAxisSize.min,
          children: [bar, row],
        );

  /// A menu at the pointer, which is where a right click puts one.
  Future<String?> _menuAt(
    BuildContext context,
    Offset at,
    List<PopupMenuEntry<String>> items,
  ) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  static PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String text, {
    Color? color,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: color == null ? null : TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }

  /// The whole thread at once.
  ///
  /// Every entry says how many messages it is about. "Delete" on a row that
  /// looks like one message but is nine is the kind of surprise that makes
  /// people turn conversations off.
  Future<void> _showConversationMenu(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    Conversation conversation,
    Offset at,
  ) async {
    final count = conversation.length;
    final unread = conversation.hasUnread;
    final flagged = conversation.isFlagged;
    final error = Theme.of(context).colorScheme.error;

    final choice = await _menuAt(context, at, [
      _item('select', Icons.checklist, 'Select all $count'),
      const PopupMenuDivider(),
      _item('move', Icons.drive_file_move_outline, 'Move all $count to…'),
      _item(
        'read',
        unread
            ? Icons.mark_email_read_outlined
            : Icons.mark_email_unread_outlined,
        unread ? 'Mark all $count as read' : 'Mark all $count as unread',
      ),
      _item(
        'flag',
        flagged ? Icons.flag : Icons.flag_outlined,
        flagged ? 'Remove flags' : 'Flag all $count',
      ),
      const PopupMenuDivider(),
      _item('delete', Icons.delete_outline, 'Delete all $count', color: error),
    ]);
    if (choice == null || !context.mounted) return;

    final messages = conversation.messages;
    final notifier = ref.read(messagesProvider(actions.listId).notifier);
    switch (choice) {
      case 'select':
        ref.read(selectedMessageIdsProvider.notifier).addAll([
          for (final m in messages) m.id,
        ]);
      case 'move':
        await actions.moveWithPrompt(context, messages);
      case 'delete':
        await actions.delete(context, messages);
      case 'read':
        for (final m in messages) {
          await notifier.setRead(m.id, unread);
        }
      case 'flag':
        for (final m in messages) {
          await notifier.setFlagged(m.id, !flagged);
        }
    }
  }

  /// Everything that can be done to one message, from a right click.
  Future<void> _showMessageMenu(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    MailMessage message,
    Offset at,
  ) async {
    final steps = ref.read(quickStepsProvider);
    final folderIndex = ref.read(folderIndexProvider);
    final error = Theme.of(context).colorScheme.error;
    final windows = ref.read(windowsAvailableProvider).value ?? false;
    final choice = await _menuAt(context, at, [
      if (windows) ...[
        _item('window', Icons.open_in_new, 'Open in new window'),
        const PopupMenuDivider(),
      ],
      _item('reply', Icons.reply, 'Reply'),
      _item('replyAll', Icons.reply_all, 'Reply all'),
      _item('forward', Icons.forward, 'Forward'),
      _item(
        'forwardAttach',
        Icons.attach_email_outlined,
        'Forward as attachment',
      ),
      const PopupMenuDivider(),
      // Only the steps that can finish on this message: one that files
      // into another account's folder cannot.
      for (final step in steps.where((s) => s.appliesTo(message.accountId)))
        PopupMenuItem<String>(
          value: 'qs:${step.id}',
          child: Row(
            children: [
              Icon(iconForQuickStep(step), size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(step.name),
                    Text(
                      describeQuickStep(step, folderIndex),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (steps.isNotEmpty) const PopupMenuDivider(),
      _item('copy', Icons.copy_outlined, 'Copy'),
      if (ref.read(calendarAvailableProvider).value ?? false)
        _item('event', Icons.event_outlined, 'Create calendar event…'),
      _item('select', Icons.checklist, 'Select'),
      _item('move', Icons.drive_file_move_outline, 'Move to…'),
      _item(
        'read',
        message.isRead
            ? Icons.mark_email_unread_outlined
            : Icons.mark_email_read_outlined,
        message.isRead ? 'Mark as unread' : 'Mark as read',
      ),
      _item(
        'flag',
        message.isFlagged ? Icons.flag : Icons.flag_outlined,
        message.isFlagged ? 'Remove flag' : 'Flag',
      ),
      const PopupMenuDivider(),
      _item('delete', Icons.delete_outline, 'Delete', color: error),
    ]);
    if (choice == null || !context.mounted) return;
    final notifier = ref.read(messagesProvider(actions.listId).notifier);

    if (choice.startsWith('qs:')) {
      final step = steps.firstWhere((s) => s.id == choice.substring(3));
      try {
        await runQuickStep(
          step: step,
          notifier: notifier,
          message: message,
          engine: ref.read(mailEngineProvider),
          onMoved: (folderId) =>
              ref.read(recentMoveTargetsProvider.notifier).record(folderId),
          onElsewhere: () {
            ref.invalidate(messagesProvider(message.folderId));
            ref.invalidate(messagesProvider(kUnifiedInboxId));
          },
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('${step.name} applied')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('${step.name} failed: $e')));
        }
      }
      return;
    }

    switch (choice) {
      case 'window':
        final opened = await ref
            .read(windowOpenerProvider)
            .open(MessageWindow(message));
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(duration: kBottomMessage, content: Text('Could not open a window.')),
            );
        }
      case 'reply':
        await openCompose(
          context,
          ref,
          kind: ComposeKind.reply,
          original: message,
        );
      case 'replyAll':
        await openCompose(
          context,
          ref,
          kind: ComposeKind.replyAll,
          original: message,
        );
      case 'forward':
        await openCompose(
          context,
          ref,
          kind: ComposeKind.forward,
          original: message,
        );
      case 'forwardAttach':
        await forwardAsAttachment(context, ref, [message]);
      case 'copy':
        await copyMessage(ref, context, message);
      case 'event':
        final body = await ref
            .read(mailEngineProvider)
            .loadMessageBody(message.id);
        final notes = body.text.trim();
        await ref
            .read(deviceCalendarProvider)
            .insertEvent(
              title: message.subject,
              description:
                  '${notes.length > 2000 ? '${notes.substring(0, 2000)}…' : notes}'
                  '\n\nFrom: ${message.from.display}',
            );
      case 'select':
        ref.read(selectedMessageIdsProvider.notifier).addAll([message.id]);
      case 'move':
        await actions.moveWithPrompt(context, [message]);
      // Through the actions, which send a search hit from another folder
      // to the engine: the open list passed over it without a word.
      case 'read':
        await actions.setRead(context, [message], !message.isRead);
      case 'flag':
        await actions.setFlagged(context, [message], !message.isFlagged);
      case 'delete':
        await actions.delete(context, [message]);
    }
  }
}

/// A row that does whatever Settings says a swipe should do.
///
/// Both directions are configurable, and either may be [SwipeAction.none], in
/// which case that direction does not drag at all — an inert drag that springs
/// back reads as the app having missed the gesture.
class _SwipeableRow extends ConsumerWidget {
  const _SwipeableRow({
    super.key,
    required this.messages,
    required this.actions,
    required this.child,
  });

  /// What the row stands for: one message, or every message in a
  /// conversation. A thread's row means the thread — its menu already
  /// says "Delete all 5" — so a swipe on it means the thread too.
  final List<MailMessage> messages;
  final MessageActions actions;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(displayProvider);
    final right = settings.swipeRight;
    final left = settings.swipeLeft;

    final direction = switch ((
      right == SwipeAction.none,
      left == SwipeAction.none,
    )) {
      (true, true) => DismissDirection.none,
      (true, false) => DismissDirection.endToStart,
      (false, true) => DismissDirection.startToEnd,
      (false, false) => DismissDirection.horizontal,
    };
    if (direction == DismissDirection.none) return child;

    return Dismissible(
      key: ValueKey('swipe:${messages.first.id}'),
      direction: direction,
      background: _backgroundFor(context, right, Alignment.centerLeft),
      secondaryBackground: _backgroundFor(context, left, Alignment.centerRight),
      confirmDismiss: (dismissed) async {
        await _run(
          context,
          ref,
          dismissed == DismissDirection.endToStart ? left : right,
        );
        // The list state removes the row itself, so the widget never
        // dismisses; that keeps one source of truth for what is in the list.
        return false;
      },
      child: child,
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    SwipeAction action,
  ) async {
    switch (action) {
      case SwipeAction.none:
        return;
      case SwipeAction.delete:
        await actions.delete(context, messages);
      case SwipeAction.move:
        await actions.moveWithPrompt(context, messages);
      // A thread is rarely all one thing: the swipe does what the label
      // said it would — read if anything is unread, unflag if anything is
      // flagged — to every message, rather than flipping each on its own
      // and leaving the row in a state nobody asked for.
      case SwipeAction.toggleRead:
        await actions.setRead(context, messages, anyUnread(messages));
      case SwipeAction.toggleFlag:
        await actions.setFlagged(context, messages, !anyFlagged(messages));
      case SwipeAction.archive:
        final target = archiveFolderIdFor(ref, messages.first.accountId);
        if (target == null) {
          // Gmail has no folder to move into, and an account may simply not
          // have one. Saying so beats a swipe that appears to do nothing.
          if (context.mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(duration: kBottomMessage, 
                  content: Text('This account has no Archive folder.'),
                ),
              );
          }
          return;
        }
        await actions.moveTo(context, messages, target);
    }
  }

  Widget _backgroundFor(
    BuildContext context,
    SwipeAction action,
    Alignment alignment,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // Destructive actions get the error colour and everything else the
    // primary one, so the half-completed swipe tells you which way you are
    // going before you let go.
    final destructive = action == SwipeAction.delete;
    return _SwipeBackground(
      alignment: alignment,
      color: destructive ? scheme.errorContainer : scheme.primaryContainer,
      foreground: destructive
          ? scheme.onErrorContainer
          : scheme.onPrimaryContainer,
      icon: swipeActionIcon(action),
      label: swipeActionShortLabel(action, messages),
    );
  }
}

/// The Archive folder for an account, or null when it has none.
String? archiveFolderIdFor(WidgetRef ref, String accountId) {
  final folders = ref.read(foldersProvider).value?[accountId];
  if (folders == null) return null;
  for (final f in folders) {
    // canAcceptMessages is what separates a real Archive folder from Gmail's
    // All Mail, which is a view of everything and cannot be moved into.
    if (f.role == FolderRole.archive && f.capabilities.canAcceptMessages) {
      return f.id;
    }
  }
  return null;
}

IconData swipeActionIcon(SwipeAction action) => switch (action) {
  SwipeAction.none => Icons.block,
  SwipeAction.delete => Icons.delete_outline,
  SwipeAction.move => Icons.drive_file_move_outline,
  SwipeAction.toggleRead => Icons.mark_email_unread_outlined,
  SwipeAction.toggleFlag => Icons.flag_outlined,
  SwipeAction.archive => Icons.archive_outlined,
};

/// The label on the swipe background, which says what will happen to *this*
/// message rather than naming the setting.
///
/// A toggle that says "Read / unread" while you are dragging is no help; what
/// you want to know is which of the two you are about to get.
String swipeActionShortLabel(SwipeAction action, List<MailMessage> messages) {
  final word = switch (action) {
    SwipeAction.none => '',
    SwipeAction.delete => 'Delete',
    SwipeAction.move => 'Move',
    SwipeAction.toggleRead => anyUnread(messages) ? 'Read' : 'Unread',
    SwipeAction.toggleFlag => anyFlagged(messages) ? 'Unflag' : 'Flag',
    SwipeAction.archive => 'Archive',
  };
  // "Delete 5" on a thread: what is about to go is not one message, and
  // the half-finished swipe is the last moment to notice.
  return messages.length > 1 && word.isNotEmpty
      ? '$word ${messages.length}'
      : word;
}

bool anyUnread(List<MailMessage> messages) => messages.any((m) => !m.isRead);

bool anyFlagged(List<MailMessage> messages) => messages.any((m) => m.isFlagged);

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.foreground,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final Color foreground;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.message});

  final MailMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: const Offset(16, -28),
      child: Material(
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.mail_outline,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    message.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One line in the list: either a collapsed conversation, or a message.
class _Row {
  const _Row._(this.message, this.conversation, this.isExpanded, this.indented);

  factory _Row.message(MailMessage message, {bool indented = false}) =>
      _Row._(message, null, false, indented);

  factory _Row.conversation(Conversation c, {required bool isExpanded}) =>
      _Row._(null, c, isExpanded, false);

  final MailMessage? message;
  final Conversation? conversation;
  final bool isExpanded;

  /// A message shown inside an open thread rather than at the top level.
  final bool indented;

  /// When this row happened, whichever kind it is.
  DateTime get date => message?.date ?? conversation!.newest.date;
}

/// The bar that separates one day from the next.
///
/// Only where the list is in date order. Sorted by sender or subject the
/// rows are not in date order at all, and a date bar over them would be
/// describing a grouping that is not there.
class _DateBar extends StatelessWidget {
  const _DateBar({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      // Underlined in the accent colour, so the bar reads as a heading and
      // not as one more read row, which sit on a shade of their own.
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
            width: 1.5,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: Text(
        formatDateBar(date),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The last row of a list that has older mail: being built is the signal
/// to fetch the next page, so scrolling to the bottom is all it takes, and
/// a folder shorter than the screen fills itself without a scroll at all.
///
/// A failed fetch stays on screen as something to tap. Retrying on its own
/// while the network is down would spin for ever under the list.
class _LoadMoreRow extends ConsumerStatefulWidget {
  const _LoadMoreRow({super.key, required this.folderId});

  final String folderId;

  @override
  ConsumerState<_LoadMoreRow> createState() => _LoadMoreRowState();
}

class _LoadMoreRowState extends ConsumerState<_LoadMoreRow> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    // After the frame: a provider must not change while the list that
    // watches it is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _error = null);
      try {
        await ref.read(messagesProvider(widget.folderId).notifier).loadMore();
      } catch (e) {
        if (mounted) setState(() => _error = e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return InkWell(
        onTap: _fetch,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Could not load older messages. Tap to try again.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
