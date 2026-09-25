import 'package:flutter/material.dart';

import '../../domain/display_settings.dart';
import '../../domain/mail_message.dart';
import '../../state/conversations.dart';
import 'date_format.dart';
import 'message_tile.dart';

/// The collapsed row for a conversation of more than one message.
///
/// Shaped like [MessageTile] on purpose, so a list with conversations on does
/// not look like a different app: the same sender line, shade for a thread
/// with nothing unread, and flag. Two differences, each earning its place:
/// the count says how many messages are inside, and a chevron says it opens.
///
/// The sender is the newest one who is not you, name and address, as it is
/// on a message row. A thread you answered last would otherwise be headed
/// with your own name, which says nothing about whose conversation it is.
///
/// A conversation of one is never drawn with this. It is a plain message row,
/// because a "1" badge next to every ordinary message is noise.
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.isExpanded,
    this.isSelected = false,
    required this.onTap,
    this.onLongPress,
    this.density = ListDensity.cozy,
    this.accountColor,
    this.tickedCount,
    this.onTicked,
    this.onContextMenu,
    this.onToggleFlag,
    this.ownAddresses = const {},
  });

  /// Flag the whole thread, or take the flag off every message in it.
  final VoidCallback? onToggleFlag;

  /// Your own addresses, in lower case, so the row can be headed by the
  /// last person who is not you.
  final Set<String> ownAddresses;

  /// A right click, with where it landed, so a menu can open there.
  final void Function(Offset at)? onContextMenu;

  final Conversation conversation;
  final bool isExpanded;

  /// The open message is inside this closed thread, so this row is where
  /// the selection is and is painted like a selected message.
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ListDensity density;
  final Color? accountColor;

  /// How many of the thread's messages are ticked, or null when the list
  /// is not selecting. The checkbox shows all, none, or a dash for some.
  ///
  /// The checkbox is the only thing that ticks here: a tap on the row
  /// still opens and closes the thread, so one message inside it can be
  /// picked out on its own. A row that both opened and ticked would do
  /// whichever the person did not mean.
  final int? tickedCount;

  /// Called with true to tick every message in the thread, false to untick
  /// them all.
  final ValueChanged<bool>? onTicked;

  bool get isSelecting => tickedCount != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = conversation.hasUnread;
    final weight = unread ? FontWeight.w700 : FontWeight.w400;
    final line = listLineStyle(theme)?.copyWith(fontWeight: weight);

    return Semantics(
      expanded: isExpanded,
      selected: isSelected,
      label: '${conversation.length} messages',
      child: Material(
        color: isSelected
            ? scheme.secondaryContainer.withValues(alpha: 0.7)
            : unread
                ? Colors.transparent
                : readRowColour(scheme),
        child: InkWell(
          onTap: onTap,
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
                      tristate: true,
                      value: tickedCount == conversation.length
                          ? true
                          : tickedCount == 0
                              ? false
                              : null,
                      // Some ticked reads as "not all": the next press
                      // takes the rest, the one after that lets go.
                      onChanged: (_) => onTicked?.call(
                        tickedCount != conversation.length,
                      ),
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
                          Expanded(
                            child: Text(
                              senderLine(leadSender),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: line,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatMessageDate(
                              conversation.newest.date,
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
                          _CountBadge(
                            count: conversation.length,
                            unread: conversation.unreadCount,
                            theme: theme,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              conversation.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: line,
                            ),
                          ),
                          if (conversation.hasAttachments) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.attach_file,
                                size: 14, color: scheme.onSurfaceVariant),
                          ],
                          RowFlag(
                            flagged: conversation.isFlagged,
                            onToggle: onToggleFlag,
                          ),
                          Icon(
                            isExpanded ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      if (density.previewLines > 0) ...[
                        SizedBox(height: density.lineGap),
                        Text(
                          conversation.newest.preview,
                          maxLines: density.previewLines,
                          overflow: TextOverflow.ellipsis,
                          style: listPreviewStyle(theme),
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

  /// Who heads the row: the newest sender who is not you, or the newest
  /// sender where everyone in it is you.
  MailAddress get leadSender {
    final newestFirst = [...conversation.messages]
      ..sort((a, b) => b.date.compareTo(a.date));
    for (final m in newestFirst) {
      if (!ownAddresses.contains(m.from.email.trim().toLowerCase())) {
        return m.from;
      }
    }
    return conversation.newest.from;
  }
}

/// How many messages, and how many of them are unread.
class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.unread,
    required this.theme,
  });

  final int count;
  final int unread;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final hasUnread = unread > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: hasUnread
            ? scheme.primary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        // "2 of 5" would be precise and unreadable at this size. The bold
        // count plus the colour already says there is something unread.
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: hasUnread ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
