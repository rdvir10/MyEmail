import 'package:flutter/material.dart';

import '../../domain/mail_message.dart';
import 'date_format.dart';

/// One row of the message list: sender, subject, preview, date, and the
/// unread / flagged / attachment marks. Compact, three lines, like Outlook
/// mobile.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isSelected,
    required this.onTap,
    this.accountColor,
    this.onLongPress,
  });

  final MailMessage message;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Shown as a thin bar on the left in the unified Inbox, so the reader can
  /// tell at a glance which account a message came through.
  final Color? accountColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = !message.isRead;
    final weight = unread ? FontWeight.w700 : FontWeight.w400;

    return Semantics(
      selected: isSelected,
      child: Material(
        color: isSelected
            ? scheme.secondaryContainer.withValues(alpha: 0.7)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 14,
                  child: Column(
                    children: [
                      const SizedBox(height: 5),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: unread ? scheme.primary : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (accountColor != null) ...[
                        const SizedBox(height: 6),
                        Container(
                          width: 3,
                          height: 22,
                          decoration: BoxDecoration(
                            color: accountColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              message.from.display,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: weight,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatMessageDate(message.date),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: unread
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: weight,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: weight,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              message.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (message.hasAttachments) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.attach_file,
                              size: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                          if (message.isFlagged) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.flag,
                              size: 14,
                              color: scheme.error,
                            ),
                          ],
                        ],
                      ),
                    ],
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
