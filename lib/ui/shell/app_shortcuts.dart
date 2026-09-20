import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../state/list_navigation.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/search_providers.dart';
import '../../state/sync_now.dart';
import '../compose/open_compose.dart';
import '../messages/message_actions.dart';
import 'pane_focus.dart';

/// Keyboard commands that work anywhere in the shell.
///
/// The bindings are Outlook's, because the app is shaped like Outlook and
/// anyone who reaches for Ctrl+R here has learned it there. The one thing
/// they need in common is to stay out of text fields: Ctrl+F while typing
/// a search must not forward a message, so nothing here fires while the
/// focus is in something editable. The list's own keys (arrows, Enter,
/// Space, Delete) live with the list in `MessageListKeyboard`; these are
/// the commands that act on whatever is open, from wherever the focus is.
///
/// One table drives both the handler and the help sheet, so the sheet
/// cannot describe a key the app does not answer to.
class AppShortcuts extends ConsumerStatefulWidget {
  const AppShortcuts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends ConsumerState<AppShortcuts> {
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Down only, not repeat: holding Ctrl+R must not open a stack of replies.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Seen from a text field too: what matters is that there is a keyboard.
    ref.read(keyboardInUseProvider.notifier).noticed();
    if (focusIsInTextField()) return KeyEventResult.ignored;
    final command = commandFor(
      event.logicalKey,
      control: HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );
    if (command == null) return KeyEventResult.ignored;
    _run(command);
    return KeyEventResult.handled;
  }

  Future<void> _run(AppCommand command) async {
    final listId = ref.read(effectiveSelectedFolderIdProvider);
    final message = ref.read(selectedMessageProvider);

    switch (command) {
      case AppCommand.newMessage:
        await openCompose(context, ref, kind: ComposeKind.newMessage);
      case AppCommand.reply:
        if (message != null) {
          await openCompose(context, ref,
              kind: ComposeKind.reply, original: message);
        }
      case AppCommand.replyAll:
        if (message != null) {
          await openCompose(context, ref,
              kind: ComposeKind.replyAll, original: message);
        }
      case AppCommand.forward:
        if (message != null) {
          await openCompose(context, ref,
              kind: ComposeKind.forward, original: message);
        }
      case AppCommand.delete:
        if (message != null && listId != null) {
          await MessageActions(ref, listId).delete(context, [message]);
        }
      case AppCommand.markRead:
      case AppCommand.markUnread:
        if (message != null && listId != null) {
          await ref
              .read(messagesProvider(listId).notifier)
              .setRead(message.id, command == AppCommand.markRead);
        }
      case AppCommand.flag:
        if (message != null && listId != null) {
          await ref
              .read(messagesProvider(listId).notifier)
              .setFlagged(message.id, !message.isFlagged);
        }
      case AppCommand.move:
        if (message != null && listId != null) {
          await MessageActions(ref, listId).moveWithPrompt(context, [message]);
        }
      case AppCommand.search:
        ref.read(searchFocusRequestsProvider.notifier).request();
      case AppCommand.sync:
        try {
          await syncNow(ref, listId);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text('Could not sync: $e')));
          }
        }
      case AppCommand.help:
        await showShortcutsHelp(context);
      case AppCommand.nextPane:
        ref.read(paneFocusProvider).neighbour(1)?.requestFocus();
      case AppCommand.previousPane:
        ref.read(paneFocusProvider).neighbour(-1)?.requestFocus();
      case AppCommand.nextMessage:
      case AppCommand.previousMessage:
        _step(listId, command == AppCommand.nextMessage ? 1 : -1);
      case AppCommand.inbox:
        final inbox = ref.read(defaultFolderIdProvider);
        if (inbox != null) {
          ref.read(selectedFolderIdProvider.notifier).select(inbox);
        }
    }
  }

  /// The message after or before the open one, from wherever the focus is:
  /// reading one message and wanting the next should not mean finding the
  /// list first.
  void _step(String? listId, int delta) {
    if (listId == null) return;
    final messages = ref.read(messagesProvider(listId)).value ?? const [];
    final next = neighbourOf(messages, ref.read(selectedMessageIdProvider), delta);
    if (next == null) return;
    ref.read(selectedMessageIdProvider.notifier).select(next);
    ref.read(lastOpenedInFolderProvider.notifier).remember(listId, next);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Not focusable itself: it listens to what bubbles up from whatever
      // has the focus, and must not take the focus away from the list.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}

/// What a shell-wide key press can do.
enum AppCommand {
  newMessage,
  reply,
  replyAll,
  forward,
  delete,
  markRead,
  markUnread,
  flag,
  move,
  search,
  sync,
  help,
  nextPane,
  previousPane,
  nextMessage,
  previousMessage,
  inbox,
}

/// The command a key press means, or null if it is not one.
AppCommand? commandFor(
  LogicalKeyboardKey key, {
  required bool control,
  required bool shift,
}) {
  if (control) {
    return switch (key) {
      LogicalKeyboardKey.keyN => AppCommand.newMessage,
      LogicalKeyboardKey.keyR =>
        shift ? AppCommand.replyAll : AppCommand.reply,
      LogicalKeyboardKey.keyF => AppCommand.forward,
      LogicalKeyboardKey.keyD => AppCommand.delete,
      LogicalKeyboardKey.keyQ => AppCommand.markRead,
      LogicalKeyboardKey.keyU => AppCommand.markUnread,
      LogicalKeyboardKey.keyG when shift => AppCommand.flag,
      LogicalKeyboardKey.keyV when shift => AppCommand.move,
      LogicalKeyboardKey.keyE => AppCommand.search,
      LogicalKeyboardKey.slash => AppCommand.help,
      LogicalKeyboardKey.period => AppCommand.nextMessage,
      LogicalKeyboardKey.comma => AppCommand.previousMessage,
      LogicalKeyboardKey.keyI when shift => AppCommand.inbox,
      _ => null,
    };
  }
  return switch (key) {
    LogicalKeyboardKey.insert => AppCommand.flag,
    LogicalKeyboardKey.f3 => AppCommand.search,
    LogicalKeyboardKey.f9 => AppCommand.sync,
    LogicalKeyboardKey.f1 => AppCommand.help,
    LogicalKeyboardKey.f6 => shift ? AppCommand.previousPane : AppCommand.nextPane,
    _ => null,
  };
}

/// One line of the help sheet.
class ShortcutHelp {
  const ShortcutHelp(this.keys, this.does);

  final String keys;
  final String does;
}

/// Everything the keyboard does, grouped the way the screen is.
const shortcutHelp = <String, List<ShortcutHelp>>{
  'Getting around': [
    ShortcutHelp('F6  /  Shift+F6', 'Next or previous pane: folders, list, message'),
    ShortcutHelp('Ctrl+.  /  Ctrl+,', 'Next or previous message, from anywhere'),
    ShortcutHelp('Ctrl+Shift+I', 'Go to the Inbox'),
    ShortcutHelp('Ctrl+E  or  F3', 'Search'),
  ],
  'In the folder tree': [
    ShortcutHelp('↑  ↓', 'Previous or next folder (it opens as you go)'),
    ShortcutHelp('→', 'Show the folders inside'),
    ShortcutHelp('←', 'Hide them, or go up to the folder above'),
    ShortcutHelp('Home  End', 'First or last folder'),
    ShortcutHelp('Enter', 'Choose (closes the drawer on a phone)'),
  ],
  'While reading': [
    ShortcutHelp('↑  ↓', 'Scroll'),
    ShortcutHelp('Space  Page Down  /  Shift+Space  Page Up', 'A screen at a time'),
    ShortcutHelp('Home  End', 'Top or bottom'),
    ShortcutHelp('Esc', 'Back to the list'),
  ],
  'Anywhere': [
    ShortcutHelp('Ctrl+N', 'New message'),
    ShortcutHelp('Ctrl+R', 'Reply'),
    ShortcutHelp('Ctrl+Shift+R', 'Reply all'),
    ShortcutHelp('Ctrl+F', 'Forward'),
    ShortcutHelp('Ctrl+D', 'Delete'),
    ShortcutHelp('Ctrl+Q', 'Mark as read'),
    ShortcutHelp('Ctrl+U', 'Mark as unread'),
    ShortcutHelp('Insert  or  Ctrl+Shift+G', 'Flag or unflag'),
    ShortcutHelp('Ctrl+Shift+V', 'Move to a folder'),
    ShortcutHelp('F9', 'Check for mail now'),
    ShortcutHelp('F1  or  Ctrl+/', 'This list'),
  ],
  'In the message list': [
    ShortcutHelp('↑  ↓', 'Previous or next message'),
    ShortcutHelp('Home  End', 'First or last message'),
    ShortcutHelp('Page Up  Page Down', 'Ten messages at a time'),
    ShortcutHelp('Enter', 'Open'),
    ShortcutHelp('→  ←', 'Open or close a conversation'),
    ShortcutHelp('Space', 'Tick or untick'),
    ShortcutHelp('Shift+↑  Shift+↓', 'Tick a run of messages'),
    ShortcutHelp('Ctrl+A', 'Tick everything on screen'),
    ShortcutHelp('Delete  or  Backspace', 'Delete'),
    ShortcutHelp('Esc', 'Untick everything'),
  ],
  'While writing': [
    ShortcutHelp('Ctrl+Enter', 'Send'),
    ShortcutHelp('Esc', 'Close (asks about the draft)'),
  ],
};

/// The help sheet: every key, grouped. Reached from F1 and from Settings.
Future<void> showShortcutsHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final section in shortcutHelp.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Text(
                      section.key,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ),
                  for (final s in section.value)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 190,
                            child: Text(
                              s.keys,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(s.does, style: theme.textTheme.bodyMedium),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
