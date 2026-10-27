import '../common/bottom_message.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/display_settings.dart';
import '../../domain/message_filter.dart';
import '../../domain/message_sort.dart';
import '../../domain/draft.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_message.dart';
import '../../domain/row_format.dart';
import '../../state/conversation_extras.dart';
import '../../state/folder_drag.dart';
import '../../state/folder_tree.dart';
import '../../state/conversations.dart';
import '../../state/display_providers.dart';
import '../../state/list_filter.dart';
import '../../state/message_providers.dart';
import '../../state/pinned_messages.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';
import '../../state/read_marker.dart';
import '../../state/row_formats.dart';
import '../../state/search_providers.dart';
import '../../state/sync_now.dart';
import '../../state/window_providers.dart';
import '../../state/message_transfer.dart';
import '../../domain/window_handoff.dart';
import '../quick_steps/apply_quick_step.dart';
import '../quick_steps/quick_steps_screen.dart';
import 'forward_as_attachment.dart';
import 'follow_up_sheet.dart';
import 'junk_actions.dart';
import 'message_actions.dart';
import 'print_message.dart';
import 'snooze_sheet.dart';
import 'threat_check_sheet.dart';
import '../settings/rules_screen.dart' show openRuleEditor;
import '../settings/server_settings_access.dart' show canReachServerSettings;
import '../../state/sender_blocks.dart';
import '../compose/open_compose.dart';
import '../meetings/new_meeting_screen.dart';
import 'conversation_tile.dart';
import 'filter_bar.dart';
import 'list_groups.dart';
import '../shell/app_shell.dart';
import '../shell/pane_focus.dart';
import '../../state/put_away_providers.dart';
import '../calendar/next_meeting_bar.dart';
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
/// the Move-to sheet), and a hold lifts the message so it can be dropped on
/// a folder in the tree. Let go where it was, the hold opens the row's
/// menu, the one a right click opens: a finger's way of asking for it.
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

  /// Where the finger last went down on a row that can be pulled, and
  /// whether the pull has gone out of the app: a hold let go where it was
  /// opens the row's menu, a pull does not.
  Offset? _heldAt;
  bool _pulledOut = false;

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
      final rows = ListRows.onScreen(ref, folderId).shown;
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

  /// The search hits in the order they are drawn.
  List<MailMessage> _searchRows() => searchRows(ref) ?? const [];

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

  /// The built row showing [id]: its own tile, or the closed thread it is
  /// folded into.
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
    // Back from being put away: newest first, at the top.
    ref.listen(listToTopProvider, (_, _) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
    // Another folder opens at its newest mail. The list is the same one from
    // folder to folder, and a folder visited before has its mail at once,
    // with no spinner between to drop the old position: on the phone Sent
    // opened as far down as the Inbox had been scrolled. Beside a reading
    // pane the list then goes to the message open in it, if this folder
    // has it too.
    ref.listen<String?>(effectiveSelectedFolderIdProvider, (before, now) {
      if (before == now || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
      final open = ref.read(selectedMessageIdProvider);
      if (open != null &&
          AppShell.hasReadingPane(
            MediaQuery.sizeOf(context).width,
            ref.read(displayProvider).readingPane,
          )) {
        _reveal(open);
      }
    });
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
    final isUnified = isSyntheticList(folderId);
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
          // The next meeting, from a quarter of an hour before it; nothing
          // at all otherwise.
          const NextMeetingBar(),
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
          ] else ...[
            // Outlook's All / Unread and Filter, over the list. Not while
            // searching or selecting, whose bars take this place.
            ListFilterBar(listId: folderId),
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
          // A failed search is not run again by itself, so the first one
          // after the radio wakes would otherwise mean retyping the words.
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Search failed.\n$e',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => ref.invalidate(searchHitsProvider),
                    child: const Text('Try again'),
                  ),
                ],
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
            final ordered = sortMessages(
              results,
              ref.watch(displayProvider).sort,
              accountRank: ref.watch(accountRankProvider),
            );
            final formats = ref.watch(rowFormatsProvider);
            final own = ref.watch(ownAddressesProvider);
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
                  showRecipients: switch (index[m.folderId]?.role) {
                    FolderRole.sent || FolderRole.drafts => true,
                    _ => false,
                  },
                  format: rowFormatFor(m, formats, own),
                  showAttachments: ref.watch(displayProvider).attachmentsOnRow,
                  onTap: () {
                    ref.read(selectedMessageIdProvider.notifier).select(m.id);
                    widget.onOpen(m);
                  },
                  // No drag out of a search: the hits are not one folder's
                  // rows. A hold opens the menu, as a right click does.
                  onLongPress: (at) =>
                      _showMessageMenu(context, ref, actions, m, at),
                  onContextMenu: (at) =>
                      _showMessageMenu(context, ref, actions, m, at),
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
          // Not loaded again by itself until the minute's ask, so there is a
          // way to ask now, once the signal is back.
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Could not load messages.\n$e',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(messagesProvider(folderId)),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
          data: (fetched) {
            final messages = ref.watch(sortedMessagesProvider(folderId));
            final filter = ref.watch(listFilterProvider(folderId));
            if (messages.isEmpty) {
              // Pulled down like a list with mail in it: an empty folder is
              // the one most likely to be waiting for some.
              return RefreshIndicator(
                onRefresh: () => _pullToSync(context, folderId),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          filter == MessageFilter.all
                              ? 'Nothing in ${folder?.displayName ?? 'this folder'}'
                              : filter.empty,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            final density = ref.watch(listDensityProvider);
            final ticked = ref.watch(selectedMessageIdsProvider);
            final selecting = ticked.isNotEmpty;
            final display = ref.watch(displayProvider);
            final ownAddresses = ref.watch(ownAddressesProvider);
            final pinned = ref.watch(pinnedMessagesProvider);
            final formats = ref.watch(rowFormatsProvider);
            final filesOnRows = display.attachmentsOnRow;
            final index = ref.watch(folderIndexProvider);
            bool outgoing(String folderId) => switch (index[folderId]?.role) {
                  FolderRole.sent || FolderRole.drafts => true,
                  _ => false,
                };
            bool isPinned(List<MailMessage> row) =>
                row.any((m) => pinned.contains(m.id));
            // Your replies from Sent, to show inside the threads they answer.
            final others = display.conversations
                ? ref.watch(conversationExtrasProvider(folderId)).value ??
                    const <MailMessage>[]
                : const <MailMessage>[];
            final rows = display.conversations
                ? _conversationRows(
                    conversationsInOrder(
                      messages,
                      display.sort,
                      accountRank: ref.watch(accountRankProvider),
                      pinned: pinned,
                      others: others,
                    ),
                    ref.watch(expandedConversationsProvider),
                  )
                : [for (final m in messages) _Row.message(m)];

            // Pulling down is the gesture every mail app answers with a
            // check, so this one does too. The same check as the ribbon's
            // Sync button, which on a phone is not there to press.
            // One more row than there are messages while the folder has
            // older mail: reaching it fetches the next page.
            // Sorted by sender, recipient or subject there are no bars: a
            // group for every name is a bar over every row or two.
            // Grouped as Outlook groups them (see listGroupOf), with the
            // pinned rows under a bar of their own above the rest.
            final now = DateTime.now();
            final accountNames = ref.watch(accountNamesProvider);
            final items = display.sort.hasBars
                ? _underBars(
                    rows,
                    (row) => isPinned(row.messages)
                        ? ListGroup.pinned
                        : listGroupOf(
                            row.lead,
                            display.sort,
                            now: now,
                            accountNames: accountNames,
                          )!,
                    ref.watch(collapsedDateGroupsProvider)[folderId] ??
                        const {},
                  )
                : [for (final r in rows) _Item(r)];
            final hasMore = ref.watch(listHasMoreProvider(folderId));
            // A closed bar at the bottom leaves the paging row on screen
            // however far the folder goes, and every page it fetched would
            // vanish under the bar: older mail waits for a tap there.
            final pageOnTap = items.isNotEmpty && items.last.row == null;
            return RefreshIndicator(
              onRefresh: () => _pullToSync(context, folderId),
              child: ListView.separated(
                key: _listKey,
                controller: _scroll,
                // A list with a controller of its own scrolls only when it is
                // longer than the screen, and the pull is a scroll: thirteen
                // messages on a tablet could not be pulled down at all.
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: items.length + (hasMore ? 1 : 0),
                // None under a closed bar: the next thing down is another
                // bar, and a line between two bars reads as a row of nothing.
                separatorBuilder: (_, i) => items[i].row == null
                    ? const SizedBox.shrink()
                    : const Divider(height: 1, indent: 28),
                itemBuilder: (context, i) {
                  if (i == items.length) {
                    return _LoadMoreRow(
                      key: ValueKey('more${pageOnTap ? '-on-tap' : ''}:'
                          '$folderId'),
                      folderId: folderId,
                      onTap: pageOnTap,
                    );
                  }
                  final section = items[i].bar;
                  final bar = section == null
                      ? null
                      : _DateBar(
                          key: ValueKey('bar:${section.group.key}'),
                          label: section.group.label,
                          collapsed: section.collapsed,
                          messages: section.messages,
                          onToggle: () => ref
                              .read(collapsedDateGroupsProvider.notifier)
                              .toggle(folderId, section.group.key),
                          onMenu: (at) => _showDateBarMenu(
                            context,
                            ref,
                            actions,
                            folderId,
                            section,
                            at,
                          ),
                        );
                  final row = items[i].row;
                  if (row == null) return _under(bar, null);
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
                        // A hold opens the thread's menu, as the right
                        // button does; its Select all ticks the thread.
                        onLongPress: (at) => _showConversationMenu(
                          context,
                          ref,
                          actions,
                          conversation,
                          at,
                        ),
                        onContextMenu: (at) => _showConversationMenu(
                          context,
                          ref,
                          actions,
                          conversation,
                          at,
                        ),
                        ownAddresses: ownAddresses,
                        showRecipients: outgoing(conversation.newest.folderId),
                        format: rowFormatFor(
                          leadOf(conversation, ownAddresses),
                          formats,
                          ownAddresses,
                        ),
                        pinned: isPinned(conversation.messages),
                        showAttachments: filesOnRows,
                      ),
                    ));
                  }

                  final m = row.message!;
                  if (row.foreign) {
                    // Your reply from Sent, inside the thread it answers. It
                    // opens like any message, with the folder it lives in on
                    // it, and nothing done to the thread reaches it: no
                    // swipe, no drag, no tick.
                    return _under(
                      bar,
                      Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: MessageTile(
                          key: ValueKey('tile-other:${m.id}'),
                          message: m,
                          isSelected: m.id == selectedId,
                          density: density,
                          folderLabel: index[m.folderId]?.displayName,
                          showRecipients: true,
                          showAttachments: filesOnRows,
                          accountColor:
                              isUnified ? accountColors[m.accountId] : null,
                          onTap: () {
                            ref
                                .read(selectedMessageIdProvider.notifier)
                                .select(m.id);
                            widget.onOpen(m);
                          },
                          onLongPress: (at) => _showMessageMenu(
                              context, ref, actions, m, at,
                              tickable: false),
                          onContextMenu: (at) => _showMessageMenu(
                              context, ref, actions, m, at,
                              tickable: false),
                        ),
                      ),
                    );
                  }
                  final tile = MessageTile(
                    message: m,
                    isSelected: m.id == selectedId,
                    isTicked: selecting ? ticked.contains(m.id) : null,
                    onTicked: (_) => ref
                        .read(selectedMessageIdsProvider.notifier)
                        .toggle(m.id),
                    density: density,
                    accountColor: isUnified ? accountColors[m.accountId] : null,
                    showRecipients: outgoing(m.folderId),
                    format: rowFormatFor(m, formats, ownAddresses),
                    pinned: pinned.contains(m.id),
                    showAttachments: filesOnRows,
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
                      // Opened here as well as by the reading pane. The pane
                      // tells the marker as it opens, and it does not open
                      // again for a message the app had already landed on — so
                      // tapping the message the folder opened at would leave it
                      // unread, which is the one case this has to get right.
                      // When it is marked read is Settings, View's to say
                      // (see ReadMarker); quiet when it fails, as the pane is.
                      ref.read(readMarkerProvider).opened(
                            m.id,
                            mark: m.isRead
                                ? null
                                : () => actions.markOpened(m),
                          );
                      widget.onOpen(m);
                    },
                    // No long press of its own: the draggable around this
                    // row owns the long press, and opens the menu on its
                    // behalf. Two long-press recognisers on one row and the
                    // inner one wins the gesture, which is a drag that never
                    // starts.
                    onContextMenu: (at) =>
                        _showMessageMenu(context, ref, actions, m, at),
                    key: ValueKey('tile:${m.id}'),
                  );
                  final swipeable = _SwipeableRow(
                    key: ValueKey(m.id),
                    messages: [m],
                    actions: actions,
                    child: Listener(
                      onPointerDown: (e) => _heldAt = e.position,
                      child: LongPressDraggable<DraggedMessages>(
                        data: DraggedMessages([m]),
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: _DragFeedback(message: m),
                        childWhenDragging: Opacity(opacity: 0.35, child: tile),
                        onDragStarted: () => _pulledOut = false,
                        // Sharing the screen, the pull becomes a drag out of
                        // the app — as .eml files the other window can take —
                        // once the finger moves, and Android takes the
                        // finger, which ends this one. Every ticked message
                        // comes along if this row is one of them.
                        onDragUpdate: (d) {
                          final from = _heldAt;
                          if (_pulledOut ||
                              from == null ||
                              (d.globalPosition - from).distance < kTouchSlop ||
                              !ref.read(multiWindowModeProvider)) {
                            return;
                          }
                          _pulledOut = true;
                          final now = ref.read(selectedMessageIdsProvider);
                          dragMessages(
                            ref,
                            now.contains(m.id)
                                ? [
                                    for (final x in messages)
                                      if (now.contains(x.id)) x,
                                  ]
                                : [m],
                          );
                        },
                        // Held and let go where it was: the row's menu, as a
                        // right click opens it, since a finger has no right
                        // button. Pulled onto a folder, or anywhere else,
                        // it was a drag.
                        onDragEnd: (d) {
                          final from = _heldAt;
                          if (d.wasAccepted ||
                              _pulledOut ||
                              from == null ||
                              (d.offset - from).distance >= kTouchSlop) {
                            return;
                          }
                          _showMessageMenu(context, ref, actions, m, d.offset);
                        },
                        child: tile,
                      ),
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
  /// messages newest first, matching the order of the list around it, your
  /// replies from Sent among them (see [Conversation.others]). A message
  /// with only your reply beside it is a thread of two, so the reply can be
  /// seen.
  static List<_Row> _conversationRows(
    List<Conversation> conversations,
    Set<String> expandedIds,
  ) {
    final rows = <_Row>[];
    for (final c in conversations) {
      if (!c.isThread && c.others.isEmpty) {
        rows.add(_Row.message(c.newest));
        continue;
      }
      final isExpanded = expandedIds.contains(c.id);
      rows.add(_Row.conversation(c, isExpanded: isExpanded));
      if (isExpanded) {
        final own = {for (final m in c.messages) m.id};
        for (final m in c.everything.reversed) {
          rows.add(
            _Row.message(m, indented: true, foreign: !own.contains(m.id)),
          );
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
  /// A closed bar is the exception, an item with no row, standing in for
  /// all the rows it has folded away.
  ///
  /// A column even then, so closing and opening a bar keeps the bar itself
  /// and its arrow turns rather than jumping.
  static Widget _under(Widget? bar, Widget? row) => bar == null
      ? row!
      : Column(
          mainAxisSize: MainAxisSize.min,
          children: [bar, ?row],
        );

  /// [rows] under their bars, as the list's items: [groupOf] says which.
  ///
  /// A row's bar is decided at its own level: under an open thread that is
  /// the thread, not its oldest message, which could be from days before
  /// and put a second "Today" in the middle of today's mail. A group in
  /// [collapsed] is one item, its bar alone.
  static List<_Item> _underBars(
    List<_Row> rows,
    ListGroup Function(_Row row) groupOf,
    Set<String> collapsed,
  ) {
    final sections = <_Section>[];
    for (final row in rows) {
      if (row.indented && sections.isNotEmpty) {
        sections.last.rows.add(row);
        continue;
      }
      final group = groupOf(row);
      if (sections.isEmpty || sections.last.group != group) {
        sections.add(
          _Section(group, collapsed: collapsed.contains(group.key)),
        );
      }
      sections.last.rows.add(row);
    }
    return [
      for (final s in sections)
        if (s.collapsed)
          _Item(null, bar: s)
        else
          for (var i = 0; i < s.rows.length; i++)
            _Item(s.rows[i], bar: i == 0 ? s : null),
    ];
  }

  /// The bar's own menu, for the group as a whole: from a long press, which
  /// on a bar has no ticking to do, or a right click.
  Future<void> _showDateBarMenu(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    String folderId,
    _Section section,
    Offset at,
  ) async {
    final messages = section.messages;
    final ids = [for (final m in messages) m.id];
    // "Select all 1" is not English; one message is just the message.
    final all = messages.length == 1 ? '' : ' all ${messages.length}';
    final unread = anyUnread(messages);
    // A toggle, as read and unread are: all ticked, the item unticks them,
    // and with nothing else ticked the boxes go with them. Only part
    // ticked, it ticks the rest.
    final ticked = ref.read(selectedMessageIdsProvider);
    final allTicked = ids.every(ticked.contains);
    final choice = await _menuAt(context, at, [
      section.collapsed
          ? _item('fold', Icons.unfold_more, 'Expand')
          : _item('fold', Icons.unfold_less, 'Collapse'),
      allTicked
          ? _item('unselect', Icons.remove_done, 'Unselect$all')
          : _item('select', Icons.checklist, 'Select$all'),
      _item(
        'read',
        unread
            ? Icons.mark_email_read_outlined
            : Icons.mark_email_unread_outlined,
        unread ? 'Mark$all as read' : 'Mark$all as unread',
      ),
    ]);
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'fold':
        ref
            .read(collapsedDateGroupsProvider.notifier)
            .toggle(folderId, section.group.key);
      case 'select':
        ref.read(selectedMessageIdsProvider.notifier).addAll(ids);
      case 'unselect':
        ref.read(selectedMessageIdsProvider.notifier).removeAll(ids);
      case 'read':
        await actions.setRead(context, messages, unread);
    }
  }

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

  /// A row of the list's menus: a little shorter than a menu's own, since
  /// Ron found the message's menu longer than the screen (3.7.0). [more]
  /// says another menu comes after it.
  static PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String text, {
    Color? color,
    bool more = false,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
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
          if (more) const Icon(Icons.chevron_right, size: 20),
        ],
      ),
    );
  }

  static const _gap = PopupMenuDivider(height: 9);

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
    final ticked = ref.read(selectedMessageIdsProvider);
    if (ticked.length > 1 &&
        conversation.messages.any((m) => ticked.contains(m.id))) {
      return _showTickedMenu(context, ref, actions, at);
    }
    final count = conversation.length;
    final unread = conversation.hasUnread;
    final flagged = conversation.isFlagged;
    final pins = ref.read(pinnedMessagesProvider);
    final pinned = conversation.messages.any((m) => pins.contains(m.id));
    final error = Theme.of(context).colorScheme.error;

    final choice = await _menuAt(context, at, [
      _item('select', Icons.checklist, 'Select all $count'),
      _gap,
      _item('move', Icons.drive_file_move_outline, 'Move all $count to…'),
      _item('archive', Icons.archive_outlined, 'Archive all $count'),
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
      _item(
        'pin',
        pinned ? Icons.push_pin : Icons.push_pin_outlined,
        pinned ? 'Unpin' : 'Pin to top',
      ),
      _gap,
      _item('delete', Icons.delete_outline, 'Delete all $count', color: error),
    ]);
    if (choice == null || !context.mounted) return;

    final messages = conversation.messages;
    switch (choice) {
      // Every message in the thread, so a reply arriving later finds the
      // thread still pinned by the ones before it.
      case 'pin':
        ref.read(pinnedMessagesProvider.notifier).setPinned(
              [for (final m in messages) m.id],
              !pinned,
            );
      case 'select':
        ref.read(selectedMessageIdsProvider.notifier).addAll([
          for (final m in messages) m.id,
        ]);
      case 'move':
        await actions.moveWithPrompt(context, messages);
      case 'archive':
        await actions.archive(context, messages);
      case 'delete':
        await actions.delete(context, messages);
      // Through the actions, as the date bar's menu and the swipe go: each
      // message is tried and what failed is said. Looped here, the first
      // that failed stopped the rest, and nothing said so.
      case 'read':
        await actions.setRead(context, messages, unread);
      case 'flag':
        await actions.setFlagged(context, messages, !flagged);
    }
  }

  /// Everything that can be done to one message, from a right click or a
  /// hold: Reply, Reply all, Forward and Delete as a row of icons across
  /// the top, what is done most by name under them, and the rest behind
  /// More, so the menu fits on the screen (3.7.0). With several ticked and
  /// this one among them, it is their menu instead. [tickable] is false for
  /// a row that cannot be ticked: your reply from Sent, inside the thread
  /// it answers.
  Future<void> _showMessageMenu(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    MailMessage message,
    Offset at, {
    bool tickable = true,
  }) async {
    final ticked = ref.read(selectedMessageIdsProvider);
    if (tickable && ticked.length > 1 && ticked.contains(message.id)) {
      return _showTickedMenu(context, ref, actions, at);
    }
    final steps = ref.read(quickStepsProvider);
    final error = Theme.of(context).colorScheme.error;
    final inJunk = isInJunk(ref, message);
    var choice = await _menuAt(context, at, [
      _MenuIcons([
        (value: 'reply', icon: Icons.reply, tooltip: 'Reply', color: null),
        (
          value: 'replyAll',
          icon: Icons.reply_all,
          tooltip: 'Reply all',
          color: null,
        ),
        (value: 'forward', icon: Icons.forward, tooltip: 'Forward', color: null),
        (
          value: 'delete',
          icon: Icons.delete_outline,
          tooltip: 'Delete',
          color: error,
        ),
      ]),
      _gap,
      if (tickable) _item('select', Icons.checklist, 'Select'),
      _item('move', Icons.drive_file_move_outline, 'Move to…'),
      if (archiveTargetFor(
                ref.read(foldersProvider).value ?? const {},
                message.accountId,
              )
              case final archive?
          when archive != message.folderId)
        _item('archive', Icons.archive_outlined, 'Archive'),
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
      _item('followUp', Icons.alarm_outlined, 'Follow up…'),
      _item('snooze', Icons.snooze_outlined, 'Snooze…'),
      if (ref.read(pinnedMessagesProvider).contains(message.id))
        _item('pin', Icons.push_pin, 'Unpin')
      else
        _item('pin', Icons.push_pin_outlined, 'Pin to top'),
      if (inJunk) _item('notJunk', Icons.report_off_outlined, 'Not junk'),
      // Only the steps that can finish on this message: one that files
      // into another account's folder cannot. A line each, by name.
      for (final step in steps.where((s) => s.appliesTo(message.accountId)))
        _item('qs:${step.id}', iconForQuickStep(step), step.name),
      _gap,
      _item('more', Icons.more_horiz, 'More', more: true),
    ]);
    if (choice == 'more' && context.mounted) {
      choice = await _menuAt(context, at, [
        if (ref.read(windowsAvailableProvider).value ?? false)
          _item('window', Icons.open_in_new, 'Open in new window'),
        _item(
          'forwardAttach',
          Icons.attach_email_outlined,
          'Forward as attachment',
        ),
        _item('copy', Icons.copy_outlined, 'Copy'),
        _item('event', Icons.event_outlined, 'Meeting from this message…'),
        _item('print', Icons.print_outlined, 'Print or save as PDF…'),
        _item('threats', Icons.shield_outlined, 'Check for threats…'),
        if (_ruleAccountFor(ref, message) != null)
          _item('rule', Icons.rule, 'Create rule…'),
        if (!inJunk &&
            !ref.read(senderBlocksProvider).blocks(message.from.email))
          _item('block', Icons.block, 'Block sender'),
      ]);
    }
    if (choice == null || !context.mounted) return;

    if (choice.startsWith('qs:')) {
      final step = steps.firstWhere((s) => s.id == choice!.substring(3));
      await applyQuickStep(context, ref,
          step: step, message: message, listId: actions.listId);
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
        if (!context.mounted) return;
        await openNewMeetingFromMessage(context, ref, message, body);
      // The body as the reading pane would show it, read first: from the
      // list it may not have been opened yet.
      case 'print':
        final MailBody body;
        try {
          body = await ref.read(mailEngineProvider).loadMessageBody(message.id);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                duration: kBottomMessage,
                content: Text('Could not print. $e'),
              ));
          }
          return;
        }
        if (!context.mounted) return;
        await printMessage(context, ref, message, body);
      case 'threats':
        await showThreatCheck(context, message);
      case 'rule':
        final account = _ruleAccountFor(ref, message);
        if (account != null) {
          await openRuleEditor(context, account, message: message);
        }
      case 'select':
        ref.read(selectedMessageIdsProvider.notifier).addAll([message.id]);
      case 'move':
        await actions.moveWithPrompt(context, [message]);
      case 'archive':
        await actions.archive(context, [message]);
      // Through the actions, which send a search hit from another folder
      // to the engine: the open list passed over it without a word.
      case 'read':
        await actions.setRead(context, [message], !message.isRead);
      case 'flag':
        await actions.setFlagged(context, [message], !message.isFlagged);
      case 'followUp':
        await showFollowUpSheet(context, ref,
            listId: actions.listId, messages: [message]);
      case 'snooze':
        await showSnoozeSheet(context, ref,
            listId: actions.listId, messages: [message]);
      case 'pin':
        final pins = ref.read(pinnedMessagesProvider.notifier);
        pins.setPinned([message.id], !pins.isPinned(message.id));
      case 'block':
        await blockSender(context, ref, actions.listId, message);
      case 'notJunk':
        await notJunk(context, ref, actions.listId, [message]);
      case 'delete':
        await actions.delete(context, [message]);
    }
  }

  /// The account a rule made from [message] would go on, where its server
  /// runs rules: Outlook's Create rule, as the open message's menu has it.
  static Account? _ruleAccountFor(WidgetRef ref, MailMessage message) {
    final account = ref
        .read(accountsProvider)
        .value
        ?.where((a) => a.id == message.accountId)
        .firstOrNull;
    return account != null && canReachServerSettings(account) ? account : null;
  }

  /// What is ticked, from a right click or a hold on one of the ticked
  /// rows, as Outlook acts on the selection: the selection bar's actions,
  /// each saying how many it is about, and the ticks let go once done, as
  /// the bar lets them go. Read and flag go the way most of them are not.
  Future<void> _showTickedMenu(
    BuildContext context,
    WidgetRef ref,
    MessageActions actions,
    Offset at,
  ) async {
    final ticked = ref.read(selectedMessageIdsProvider);
    final listed = ref.read(searchQueryProvider).trim().isNotEmpty
        ? ref.read(searchResultsProvider).value
        : ref.read(messagesProvider(actions.listId)).value;
    final chosen = [
      for (final m in listed ?? const <MailMessage>[])
        if (ticked.contains(m.id)) m,
    ];
    if (chosen.isEmpty) return;
    final n = chosen.length;
    final mostlyUnread = chosen.where((m) => !m.isRead).length > n / 2;
    final mostlyUnflagged = chosen.where((m) => !m.isFlagged).length > n / 2;
    final pins = ref.read(pinnedMessagesProvider);
    final pinned = chosen.every((m) => pins.contains(m.id));
    final error = Theme.of(context).colorScheme.error;

    final choice = await _menuAt(context, at, [
      _item('move', Icons.drive_file_move_outline, 'Move $n to…'),
      _item('archive', Icons.archive_outlined, 'Archive $n'),
      _item(
        'read',
        mostlyUnread
            ? Icons.mark_email_read_outlined
            : Icons.mark_email_unread_outlined,
        mostlyUnread ? 'Mark $n as read' : 'Mark $n as unread',
      ),
      _item(
        'flag',
        mostlyUnflagged ? Icons.flag_outlined : Icons.flag,
        mostlyUnflagged ? 'Flag $n' : 'Remove flags',
      ),
      _item('followUp', Icons.alarm_outlined, 'Follow up…'),
      _item('snooze', Icons.snooze_outlined, 'Snooze…'),
      _item(
        'pin',
        pinned ? Icons.push_pin : Icons.push_pin_outlined,
        pinned ? 'Unpin' : 'Pin to top',
      ),
      _item(
        'forwardAttach',
        Icons.attach_email_outlined,
        'Forward $n as attachments',
      ),
      _gap,
      _item('delete', Icons.delete_outline, 'Delete $n', color: error),
    ]);
    if (choice == null || !context.mounted) return;

    final selection = ref.read(selectedMessageIdsProvider.notifier);
    switch (choice) {
      // Let go only when something moved, as the bar's Move: the sheet
      // closed without a choice keeps them ticked for another try.
      case 'move':
        if (await actions.moveWithPrompt(context, chosen)) selection.clear();
      case 'archive':
        if (await actions.archive(context, chosen)) selection.clear();
      case 'read':
        await actions.setRead(context, chosen, mostlyUnread);
        selection.clear();
      case 'flag':
        await actions.setFlagged(context, chosen, mostlyUnflagged);
        selection.clear();
      case 'followUp':
        await showFollowUpSheet(context, ref,
            listId: actions.listId, messages: chosen);
      case 'snooze':
        if (await showSnoozeSheet(context, ref,
            listId: actions.listId, messages: chosen)) {
          selection.clear();
        }
      case 'pin':
        ref.read(pinnedMessagesProvider.notifier).setPinned(
              [for (final m in chosen) m.id],
              !pinned,
            );
        selection.clear();
      case 'forwardAttach':
        await forwardAsAttachment(context, ref, chosen);
        selection.clear();
      case 'delete':
        await actions.delete(context, chosen);
        selection.clear();
    }
  }
}

/// One of the buttons across the top of a message's menu.
typedef _MenuIcon = ({
  String value,
  IconData icon,
  String tooltip,
  Color? color,
});

/// The commonest things done to a message as a row of icons at the top of
/// its menu, as Windows' own menus have them: four rows of the menu in
/// one. Each says what it is when held, or under a mouse.
class _MenuIcons extends PopupMenuEntry<String> {
  const _MenuIcons(this.buttons);

  final List<_MenuIcon> buttons;

  @override
  double get height => 48;

  @override
  bool represents(String? value) => buttons.any((b) => b.value == value);

  @override
  State<_MenuIcons> createState() => _MenuIconsState();
}

class _MenuIconsState extends State<_MenuIcons> {
  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final b in widget.buttons)
            IconButton(
              key: ValueKey('menu-${b.value}'),
              tooltip: b.tooltip,
              icon: Icon(b.icon, color: b.color),
              // As a menu's own row closes it, with what was chosen.
              onPressed: () => Navigator.of(context).pop(b.value),
            ),
        ],
      );
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
      // Gmail too, out of this folder into All Mail; an account with no
      // archive at all is told so rather than the swipe doing nothing.
      case SwipeAction.archive:
        await actions.archive(context, messages);
      case SwipeAction.snooze:
        await showSnoozeSheet(context, ref,
            listId: actions.listId, messages: messages);
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

IconData swipeActionIcon(SwipeAction action) => switch (action) {
  SwipeAction.none => Icons.block,
  SwipeAction.delete => Icons.delete_outline,
  SwipeAction.move => Icons.drive_file_move_outline,
  SwipeAction.toggleRead => Icons.mark_email_unread_outlined,
  SwipeAction.toggleFlag => Icons.flag_outlined,
  SwipeAction.archive => Icons.archive_outlined,
  SwipeAction.snooze => Icons.snooze_outlined,
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
    SwipeAction.snooze => 'Snooze',
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
  const _Row._(
    this.message,
    this.conversation,
    this.isExpanded,
    this.indented,
    this.foreign,
  );

  factory _Row.message(
    MailMessage message, {
    bool indented = false,
    bool foreign = false,
  }) =>
      _Row._(message, null, false, indented, foreign);

  factory _Row.conversation(Conversation c, {required bool isExpanded}) =>
      _Row._(null, c, isExpanded, false, false);

  final MailMessage? message;
  final Conversation? conversation;
  final bool isExpanded;

  /// A message shown inside an open thread rather than at the top level.
  final bool indented;

  /// A message from another folder shown inside an open thread: your
  /// reply, from Sent. Not one of the list's own.
  final bool foreign;

  /// When this row happened, whichever kind it is.
  DateTime get date => lead.date;

  /// The message that stands for the row, and decides its bar: a thread's
  /// newest.
  MailMessage get lead => message ?? conversation!.newest;

  /// What the row stands for: a thread's row, every message in it.
  List<MailMessage> get messages => conversation?.messages ?? [message!];
}

/// The rows under one bar.
class _Section {
  _Section(this.group, {required this.collapsed});

  final ListGroup group;
  final bool collapsed;
  final rows = <_Row>[];

  /// Every message under the bar, once each: an open thread's own rows are
  /// the thread's messages again.
  List<MailMessage> get messages => [
        for (final r in rows)
          if (!r.indented) ...r.messages,
      ];
}

/// One item of the list: a row, with its group's bar over it when it is the
/// group's first; or, for a closed group, the bar on its own.
class _Item {
  const _Item(this.row, {this.bar});

  final _Row? row;
  final _Section? bar;
}

/// The bar that separates one day from the next.
///
/// Only where the list is in date order. Sorted by sender or subject the
/// rows are not in date order at all, and a date bar over them would be
/// describing a grouping that is not there.
///
/// A tap anywhere on it closes the group, as the arrow says; the arrow
/// alone would be a target the size of a letter. A long press or a right
/// click is the menu. Closed, it says how many messages are folded away
/// and how many of those are unread: a closed Today still takes the
/// morning's mail, and a bar that said nothing would hide it.
class _DateBar extends StatelessWidget {
  const _DateBar({
    super.key,
    required this.label,
    required this.collapsed,
    required this.messages,
    required this.onToggle,
    required this.onMenu,
  });

  final String label;
  final bool collapsed;

  /// Everything under the bar.
  final List<MailMessage> messages;

  final VoidCallback onToggle;
  final void Function(Offset at) onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final unread = collapsed ? messages.where((m) => !m.isRead).length : 0;
    return Container(
      width: double.infinity,
      // Shaded and underlined in the accent colour, so the bar reads as a
      // heading and not as one more row.
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(
          bottom: BorderSide(
            color: scheme.primary.withValues(alpha: 0.7),
            width: 1.5,
          ),
        ),
      ),
      // Its own see-through Material, so the ripple shows over the shading
      // rather than under it.
      child: Material(
        type: MaterialType.transparency,
        // The long press from outside the ink: InkWell's own does not say
        // where the finger is, and the menu belongs under it.
        child: GestureDetector(
          onLongPressStart: (d) {
            Feedback.forLongPress(context);
            onMenu(d.globalPosition);
          },
          child: InkWell(
            onTap: onToggle,
            onSecondaryTapUp: (d) => onMenu(d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 16, 5),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: collapsed ? -0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  if (collapsed)
                    Text.rich(
                      TextSpan(
                        children: [
                          if (unread > 0)
                            TextSpan(
                              text: '$unread unread · ',
                              style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          TextSpan(text: '${messages.length}'),
                        ],
                      ),
                      style: style,
                    ),
                ],
              ),
            ),
          ),
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
///
/// With [onTap] it waits to be asked from the start: see where the list
/// passes it.
class _LoadMoreRow extends ConsumerStatefulWidget {
  const _LoadMoreRow({
    super.key,
    required this.folderId,
    this.onTap = false,
  });

  final String folderId;
  final bool onTap;

  @override
  ConsumerState<_LoadMoreRow> createState() => _LoadMoreRowState();
}

class _LoadMoreRowState extends ConsumerState<_LoadMoreRow> {
  Object? _error;
  late bool _waiting = widget.onTap;

  @override
  void initState() {
    super.initState();
    if (!_waiting) _fetch();
  }

  void _fetch() {
    // After the frame: a provider must not change while the list that
    // watches it is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _error = null);
      try {
        await ref.read(messagesProvider(widget.folderId).notifier).loadMore();
        // A page that went under the closed bar leaves this row where it
        // was, and it would spin there for good.
        if (mounted && widget.onTap) setState(() => _waiting = true);
      } catch (e) {
        if (mounted) setState(() => _error = e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_waiting) {
      return InkWell(
        onTap: () {
          setState(() => _waiting = false);
          _fetch();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Load older messages',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }
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
