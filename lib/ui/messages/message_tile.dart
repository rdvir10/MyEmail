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
/// Read and unread sit on the same ground, as they do in Outlook. What is
/// unread says so on its first line alone: bold, with a dot and a blue time.
/// A tablet puts the subject on that first line too, beside the sender, so
/// the row reads across like Outlook's (see [rowsOnOneLine]).
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
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => _buildFor(context, box.maxWidth),
      );

  Widget _buildFor(BuildContext context, double width) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = !message.isRead;
    final weight = unread ? FontWeight.w700 : FontWeight.w400;
    // Only the first line is bold when unread; the rest are the same either
    // way.
    final first = listLineStyle(theme)?.copyWith(fontWeight: weight);
    final rest = listLineStyle(theme);

    final dateText = formatMessageDate(
      message.date,
      use24h: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final dateStyle = theme.textTheme.labelSmall?.copyWith(
      color: unread ? scheme.primary : scheme.onSurfaceVariant,
      fontWeight: weight,
    );
    final date = Text(dateText, style: dateStyle);

    // What the first line would hold besides the sender and the subject,
    // were they on it: the row's edges, the marks, the date, and with no
    // preview line the attachment and the size as well.
    final marks = actionMarks(message, scheme);
    final fixed = rowEdges +
        marks.length * markWidth +
        12 +
        8 +
        textWidth(context, dateText, dateStyle) +
        (showsPreview
            ? 6
            : 6 +
                (message.isMeeting ? 20 : 0) +
                (message.hasAttachments ? 20 : 0) +
                (message.sizeBytes > 0
                    ? 6 +
                        textWidth(
                          context,
                          formatMessageSize(message.sizeBytes),
                          theme.textTheme.labelSmall,
                        )
                    : 0));
    final oneLine = rowsOnOneLine(context, width: width, fixed: fixed);
    final singleLine = oneLine && !showsPreview;
    final chipWidth = width * 0.35;
    const end = SizedBox(width: 6);

    final List<Widget> lines;
    if (oneLine) {
      lines = [
        Row(
          children: [
            ...marks,
            // Name only: beside the subject there is no room for the address
            // as well, and Outlook's own list names the sender the same way.
            Expanded(
              flex: 2,
              child: Text(
                message.from.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: first,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Text(
                message.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: first,
              ),
            ),
            if (!showsPreview) ..._marks(theme, scheme),
            const SizedBox(width: 8),
            date,
            end,
          ],
        ),
        if (showsPreview) ...[
          SizedBox(height: density.lineGap),
          _previewLine(theme, scheme, trailing: end, chipWidth: chipWidth),
        ],
      ];
    } else {
      lines = [
        Row(
          children: [
            // What has been done with it, before who it is from: a mail
            // already answered is the first thing worth knowing about it
            // when scanning.
            ...marks,
            // Name and address together, at the name's size, in every
            // density. Small and grey after the name, the address was the
            // first thing cut off, and Compact left it out altogether.
            Expanded(
              child: Text(
                senderLine(message.from),
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
            Expanded(
              child: Text(
                message.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rest,
              ),
            ),
            // With no preview line there is nowhere else for these to go,
            // and a hidden attachment mark is worse than a slightly busier
            // subject line.
            if (showsPreview == false) ..._marks(theme, scheme),
            end,
          ],
        ),
        if (showsPreview) ...[
          SizedBox(height: density.lineGap),
          _previewLine(
            theme,
            scheme,
            trailing: const SizedBox(width: 6),
            chipWidth: chipWidth,
          ),
        ],
      ];
    }

    return Semantics(
      selected: isSelecting ? isTicked : isSelected,
      label: message.isFlagged ? 'Flagged' : null,
      child: Material(
        color: rowGround(
          scheme,
          selected: isSelected,
          flagged: message.isFlagged,
        ),
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
                    child: RowCheckbox(
                      value: isTicked,
                      onChanged: (v) => onTicked?.call(v ?? false),
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
                    // One line tall, whether or not the checkbox is up, so
                    // starting a selection does not make every row jump.
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
    );
  }

  /// The preview, after the folder a search hit is in, with the marks and
  /// [trailing] at the end.
  Widget _previewLine(
    ThemeData theme,
    ColorScheme scheme, {
    required Widget trailing,
    required double chipWidth,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (folderLabel != null) ...[
            // At most a third of the line: a long folder name took all of
            // it, and the preview, marks and flag went off the edge.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: chipWidth),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  folderLabel!,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
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
          trailing,
        ],
      );

  bool get showsPreview => density.previewLines > 0;

  /// Invitation, attachment and size, in that order, at the end of the last
  /// line.
  ///
  /// The size is every message's, as Outlook shows it for Gmail and
  /// Microsoft alike: the whole message, files and all, where the server
  /// has said (see [MailMessage.sizeBytes]).
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
        ],
        if (message.sizeBytes > 0) ...[
          SizedBox(width: message.hasAttachments ? 2 : 6),
          Text(
            formatMessageSize(message.sizeBytes),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ];
}

/// Whether a row [width] wide puts the subject on its first line, beside
/// the sender, when everything else on that line takes [fixed].
///
/// On a tablet, where Ron asked for it. The device decides, not the width
/// alone: beside the reading pane a tablet's list is barely wider than a
/// phone. But only where the sender and subject keep [minTextRoom] between
/// them; with the list at its narrowest, the text large or Compact putting
/// every mark on that line, both came down to "…" and then the row
/// overflowed, so there the row keeps two lines.
bool rowsOnOneLine(
  BuildContext context, {
  required double width,
  required double fixed,
}) =>
    MediaQuery.sizeOf(context).shortestSide >= 600 &&
    width - fixed >= minTextRoom;

/// The least room for the sender and subject together on one line.
const double minTextRoom = 150;

/// A row's edges: its padding, the unread gutter, and the gap after it.
/// The selection checkbox is left out on purpose, so ticking a row never
/// changes how it is laid out.
const double rowEdges = 8 + 6 + 14 + 6;

/// A replied or forwarded mark, with its gap.
const double markWidth = 19;

/// What a row sits on: the selection's colour when it is the open one,
/// a pale yellow when it is flagged, as Outlook marks a flagged message
/// (the flag icon at the end of every row is gone: Ron asked for the
/// line to say it instead), and the list's own ground otherwise.
Color rowGround(
  ColorScheme scheme, {
  required bool selected,
  required bool flagged,
}) {
  if (selected) return scheme.secondaryContainer.withValues(alpha: 0.7);
  if (flagged) return flaggedRowColour(scheme);
  return Colors.transparent;
}

/// Outlook's flagged yellow, and a dim amber in the dark.
Color flaggedRowColour(ColorScheme scheme) =>
    scheme.brightness == Brightness.dark
        ? const Color(0xFF3A3322)
        : const Color(0xFFFFF4CE);

/// How wide [text] is drawn in [style], at the reader's text size.
double textWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// The selection checkbox, held to one line's height in a row of one line:
/// at its usual size it made every Compact row nearly twice as tall the
/// moment a selection began.
class RowCheckbox extends StatelessWidget {
  const RowCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.singleLine = false,
    this.tristate = false,
  });

  final bool? value;
  final ValueChanged<bool?> onChanged;
  final bool singleLine;
  final bool tristate;

  /// The height of a row of one line.
  static const double singleLineSize = 24;

  @override
  Widget build(BuildContext context) {
    final box = Checkbox(
      value: value,
      tristate: tristate,
      onChanged: onChanged,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize:
          singleLine ? MaterialTapTargetSize.shrinkWrap : null,
    );
    return singleLine
        ? SizedBox(height: singleLineSize, child: box)
        : box;
  }
}

/// Replied and forwarded, as marks before the sender.
List<Widget> actionMarks(MailMessage message, ColorScheme scheme) => [
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
    ];

/// The strip down a row's left edge: the unread dot, and in the unified
/// Inbox and search the bar in the account's colour.
///
/// In a row of one line the bar stands beside the dot rather than under it:
/// stacked, it made those rows twice the height of the line.
class RowGutter extends StatelessWidget {
  const RowGutter({
    super.key,
    required this.unread,
    this.accountColor,
    this.singleLine = false,
  });

  final bool unread;
  final Color? accountColor;
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: unread ? scheme.primary : Colors.transparent,
        shape: BoxShape.circle,
      ),
    );
    Widget bar(double height) => Container(
          width: 3,
          height: height,
          decoration: BoxDecoration(
            color: accountColor,
            borderRadius: BorderRadius.circular(2),
          ),
        );
    if (singleLine) {
      return SizedBox(
        width: 14,
        child: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: dot),
              const SizedBox(width: 3),
              if (accountColor != null) bar(12),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: 14,
      child: Column(
        children: [
          const SizedBox(height: 5),
          dot,
          if (accountColor != null) ...[
            const SizedBox(height: 6),
            bar(22),
          ],
        ],
      ),
    );
  }
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

/// The sender and subject lines of a list row: the body size, set tight.
/// Material's line height is meant for paragraphs, and between one-line
/// rows it was a third of every row's height spent on nothing.
TextStyle? listLineStyle(ThemeData theme) =>
    theme.textTheme.bodyMedium?.copyWith(height: 1.25);

/// A row's preview line, a size down and quieter.
TextStyle? listPreviewStyle(ThemeData theme) => theme.textTheme.bodySmall
    ?.copyWith(height: 1.25, color: theme.colorScheme.onSurfaceVariant);
