import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../domain/calendar_invite.dart';
import '../../state/trusted_senders.dart';
import '../../domain/trusted_senders.dart';
import '../../state/calendar_providers.dart';
import 'invite_card.dart';
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
import '../../data/print/message_printer.dart';
import '../../state/print_providers.dart';
import 'full_screen_message.dart';
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

  Future<void> _openWindow(MailMessage message) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await ref.read(windowOpenerProvider).open(MessageWindow(message))) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open a window.')),
      );
    }
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
                ? () => _openWindow(message)
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
            onPrint: body.value == null ||
                    !(ref.watch(printingAvailableProvider).value ?? false)
                ? null
                : () => _print(message, body.value!),
            onFullScreen: body.value == null
                ? null
                : () => FullScreenMessage.open(context, message),
            onCreateEvent: body.value == null ||
                    !(ref.watch(calendarAvailableProvider).value ?? false)
                ? null
                : () => _createEvent(message, body.value!),
          ),
        ),
        // The invitation, when the message carries one, before the body:
        // the answer is the point of the message.
        if (body.value?.calendar case final ics?)
          if (CalendarInvite.parse(ics) case final invite?)
            InviteCard(message: message, invite: invite),
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

  /// An event from the message: its subject as the title, its text as
  /// the notes, in the calendar app's own new-event screen where the
  /// time is picked. For the mail that says "let's meet Thursday" without
  /// sending an invitation.
  Future<void> _createEvent(MailMessage message, MailBody body) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final notes = body.text.trim();
    final ok = await ref.read(deviceCalendarProvider).insertEvent(
          title: message.subject,
          description:
              '${notes.length > 2000 ? '${notes.substring(0, 2000)}…' : notes}'
              '\n\nFrom: ${message.from.display}',
        );
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('No calendar app to add it to.')),
      );
    }
  }

  /// The system's print sheet, which is also where "Save as PDF" lives.
  /// Pictures from the web are left out unless the setting shows them,
  /// the same rule the pane itself follows: printing a message must not
  /// tell its sender it was read.
  Future<void> _print(MailMessage message, MailBody body) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final html = body.html ?? '';
    // What is on screen is what prints: a trusted sender's pictures are
    // already loaded, and the rest stay out of the paper too.
    final shown = _showsImages ? html : stripRemoteContent(html);
    try {
      final ok = await ref.read(messagePrinterProvider).print(
            title: message.subject.trim().isEmpty ? 'Message' : message.subject,
            html: printableMessage(message, body, bodyHtml: shown),
          );
      if (!ok) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Printing is not available here.')),
        );
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not print. $e')));
    }
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

  /// Whether this message's pictures load without being asked about: the
  /// setting for every message, or this sender being trusted.
  bool get _showsImages =>
      ref.watch(displayProvider).alwaysShowImages ||
      isSenderTrusted(
        ref.watch(trustedSendersProvider),
        widget.message.from.email,
      );

  Widget _bodyView(ThemeData theme, MailBody b) {
    final html = b.html;
    // The WebView is a platform view: Android has it, the browser preview
    // does not. Text is the universal fallback.
    if (html != null && html.trim().isNotEmpty && !kIsWeb) {
      return HtmlBodyView(
        key: _html,
        html: html,
        showImages: _showsImages,
        senderEmail: widget.message.from.email,
        onTrust: (entry) {
          ref.read(trustedSendersProvider.notifier).trust(entry);
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text('Pictures will load from ${describeTrustEntry(entry).toLowerCase()}'),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () =>
                    ref.read(trustedSendersProvider.notifier).forget(entry),
              ),
            ));
        },
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
    this.onPrint,
    this.onCreateEvent,
    this.onFullScreen,
    this.compact = false,
  });

  /// The body alone, edge to edge, with the system bars out of the way.
  /// Null until the body is here: there would be nothing to fill it with.
  final VoidCallback? onFullScreen;

  /// Make a calendar event out of this message. Null until the body is
  /// here, and where there is no calendar app.
  final VoidCallback? onCreateEvent;

  /// Print, or save as a PDF. Null until the body is here, and where there
  /// is no print sheet.
  final VoidCallback? onPrint;

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
        // On its own line, above the buttons. Sharing a row with seven of
        // them left the subject a column three words wide, wrapped and cut
        // — and on a screen of its own the title bar is already saying it,
        // so there it is not said twice.
        if (onPopOut != null) ...[
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: Text(
              message.subject,
              style: theme.textTheme.titleLarge,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        // Seven buttons on a narrow phone are wider than the phone; they
        // slide rather than being clipped at the delete.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // First, not last. These two change where you are rather than
            // what the message is, and grouping them with the three compose
            // actions would invite mis-taps.
            if (onPopOut != null)
              IconButton(
                tooltip: 'Open on its own screen',
                icon: const Icon(Icons.open_in_full),
                onPressed: onPopOut,
              ),
            IconButton(
              tooltip: 'Full screen (F11)',
              icon: const Icon(Icons.fullscreen),
              onPressed: onFullScreen,
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
                'print' => onPrint?.call(),
                'event' => onCreateEvent?.call(),
                _ => onSaveSource?.call(),
              },
              itemBuilder: (context) => [
                if (onOpenWindow != null)
                  const PopupMenuItem(
                    value: 'window',
                    child: Text('Open in new window'),
                  ),
                PopupMenuItem(
                  value: 'print',
                  enabled: onPrint != null,
                  child: const Text('Print or save as PDF…'),
                ),
                PopupMenuItem(
                  value: 'event',
                  enabled: onCreateEvent != null,
                  child: const Text('Create calendar event…'),
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
                  _Recipients(to: message.to),
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

/// Who else got it.
///
/// A mail at work goes to nine people, and nine names cut off mid-word
/// tell you nothing except that the list is long. Two names and a count
/// say the same thing in one line, and a tap opens the rest — with their
/// addresses, since "Ron Dvir" is the part you already knew.
class _Recipients extends StatefulWidget {
  const _Recipients({required this.to});

  final List<MailAddress> to;

  /// How many fit before it is worth folding them away.
  static const shown = 2;

  @override
  State<_Recipients> createState() => _RecipientsState();
}

class _RecipientsState extends State<_Recipients> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final to = widget.to;
    if (to.isEmpty) {
      return Text('To: (nobody named)', style: style);
    }

    final hidden = to.length - _Recipients.shown;
    if (hidden <= 0) {
      return Text(
        'To: ${to.map((a) => a.display).join(', ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    if (!_open) {
      final first = to.take(_Recipients.shown).map((a) => a.display).join(', ');
      return InkWell(
        onTap: () => setState(() => _open = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'To: $first  '),
                TextSpan(
                  text: '+$hidden more',
                  style: style?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => setState(() => _open = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To: ${to.length} people', style: style),
            const SizedBox(height: 2),
            for (final a in to)
              Text(
                a.name == null || a.name!.trim().isEmpty
                    ? a.email
                    : '${a.name}  <${a.email}>',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            Text('Show fewer',
                style: style?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      ),
    );
  }
}
