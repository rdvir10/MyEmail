import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/conversations.dart';
import '../../state/display_providers.dart';
import '../../state/list_navigation.dart';
import '../../state/message_providers.dart';
import '../shell/pane_focus.dart';
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
  });

  final String listId;
  final Widget child;

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
    for (final c in groupIntoConversations(_messages)) {
      if (!c.isThread || !c.messages.any((m) => m.id == id)) continue;
      final expanded = ref.read(expandedConversationsProvider);
      if (expanded.contains(c.id) != open) {
        ref.read(expandedConversationsProvider.notifier).toggle(c.id);
      }
      return;
    }
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
      // The shell's node for the list, so F6 can come back to it.
      focusNode: ref.watch(paneFocusProvider).list,
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
