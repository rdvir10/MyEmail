import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../state/display_providers.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/window_providers.dart';
import '../../domain/window_handoff.dart';
import '../compose/open_compose.dart';
import 'attachment_bar.dart';
import 'date_format.dart';
import '../shell/pane_focus.dart';
import 'html_body_view.dart';
import 'message_actions.dart';
import 'message_source.dart';

/// One open message: a fixed header with actions, then the body.
///
/// Opening an unread message marks it read, as Outlook does; that happens
/// after the first frame so the pane never blocks on the network. The flag
/// and read state shown come from the live list, so a change made here or in
/// the list is reflected immediately in both.
///
/// HTML bodies go into the sandboxed [HtmlBodyView] on a device; plain-text
/// bodies, and every body in the browser preview, render as selectable text.
class ReadingPane extends ConsumerStatefulWidget {
  const ReadingPane({
    super.key,
    required this.message,
    this.onPopOut,
    this.focusNode,
    this.onEscape,
  });

  /// The shell's node for this pane, so F6 can land here. A message on a
  /// screen of its own gets a node of its own.
  final FocusNode? focusNode;

  /// Esc: back to the list on a tablet, back a screen on a phone.
  final VoidCallback? onEscape;

  /// Open this message on a screen of its own. Null when it already is one,
  /// which is what keeps a pop-out button off the popped-out copy.
  ///
  /// A callback rather than a push from in here: the full-screen route lives
  /// in the shell, and the shell already imports this file.
  final VoidCallback? onPopOut;

  final MailMessage message;

  @override
  ConsumerState<ReadingPane> createState() => _ReadingPaneState();
}

class _ReadingPaneState extends ConsumerState<ReadingPane> {
  /// The plain-text body's scroll position; the HTML body scrolls inside
  /// its WebView, reached through [_html].
  final _textScroll = ScrollController();
  final _html = GlobalKey<HtmlBodyViewState>();
  late final FocusNode _ownNode = FocusNode(debugLabel: 'Open message');

  FocusNode get _node => widget.focusNode ?? _ownNode;

  @override
  void dispose() {
    _textScroll.dispose();
    _ownNode.dispose();
    super.dispose();
  }

  /// Reading with the keyboard: arrows nudge, Space and the Page keys move
  /// a screen at a time, Home and End go to the ends. The body is a WebView
  /// on a device, which scrolls itself only when it has native focus, so
  /// the keys are answered here and passed to it as scroll requests.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final screen = ((context.size?.height ?? 600) - 80).clamp(120.0, 4000.0);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _scrollBy(64);
      case LogicalKeyboardKey.arrowUp:
        _scrollBy(-64);
      case LogicalKeyboardKey.pageDown:
        _scrollBy(screen);
      case LogicalKeyboardKey.pageUp:
        _scrollBy(-screen);
      case LogicalKeyboardKey.space:
        _scrollBy(shift ? -screen : screen);
      case LogicalKeyboardKey.home:
        _scrollToEnd(top: true);
      case LogicalKeyboardKey.end:
        _scrollToEnd(top: false);
      case LogicalKeyboardKey.escape:
        if (widget.onEscape == null) return KeyEventResult.ignored;
        widget.onEscape!();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _scrollBy(double dy) {
    final html = _html.currentState;
    if (html != null) {
      html.scrollBy(dy);
    } else if (_textScroll.hasClients) {
      final p = _textScroll.position;
      _textScroll.jumpTo(
        (p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent),
      );
    }
  }

  void _scrollToEnd({required bool top}) {
    final html = _html.currentState;
    if (html != null) {
      html.scrollToEnd(top: top);
    } else if (_textScroll.hasClients) {
      final p = _textScroll.position;
      _textScroll.jumpTo(top ? p.minScrollExtent : p.maxScrollExtent);
    }
  }

  @override
  void initState() {
    super.initState();
    // Only when the person picked this message. A folder that opens with its
    // newest message already selected would otherwise mark that message read
    // every time someone walked past the Inbox, which is a good way to lose
    // mail you meant to come back to. Acting on it — a key, a tap — claims the
    // selection, and it reads as opened from then on.
    if (!widget.message.isRead &&
        ref.read(selectedMessageIdProvider.notifier).chosenByPerson) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
    }
  }

  /// The list this message was opened from: the unified inbox or a folder.
  String? get _listId => ref.read(effectiveSelectedFolderIdProvider);

  Future<void> _markRead() async {
    final listId = _listId;
    if (!mounted || listId == null) return;
    try {
      await ref
          .read(messagesProvider(listId).notifier)
          .setRead(widget.message.id, true);
    } catch (_) {
      // Offline or refused: the message simply stays unread. Nothing to tell
      // the user about an action they did not take.
    }
  }

  /// Delete, from the header. On a screen of its own the screen goes too:
  /// a page showing a message that is no longer anywhere is a lie.
  Future<void> _delete() async {
    final listId = _listId;
    if (listId == null) return;
    final ownScreen = widget.onPopOut == null;
    final navigator = Navigator.of(context);
    await MessageActions(ref, listId).delete(context, [widget.message]);
    if (ownScreen) navigator.maybePop();
  }

  Future<void> _act(Future<void> Function(Messages notifier) op) async {
    final listId = _listId;
    if (listId == null) return;
    try {
      await op(ref.read(messagesProvider(listId).notifier));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not update: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Prefer the live copy so flag changes show at once.
    final live = _listId == null
        ? null
        : ref
            .watch(messagesProvider(_listId!))
            .value
            ?.where((m) => m.id == widget.message.id)
            .firstOrNull;
    final message = live ?? widget.message;
    final body = ref.watch(messageBodyProvider(message.id));

    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: PaneFocusFrame(
        node: _node,
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          child: _Header(
            message: message,
            onPopOut: widget.onPopOut,
            onDelete: _delete,
            onOpenWindow: (ref.watch(windowsAvailableProvider).value ?? false) &&
                    widget.onPopOut != null
                ? () => ref
                    .read(windowOpenerProvider)
                    .open(MessageWindow(message))
                : null,
            // A phone's width, the shell's medium breakpoint: the header
            // has room for one of Flag and Delete, and Delete is the one
            // reached for more.
            compact: MediaQuery.sizeOf(context).width < 600,
            onToggleFlag: () =>
                _act((n) => n.setFlagged(message.id, !message.isFlagged)),
            onToggleRead: () =>
                _act((n) => n.setRead(message.id, !message.isRead)),
            onCompose: (kind) => openCompose(
              context,
              ref,
              kind: kind,
              original: message,
            ),
            // Only once the body is here: there is nothing to save until it
            // has loaded, and a menu item that does nothing is worse than
            // one that is not there yet.
            onSaveSource:
                body.value == null ? null : () => _saveSource(body.value!),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: body.when(
            loading: () => const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Could not load the message.\n$e',
                style: theme.textTheme.bodySmall,
              ),
            ),
            data: (b) => _bodyView(theme, b),
          ),
        ),
      ],
        ),
      ),
    );
  }

  Future<void> _saveSource(MailBody body) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final saved = await saveMessageSource(widget.message, body);
      if (!saved) return; // They changed their mind in the file picker.
      messenger?.showSnackBar(
        const SnackBar(content: Text('Message source saved')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save the source. $e')),
      );
    }
  }

  Widget _bodyView(ThemeData theme, MailBody b) {
    final html = b.html;
    // The WebView is a platform view: Android has it, the browser preview
    // does not. Text is the universal fallback.
    if (html != null && html.trim().isNotEmpty && !kIsWeb) {
      return HtmlBodyView(
        key: _html,
        html: html,
        showImages: ref.watch(displayProvider).alwaysShowImages,
      );
    }
    return SingleChildScrollView(
      controller: _textScroll,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: SelectableText(
        b.text,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.message,
    this.onSaveSource,
    required this.onToggleFlag,
    required this.onToggleRead,
    required this.onCompose,
    required this.onDelete,
    this.onPopOut,
    this.onOpenWindow,
    this.compact = false,
  });

  /// Open this message in a window of its own. Null where there are no
  /// windows, or where this already is one.
  final VoidCallback? onOpenWindow;

  final MailMessage message;
  final VoidCallback onToggleFlag;
  final VoidCallback onToggleRead;
  final VoidCallback onDelete;

  /// Narrow: Delete takes the flag's place in the row and the flag moves
  /// into the menu.
  final bool compact;
  final void Function(ComposeKind kind) onCompose;
  final VoidCallback? onPopOut;

  /// Write the message out as it arrived. Null until the body has loaded.
  final VoidCallback? onSaveSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                message.subject,
                style: theme.textTheme.titleLarge,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // First, not last. It is the one button here that changes
            // where you are rather than what the message is, and grouping it
            // with the three compose actions would invite mis-taps.
            if (onPopOut != null)
              IconButton(
                tooltip: 'Open full screen',
                icon: const Icon(Icons.open_in_full),
                onPressed: onPopOut,
              ),
            IconButton(
              tooltip: 'Reply',
              icon: const Icon(Icons.reply),
              onPressed: () => onCompose(ComposeKind.reply),
            ),
            IconButton(
              tooltip: 'Reply all',
              icon: const Icon(Icons.reply_all),
              onPressed: () => onCompose(ComposeKind.replyAll),
            ),
            IconButton(
              tooltip: 'Forward',
              icon: const Icon(Icons.forward),
              onPressed: () => onCompose(ComposeKind.forward),
            ),
            if (!compact)
              IconButton(
                tooltip: message.isFlagged ? 'Remove flag' : 'Flag',
                icon: Icon(
                  message.isFlagged ? Icons.flag : Icons.flag_outlined,
                  color: message.isFlagged ? scheme.error : null,
                ),
                onPressed: onToggleFlag,
              ),
            IconButton(
              tooltip: message.isRead ? 'Mark as unread' : 'Mark as read',
              icon: Icon(
                message.isRead
                    ? Icons.mark_email_unread_outlined
                    : Icons.mark_email_read_outlined,
              ),
              onPressed: onToggleRead,
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
            // The things that are neither reading nor replying live behind
            // one button, rather than adding another icon to a row that is
            // already the width of the pane.
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) => switch (value) {
                'flag' => onToggleFlag(),
                'window' => onOpenWindow?.call(),
                _ => onSaveSource?.call(),
              },
              itemBuilder: (context) => [
                if (onOpenWindow != null)
                  const PopupMenuItem(
                    value: 'window',
                    child: Text('Open in new window'),
                  ),
                if (compact)
                  PopupMenuItem(
                    value: 'flag',
                    child: Text(message.isFlagged ? 'Remove flag' : 'Flag'),
                  ),
                PopupMenuItem(
                  value: 'source',
                  enabled: onSaveSource != null,
                  child: const Text('Save source…'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Text(_initial(message.from)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Addresses have no spaces, so an unnamed sender would
                  // otherwise wrap mid-word on a phone; clip instead.
                  Text(
                    message.from.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (message.from.name != null)
                    Text(
                      message.from.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    'To: ${message.to.map((a) => a.display).join(', ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatMessageDateLong(message.date),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        // Asked for whenever the message says it has something attached.
        // The list is small and separate from the body, so it arrives while
        // the body is still coming and costs nothing when there is nothing.
        if (message.hasAttachments) AttachmentBar(messageId: message.id),
      ],
    );
  }

  static String _initial(MailAddress a) {
    final s = a.display.trim();
    return s.isEmpty ? '?' : s[0].toUpperCase();
  }
}
