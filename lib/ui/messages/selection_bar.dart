import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import 'forward_as_attachment.dart';
import 'message_actions.dart';

/// What replaces the list's own heading while messages are ticked.
///
/// Every action here works on the whole selection. They are the same ones the
/// long-press menu offers for a single message, deliberately: someone who has
/// learned what a menu does to one message should not have to learn a second
/// vocabulary to do it to five.
///
/// Read and flag act on what the selection mostly is not — tick five unread
/// messages and the button says "Mark read". A button that toggled each
/// message independently would leave the selection in a mixed state that
/// nobody asked for and cannot be undone in one press.
class SelectionBar extends ConsumerWidget {
  const SelectionBar({
    super.key,
    required this.listId,
    required this.onScreen,
    required this.messages,
    this.selectAllIsEverything = false,
  });

  final String listId;

  /// The rows on offer: the folder's list, or the search's hits. What is
  /// ticked is looked up here, because a tick is only an id.
  final List<MailMessage> messages;

  /// Search: the hits are a bounded set that was asked for, so "select
  /// all" means all of them. A folder holds thousands, and there it means
  /// what is on screen.
  final bool selectAllIsEverything;

  /// The messages the list is showing at this moment.
  ///
  /// Asked for when the button is pressed rather than watched, because it
  /// changes with every pixel of scrolling and nothing here needs to redraw
  /// while it does.
  final List<String> Function() onScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ticked = ref.watch(selectedMessageIdsProvider);
    if (ticked.isEmpty) return const SizedBox.shrink();

    final chosen = [
      for (final m in messages)
        if (ticked.contains(m.id)) m,
    ];
    final actions = MessageActions(ref, listId);

    // "Mostly unread" rather than "any unread": the button should do the thing
    // that changes the most, and say so.
    final mostlyUnread =
        chosen.where((m) => !m.isRead).length > chosen.length / 2;
    final mostlyUnflagged =
        chosen.where((m) => !m.isFlagged).length > chosen.length / 2;

    Future<void> then(Future<void> Function() act) async {
      await act();
      ref.read(selectedMessageIdsProvider.notifier).clear();
    }

    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Stop selecting',
              icon: const Icon(Icons.close),
              onPressed: () =>
                  ref.read(selectedMessageIdsProvider.notifier).clear(),
            ),
            Text('${ticked.length}', style: theme.textTheme.titleMedium),
            // The buttons scroll when the bar is narrower than they are:
            // a phone, or a pane beside a reading pane. Reversed, so the
            // ones at the right edge, Move and Delete, are what shows.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      // What is on screen, not the whole folder. An Inbox holds
                      // thousands, and a button that ticks all of them puts a delete
                      // one press away from a mistake nobody can see the size of.
                      // It adds to the selection, so scrolling and pressing again
                      // takes in the next screenful.
                      tooltip: selectAllIsEverything
                          ? 'Select all results'
                          : 'Select what is on screen',
                      icon: const Icon(Icons.select_all),
                      onPressed: () => ref
                          .read(selectedMessageIdsProvider.notifier)
                          .addAll(
                            selectAllIsEverything
                                ? messages.map((m) => m.id)
                                : onScreen(),
                          ),
                    ),
                    IconButton(
                      tooltip: mostlyUnread ? 'Mark read' : 'Mark unread',
                      icon: Icon(
                        mostlyUnread
                            ? Icons.mark_email_read_outlined
                            : Icons.mark_email_unread_outlined,
                      ),
                      onPressed: () =>
                          then(() =>
                              actions.setRead(context, chosen, mostlyUnread)),
                    ),
                    IconButton(
                      tooltip: mostlyUnflagged ? 'Flag' : 'Remove flag',
                      icon: Icon(
                        mostlyUnflagged ? Icons.flag_outlined : Icons.flag,
                      ),
                      onPressed: () => then(
                        () => actions.setFlagged(
                            context, chosen, mostlyUnflagged),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Forward as attachment',
                      icon: const Icon(Icons.attach_email_outlined),
                      onPressed: () =>
                          then(() => forwardAsAttachment(context, ref, chosen)),
                    ),
                    IconButton(
                      tooltip: 'Move to…',
                      icon: const Icon(Icons.drive_file_move_outline),
                      onPressed: () async {
                        await actions.moveWithPrompt(context, chosen);
                        ref.read(selectedMessageIdsProvider.notifier).clear();
                      },
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await actions.delete(context, chosen);
                        ref.read(selectedMessageIdsProvider.notifier).clear();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
