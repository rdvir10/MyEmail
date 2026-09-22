import 'package:flutter/material.dart';

import '../../domain/display_settings.dart';
import '../../domain/mail_attachment.dart';
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
    this.isTicked,
    this.onTicked,
    this.onContextMenu,
  });

  /// A right click, with where it landed, so a menu can open there.
  final void Function(Offset at)? onContextMenu;

  /// Whether this row is ticked, or null when the list is not selecting.
  ///
  /// Null rather than a separate flag: the checkbox and the mode are the same
  /// fact, and two fields for one fact drift apart.
  final bool? isTicked;

  final ValueChanged<bool>? onTicked;

  final ListDensity density;

  bool get isSelecting => isTicked != null;

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
      selected: isSelecting ? isTicked : isSelected,
      child: Material(
        color: isSelected
            ? scheme.secondaryContainer.withValues(alpha: 0.7)
            : Colors.transparent,
        child: InkWell(
          // While selecting, a tap ticks rather than opens. Opening a message
          // mid-selection would take the list off screen and lose the ticks
          // with it, which is not what a tap means once checkboxes are up.
          onTap: isSelecting ? () => onTicked?.call(!isTicked!) : onTap,
          onLongPress: onLongPress,
          onSecondaryTapUp: onContextMenu == null
              ? null
              : (d) => onContextMenu!(d.globalPosition),
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
                if (isSelecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Checkbox(
                      value: isTicked,
                      onChanged: (v) => onTicked?.call(v ?? false),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
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
                          // One line, not two. The name reads first and the
                          // address follows it quietly; a line of its own
                          // doubled the height of every row to say something
                          // most rows did not need to say at all.
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: message.from.display),
                                  if (senderAddress case final address?)
                                    TextSpan(
                                      text: '   $address',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                ],
                              ),
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

  /// The sender's address, where it is worth a line of its own.
  ///
  /// Only when there is a name to sit above it. A row whose sender is just
  /// an address would otherwise print it twice, and a compact list has no
  /// room to spend on that.
  String? get senderAddress {
    if (density == ListDensity.compact) return null;
    final name = message.from.name?.trim() ?? '';
    final email = message.from.email.trim();
    if (name.isEmpty || email.isEmpty) return null;
    if (name.toLowerCase() == email.toLowerCase()) return null;
    return email;
  }

  /// Attachment and flag, in that order, at the end of the last line.
  ///
  /// The attachment mark carries a size where the server gave one. It is
  /// free over IMAP, which reports a size per part with the structure the
  /// header fetch already asks for; Microsoft sends none with a list row,
  /// so there the paperclip stands on its own rather than lying about it.
  List<Widget> _marks(ThemeData theme, ColorScheme scheme) => [
        // An invitation goes first: it is the one mark that changes what the
        // row is rather than describing what is on it.
        if (message.isMeeting) ...[
          const SizedBox(width: 6),
          Icon(Icons.event, size: 14, color: scheme.primary),
        ],
        if (message.hasAttachments) ...[
          const SizedBox(width: 6),
          Icon(Icons.attach_file, size: 14, color: scheme.onSurfaceVariant),
          if (message.attachmentBytes > 0) ...[
            const SizedBox(width: 2),
            Text(
              formatFileSize(message.attachmentBytes),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
        if (message.isFlagged) ...[
          const SizedBox(width: 6),
          Icon(Icons.flag, size: 14, color: scheme.error),
        ],
      ];
}
