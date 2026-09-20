import 'package:flutter/material.dart';

import '../../domain/display_settings.dart';
import '../../state/conversations.dart';
import 'date_format.dart';

/// The collapsed row for a conversation of more than one message.
///
/// Shaped like [MessageTile] on purpose, so a list with conversations on does
/// not look like a different app. Three differences, each earning its place:
/// the senders are everyone who has written rather than one name, the count
/// says how many messages are inside, and a chevron says it opens.
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
  });

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

    return Semantics(
      expanded: isExpanded,
      selected: isSelected,
      label: '${conversation.length} messages',
      child: Material(
        color: isSelected
            ? scheme.secondaryContainer.withValues(alpha: 0.7)
            : Colors.transparent,
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
                              _participants,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: weight),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatMessageDate(conversation.newest.date),
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
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: weight),
                            ),
                          ),
                          if (conversation.hasAttachments) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.attach_file,
                                size: 14, color: scheme.onSurfaceVariant),
                          ],
                          if (conversation.isFlagged) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.flag, size: 14, color: scheme.error),
                          ],
                          Icon(
                            isExpanded ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      if (density.previewLines > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          conversation.newest.preview,
                          maxLines: density.previewLines,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
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

  /// Names where there are names, addresses otherwise, and a tail count once
  /// there are more than three. A row of eight addresses is unreadable and
  /// tells you less than "Dana, Sam, Ron +5".
  String get _participants {
    final people = conversation.participants;
    String name(int i) {
      final p = people[i];
      final display = p.name?.trim();
      if (display == null || display.isEmpty) return p.email;
      // First name only once there are several: full names do not fit.
      return people.length > 2 ? display.split(' ').first : display;
    }

    if (people.length <= 3) {
      return [for (var i = 0; i < people.length; i++) name(i)].join(', ');
    }
    final shown = [for (var i = 0; i < 3; i++) name(i)].join(', ');
    return '$shown +${people.length - 3}';
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
