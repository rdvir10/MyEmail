import 'package:flutter/material.dart';

import '../../domain/display_settings.dart';
import '../../domain/mail_message.dart';
import 'date_format.dart';

/// One row of the message list: sender, subject, preview, date, and the
/// unread / flagged / attachment marks. Compact, like Outlook mobile.
///
/// [density] decides how many lines the row gets. The marks always ride on
/// the last visible line rather than living on the preview line, or setting
/// the list to Compact would hide the fact that a message has an attachment.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isSelected,
    required this.onTap,
    this.accountColor,
    this.onLongPress,
    this.folderLabel,
    this.density = ListDensity.cozy,
  });

  final ListDensity density;

  /// Shown as a chip in search results, where hits come from many folders.
  final String? folderLabel;

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
            padding: EdgeInsets.fromLTRB(
              8,
              density.verticalPadding,
              12,
              density.verticalPadding,
            ),
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              message.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: weight,
                              ),
                            ),
                          ),
                          // With no preview line there is nowhere else for
                          // these to go, and a hidden attachment mark is worse
                          // than a slightly busier subject line.
                          if (showsPreview == false) ..._marks(theme, scheme),
                        ],
                      ),
                      if (showsPreview) ...[
                        const SizedBox(height: 2),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (folderLabel != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  folderLabel!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                message.preview,
                                maxLines: density.previewLines,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            ..._marks(theme, scheme),
                          ],
                        ),
                      ],
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

  bool get showsPreview => density.previewLines > 0;

  /// Attachment and flag, in that order, at the end of the last line.
  List<Widget> _marks(ThemeData theme, ColorScheme scheme) => [
        if (message.hasAttachments) ...[
          const SizedBox(width: 6),
          Icon(Icons.attach_file, size: 14, color: scheme.onSurfaceVariant),
        ],
        if (message.isFlagged) ...[
          const SizedBox(width: 6),
          Icon(Icons.flag, size: 14, color: scheme.error),
        ],
      ];
}
