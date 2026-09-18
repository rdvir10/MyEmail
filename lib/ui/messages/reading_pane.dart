import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../compose/open_compose.dart';
import 'date_format.dart';
import 'html_body_view.dart';

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
  const ReadingPane({super.key, required this.message, this.onPopOut});

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          child: _Header(
            message: message,
            onPopOut: widget.onPopOut,
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
    );
  }

  Widget _bodyView(ThemeData theme, MailBody b) {
    final html = b.html;
    // The WebView is a platform view: Android has it, the browser preview
    // does not. Text is the universal fallback.
    if (html != null && html.trim().isNotEmpty && !kIsWeb) {
      return HtmlBodyView(html: html);
    }
    return SingleChildScrollView(
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
    required this.onToggleFlag,
    required this.onToggleRead,
    required this.onCompose,
    this.onPopOut,
  });

  final MailMessage message;
  final VoidCallback onToggleFlag;
  final VoidCallback onToggleRead;
  final void Function(ComposeKind kind) onCompose;
  final VoidCallback? onPopOut;

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
        if (message.hasAttachments) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.attach_file, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                'Attachments arrive in milestone 5',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _initial(MailAddress a) {
    final s = a.display.trim();
    return s.isEmpty ? '?' : s[0].toUpperCase();
  }
}
