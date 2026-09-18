import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/list_navigation.dart';
import '../../state/message_providers.dart';
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
  });

  final String listId;
  final Widget child;

  /// Off where there is no reading pane. On a phone a message opens as its own
  /// screen, so landing on one would mean walking into a folder and finding a
  /// message already open on top of it.
  final bool landOnOpen;

  /// Enter, where the layout wants opening to do something more than select.
  final void Function(MailMessage)? onOpen;

  @override
  ConsumerState<MessageListKeyboard> createState() =>
      _MessageListKeyboardState();
}

class _MessageListKeyboardState extends ConsumerState<MessageListKeyboard> {
  List<MailMessage> get _messages =>
      ref.read(messagesProvider(widget.listId)).value ?? const [];

  String? get _selected => ref.read(selectedMessageIdProvider);

  void _land() {
    if (!widget.landOnOpen) return;
    final messages = _messages;
    if (messages.isEmpty) return;

    final target = messageToLandOn(
      messages: messages,
      lastOpened: ref.read(lastOpenedInFolderProvider)[widget.listId],
      current: _selected,
    );
    if (target == null || target == _selected) return;
    // byPerson: false — this is the app landing somewhere, not a choice, so
    // the message is shown without being marked read.
    ref.read(selectedMessageIdProvider.notifier).select(target, byPerson: false);
  }

  void _move(int delta) {
    final next = neighbourOf(_messages, _selected, delta);
    if (next == null) return;
    // A key press is a choice, so from here the message counts as opened.
    ref.read(selectedMessageIdProvider.notifier).select(next);
    ref.read(lastOpenedInFolderProvider.notifier).remember(widget.listId, next);
  }

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

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
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
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        final message = _current;
        if (message == null) return KeyEventResult.ignored;
        // Move first, so the list does not leave the person on nothing once
        // the row under them disappears.
        _move(1);
        MessageActions(ref, widget.listId).delete(context, [message]);
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
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
