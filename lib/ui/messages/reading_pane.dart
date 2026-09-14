import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import 'date_format.dart';

/// One open message: headers, actions, then the body.
///
/// Opening an unread message marks it read, as Outlook does; that happens
/// after the first frame so the pane never blocks on the network. The flag
/// and read state shown come from the live list, so a change made here or in
/// the list is reflected immediately in both.
///
/// Renders the plain-text body. The sandboxed WebView for HTML mail is an
/// Android-only step; the seam is [MailBody.html], which this pane ignores
/// for now.
class ReadingPane extends ConsumerStatefulWidget {
  const ReadingPane({super.key, required this.message});

  final MailMessage message;

  @override
  ConsumerState<ReadingPane> createState() => _ReadingPaneState();
}

class _ReadingPaneState extends ConsumerState<ReadingPane> {
  @override
  void initState() {
    super.initState();
    if (!widget.message.isRead) {
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
    final scheme = theme.colorScheme;
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(message.subject, style: theme.textTheme.titleLarge),
            ),
            IconButton(
              tooltip: message.isFlagged ? 'Remove flag' : 'Flag',
              icon: Icon(
                message.isFlagged ? Icons.flag : Icons.flag_outlined,
                color: message.isFlagged ? scheme.error : null,
              ),
              onPressed: () =>
                  _act((n) => n.setFlagged(message.id, !message.isFlagged)),
            ),
            IconButton(
              tooltip: message.isRead ? 'Mark as unread' : 'Mark as read',
              icon: Icon(
                message.isRead
                    ? Icons.mark_email_unread_outlined
                    : Icons.mark_email_read_outlined,
              ),
              onPressed: () =>
                  _act((n) => n.setRead(message.id, !message.isRead)),
            ),
          ],
        ),
        const SizedBox(height: 12),
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
          const SizedBox(height: 12),
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
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        body.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: (e, _) => Text(
            'Could not load the message.\n$e',
            style: theme.textTheme.bodySmall,
          ),
          data: (b) => SelectableText(
            b.text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ),
      ],
    );
  }

  static String _initial(MailAddress a) {
    final s = a.display.trim();
    return s.isEmpty ? '?' : s[0].toUpperCase();
  }
}
