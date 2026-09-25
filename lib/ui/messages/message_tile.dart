import 'package:flutter/material.dart';

import '../../domain/display_settings.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import 'date_format.dart';

/// One row of the message list: sender, subject, preview, date, and the
/// unread / flagged / attachment marks.
///
/// [density] decides how many lines the row gets. The marks always ride on
/// the last visible line rather than living on the preview line, or setting
/// the list to Compact would hide the fact that a message has an attachment.
///
/// Read and unread differ by more than weight: an unread row sits on the
/// list's own ground and a read one on a shade of it, so what is new can be
/// picked out from across a screen, the way it can in Outlook.
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
    this.onToggleFlag,
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

  /// Flag it, or take the flag off, from the row itself. Where the row has
  /// nothing to do it with, a flag that is set is still shown.
  final VoidCallback? onToggleFlag;

  /// Shown as a thin bar on the left in the unified Inbox, so the reader can
  /// tell at a glance which account a message came through.
  final Color? accountColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = !message.isRead;
    final weight = unread ? FontWeight.w700 : FontWeight.w400;
    final line = listLineStyle(theme)?.copyWith(fontWeight: weight);

    return Semantics(
      selected: isSelecting ? isTicked : isSelected,
      child: Material(
        color: isSelected
            ? scheme.secondaryContainer.withValues(alpha: 0.7)
            : unread
                ? Colors.transparent
                : readRowColour(scheme),
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
              6,
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
                          // What has been done with it, before who it is
                          // from: a mail already answered is the first
                          // thing worth knowing about it when scanning.
                          if (message.isAnswered)
                            _Mark(
                              icon: Icons.reply,
                              label: 'Replied',
                              colour: scheme.onSurfaceVariant,
                            ),
                          if (message.isForwarded)
                            _Mark(
                              icon: Icons.forward,
                              label: 'Forwarded',
                              colour: scheme.onSurfaceVariant,
                            ),
                          // Name and address together, at the name's size,
                          // in every density. Small and grey after the name,
                          // the address was the first thing cut off, and
                          // Compact left it out altogether.
                          Expanded(
                            child: Text(
                              senderLine(message.from),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: line,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatMessageDate(
                              message.date,
                              use24h: MediaQuery.alwaysUse24HourFormatOf(
                                context,
                              ),
                            ),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: unread
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: weight,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ),
                      SizedBox(height: density.lineGap),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              message.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: line,
                            ),
                          ),
                          // With no preview line there is nowhere else for
                          // these to go, and a hidden attachment mark is worse
                          // than a slightly busier subject line.
                          if (showsPreview == false) ..._marks(theme, scheme),
                          RowFlag(
                            flagged: message.isFlagged,
                            onToggle: onToggleFlag,
                          ),
                        ],
                      ),
                      if (showsPreview) ...[
                        SizedBox(height: density.lineGap),
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
                                style: listPreviewStyle(theme),
                              ),
                            ),
                            ..._marks(theme, scheme),
                            const SizedBox(width: 6),
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

  /// Invitation and attachment, in that order, at the end of the last line.
  /// The flag has a place of its own at the end of the subject's line.
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
      ];
}

/// A small mark before the sender: replied, or forwarded.
class _Mark extends StatelessWidget {
  const _Mark({required this.icon, required this.label, required this.colour});

  final IconData icon;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: label,
          child: Icon(icon, size: 15, color: colour, semanticLabel: label),
        ),
      );
}

/// `Crystal R <crystalr@hadco-metal.com>`, or the address alone where there
/// is no name, or where the name is only the address again.
String senderLine(MailAddress from) {
  final name = from.name?.trim() ?? '';
  final email = from.email.trim();
  if (name.isEmpty || email.isEmpty) return from.display;
  if (name.toLowerCase() == email.toLowerCase()) return email;
  return '$name <$email>';
}

/// The shade a read row sits on; an unread one sits on the list itself.
Color readRowColour(ColorScheme scheme) => scheme.surfaceContainerHigh;

/// The sender and subject lines of a list row: the body size, set tight.
/// Material's line height is meant for paragraphs, and between one-line
/// rows it was a third of every row's height spent on nothing.
TextStyle? listLineStyle(ThemeData theme) =>
    theme.textTheme.bodyMedium?.copyWith(height: 1.25);

/// A row's preview line, a size down and quieter.
TextStyle? listPreviewStyle(ThemeData theme) => theme.textTheme.bodySmall
    ?.copyWith(height: 1.25, color: theme.colorScheme.onSurfaceVariant);

/// The flag at the end of a row's subject line: a tap sets it or takes it
/// off, without opening the message or reaching for a swipe.
///
/// An outline where there is no flag, so the place to tap is always there;
/// the red flag where there is one. Where there is nothing to toggle it
/// with, only a flag that is set is drawn.
class RowFlag extends StatelessWidget {
  const RowFlag({super.key, required this.flagged, required this.onToggle});

  final bool flagged;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = Icon(
      flagged ? Icons.flag : Icons.flag_outlined,
      size: 18,
      color: flagged
          ? scheme.error
          : scheme.onSurfaceVariant.withValues(alpha: 0.55),
    );
    if (onToggle == null) {
      return flagged
          ? Padding(padding: const EdgeInsets.only(left: 6), child: icon)
          : const SizedBox(width: 6);
    }
    return Semantics(
      button: true,
      label: flagged ? 'Remove flag' : 'Flag',
      excludeSemantics: true,
      child: Tooltip(
        message: flagged ? 'Remove flag' : 'Flag',
        child: InkResponse(
          onTap: onToggle,
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: icon,
          ),
        ),
      ),
    );
  }
}
