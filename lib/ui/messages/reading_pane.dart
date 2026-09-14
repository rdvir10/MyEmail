import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import 'date_format.dart';

/// One open message: headers, then the body.
///
/// Renders the plain-text body. The sandboxed WebView for HTML mail is an
/// Android-only step that comes with the real engine; the seam is
/// [MailBody.html], which this pane ignores for now.
class ReadingPane extends ConsumerWidget {
  const ReadingPane({super.key, required this.message});

  final MailMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = ref.watch(messageBodyProvider(message.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Text(message.subject, style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
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
                  Text(
                    message.from.display,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (message.from.name != null)
                    Text(
                      message.from.email,
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
