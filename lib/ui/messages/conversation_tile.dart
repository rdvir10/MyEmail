import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/display_settings.dart';
import '../../domain/mail_attachment.dart' show formatMessageSize;
import '../../domain/mail_message.dart';
import '../../domain/row_format.dart';
import '../../state/conversations.dart';
import 'date_format.dart';
import 'list_columns.dart';
import 'message_tile.dart';
import 'row_attachments.dart';

/// The collapsed row for a conversation of more than one message.
///
/// Shaped like [MessageTile] on purpose, so a list with conversations on does
/// not look like a different app: the same lines, the same bold first line
/// while anything in it is unread, the same yellow while anything in it is
/// flagged, and the replied or
/// forwarded mark of the message the row is headed by (a thread you had
/// answered showed no arrow until it was opened). Two differences, each
/// earning its place: the count says how many messages are inside, and an
/// arrow at the row's start says it opens, as the group bars' does.
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
    this.ownAddresses = const {},
    this.showRecipients = false,
    this.format,
    this.pinned = false,
    this.showAttachments = false,
  });

  /// The thread's files under it, newest first, as on a message row: see
  /// [MessageTile.showAttachments].
  final bool showAttachments;

  /// Who the newest message went to, in place of who it is from: Sent and
  /// Drafts, where everyone writing is you.
  final bool showRecipients;

  /// The conditional format the message heading the row matches, if any.
  final RowFormat? format;

  /// A message in the thread is pinned to the top of its folder.
  final bool pinned;

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

  /// A hold, with where the finger is, so a menu can open under it.
  final void Function(Offset at)? onLongPress;
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
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => _buildFor(context, box.maxWidth),
      );

  Widget _buildFor(BuildContext context, double width) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = conversation.hasUnread;
    final weight =
        unread || (format?.bold ?? false) ? FontWeight.w700 : FontWeight.w400;
    final colour = format?.colour.on(theme.brightness);
    final first =
        listLineStyle(theme)?.copyWith(fontWeight: weight, color: colour);
    final rest = listLineStyle(theme)?.copyWith(color: colour);
    final previews = density.previewLines > 0;
    final lead = leadMessage;

    final dateText = formatMessageDate(
      conversation.newest.date,
      use24h: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final dateStyle = theme.textTheme.labelSmall?.copyWith(
      color: unread ? scheme.primary : scheme.onSurfaceVariant,
      fontWeight: weight,
    );
    final date = Text(dateText, style: dateStyle);
    // The mark of the message the row is headed by, so the arrow and the
    // name beside it are about the same mail.
    final marks = [
      if (pinned) pinMark(scheme),
      ...actionMarks(lead, scheme),
    ];
    final columns = ColumnLayout.maybeOf(context);
    // The group bars' arrow, where theirs is: at the start, pointing right
    // while the thread is closed and down while it is open. It had been a
    // chevron at the end of the subject; Ron asked for it on the left,
    // like the bars'.
    final arrow = Padding(
      key: const ValueKey('thread-arrow'),
      padding: const EdgeInsets.only(right: 4),
      child: AnimatedRotation(
        turns: isExpanded ? 0 : -0.25,
        duration: const Duration(milliseconds: 150),
        child: Icon(
          Icons.expand_more,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    double fixed() => rowEdges +
        threadArrowWidth +
        marks.length * markWidth +
        12 +
        textWidth(context, '${conversation.everything.length}', theme.textTheme.labelSmall) +
        12 +
        6 +
        8 +
        textWidth(context, dateText, dateStyle) +
        (previews ? 6 : (conversation.hasAttachments ? 20 : 0) + 6);
    final oneLine =
        columns == null && rowsOnOneLine(context, width: width, fixed: fixed());
    final singleLine = (columns != null || oneLine) && !previews;
    // Your replies from Sent are counted: they are in the thread when it
    // opens, as Outlook counts them.
    Widget badge({required bool bold}) => _CountBadge(
          count: conversation.everything.length,
          unread: conversation.unreadCount,
          theme: theme,
          bold: bold,
        );
    final ends = <Widget>[
      if (conversation.hasAttachments) ...[
        const SizedBox(width: 6),
        Icon(Icons.attach_file, size: 14, color: scheme.onSurfaceVariant),
      ],
      const SizedBox(width: 6),
    ];
    final preview = Text(
      conversation.newest.preview,
      maxLines: density.previewLines,
      overflow: TextOverflow.ellipsis,
      style: listPreviewStyle(theme),
    );

    final List<Widget> lines;
    if (columns != null) {
      // Under the list's headers, as a message row has them (see
      // MessageTile): the arrow starts the From column, the count rides
      // with the subject, and the size is the whole thread's, as the count
      // is.
      final from = math.max(24.0, columns.from - (columns.width - width));
      final bytes = conversation.everything
          .fold<int>(0, (total, m) => total + m.sizeBytes);
      lines = [
        Row(
          children: [
            if (columns.files > 0)
              SizedBox(
                width: columns.files,
                child: conversation.hasAttachments
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(
                          Icons.attach_file,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                          semanticLabel: 'Attachment',
                        ),
                      )
                    : null,
              ),
            SizedBox(
              width: from,
              child: Row(
                children: [
                  arrow,
                  if (from >= threadArrowWidth + marks.length * markWidth + 40)
                    ...marks,
                  Expanded(
                    child: Text(
                      showRecipients
                          ? recipientsLine(lead, short: true)
                          : leadSender.display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: first,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: ColumnLayout.gap),
            badge(bold: unread),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                conversation.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: first,
              ),
            ),
            if (columns.received > 0) ...[
              const SizedBox(width: ColumnLayout.gap),
              SizedBox(
                width: columns.received,
                child: Text(
                  formatMessageDateColumn(
                    conversation.newest.date,
                    use24h: MediaQuery.alwaysUse24HourFormatOf(context),
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: dateStyle,
                ),
              ),
            ],
            if (columns.size > 0) ...[
              const SizedBox(width: ColumnLayout.gap),
              SizedBox(
                width: columns.size,
                child: Text(
                  bytes > 0 ? formatMessageSize(bytes) : '',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: dateStyle,
                ),
              ),
            ],
            const SizedBox(width: 6),
          ],
        ),
        if (previews) ...[
          SizedBox(height: density.lineGap),
          Padding(
            padding: EdgeInsets.only(left: columns.files, right: 6),
            child: preview,
          ),
        ],
      ];
    } else if (oneLine) {
      lines = [
        Row(
          children: [
            arrow,
            ...marks,
            Expanded(
              flex: 2,
              child: Text(
                showRecipients
                    ? recipientsLine(lead, short: true)
                    : leadSender.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: first,
              ),
            ),
            const SizedBox(width: 12),
            badge(bold: unread),
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: Text(
                conversation.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: first,
              ),
            ),
            const SizedBox(width: 8),
            date,
            if (previews) const SizedBox(width: 6) else ...ends,
          ],
        ),
        if (previews) ...[
          SizedBox(height: density.lineGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Expanded(child: preview), ...ends],
          ),
        ],
      ];
    } else {
      lines = [
        Row(
          children: [
            arrow,
            ...marks,
            Expanded(
              child: Text(
                showRecipients ? recipientsLine(lead) : senderLine(leadSender),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: first,
              ),
            ),
            const SizedBox(width: 8),
            date,
            const SizedBox(width: 6),
          ],
        ),
        SizedBox(height: density.lineGap),
        Row(
          children: [
            // Not bold on the second line: only the first line is.
            badge(bold: false),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                conversation.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rest,
              ),
            ),
            ...ends,
          ],
        ),
        if (previews) ...[
          SizedBox(height: density.lineGap),
          preview,
        ],
      ];
    }
    final files = showAttachments && previews
        ? rowFilesOfAll(conversation.messages)
        : const <RowFile>[];
    if (files.isNotEmpty) {
      lines.addAll([
        SizedBox(height: density.lineGap + 3),
        Padding(
          padding: EdgeInsets.only(left: columns?.files ?? 0, right: 6),
          child: RowAttachments(files: files),
        ),
      ]);
    }

    return Semantics(
      expanded: isExpanded,
      selected: isSelected,
      label: '${conversation.everything.length} messages'
          '${conversation.isFlagged ? ', flagged' : ''}',
      child: Material(
        color: rowGround(
          scheme,
          selected: isSelected,
          flagged: conversation.isFlagged,
        ),
        // The hold from outside the ink, as on a message row.
        child: GestureDetector(
          onLongPressStart: onLongPress == null
              ? null
              : (d) {
                  Feedback.forLongPress(context);
                  onLongPress!(d.globalPosition);
                },
          child: InkWell(
            onTap: onTap,
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
                      child: RowCheckbox(
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
                        singleLine: singleLine,
                      ),
                    ),
                  RowGutter(
                    unread: unread,
                    accountColor: accountColor,
                    singleLine: singleLine,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: singleLine ? RowCheckbox.singleLineSize : 0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: lines,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The message that heads the row: the newest one not from you, or the
  /// newest where everyone in it is you.
  MailMessage get leadMessage => leadOf(conversation, ownAddresses);

  /// Who heads the row: see [leadMessage].
  MailAddress get leadSender => leadMessage.from;
}

/// The arrow at the start of a thread's row, with the space after it.
const double threadArrowWidth = 16 + 4;

/// The message that heads [conversation]'s row: the newest one not from
/// [ownAddresses], or the newest where everyone in it is you. The list
/// matches a conditional format against it, as the row shows it.
MailMessage leadOf(Conversation conversation, Set<String> ownAddresses) {
  final newestFirst = [...conversation.messages]
    ..sort((a, b) => b.date.compareTo(a.date));
  for (final m in newestFirst) {
    if (!ownAddresses.contains(m.from.email.trim().toLowerCase())) {
      return m;
    }
  }
  return conversation.newest;
}

/// How many messages, and how many of them are unread.
class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.unread,
    required this.theme,
    this.bold = true,
  });

  final int count;
  final int unread;
  final ThemeData theme;

  /// Bold while anything is unread, on a first line only.
  final bool bold;

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
          fontWeight: hasUnread && bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
