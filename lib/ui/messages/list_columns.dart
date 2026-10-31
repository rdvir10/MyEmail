import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/message_sort.dart';
import '../../state/display_providers.dart';
import '../../state/list_columns.dart';
import '../../state/message_providers.dart' show isSelectingProvider;
import 'date_format.dart';
import 'message_tile.dart';

/// Where the list's columns sit, worked out once for the list's width so
/// the headers and every row under them agree.
///
/// Only on a tablet, as rows of one line are (see [rowsOnOneLine]), and
/// only where the list is wide enough to leave the subject [minSubject]
/// beside the rest. Beside the reading pane at its usual width it is not,
/// and there the rows stay as they were, with the sort button over them
/// doing the headers' work: Outlook switches the same way.
@immutable
class ColumnLayout {
  const ColumnLayout({
    required this.width,
    required this.files,
    required this.from,
    required this.received,
    required this.size,
  });

  /// The list's own width.
  final double width;

  /// Each column's width, 0 for one put away. Subject takes what is left.
  final double files;
  final double from;
  final double received;
  final double size;

  /// Between two columns, where a header's edge is.
  static const double gap = 12;

  /// The paperclip's column.
  static const double filesWidth = 22;

  /// What a row has before its first column: its padding, the unread
  /// gutter and the space after it (see [rowEdges]).
  static const double before = 8 + 14 + 6;

  /// What a row has after its last column: its padding and the end space.
  static const double after = 6 + 6;

  /// What the subject has, in a row with no checkbox.
  double get subject =>
      width -
      before -
      after -
      files -
      from -
      gap -
      (received > 0 ? gap + received : 0) -
      (size > 0 ? gap + size : 0);

  /// The columns of the list [context] is in, or null where it has none.
  static ColumnLayout? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ListColumnsScope>()?.layout;

  @override
  bool operator ==(Object other) =>
      other is ColumnLayout &&
      other.width == width &&
      other.files == files &&
      other.from == from &&
      other.received == received &&
      other.size == size;

  @override
  int get hashCode => Object.hash(width, files, from, received, size);

  @override
  String toString() =>
      'ColumnLayout($width: files $files, from $from, '
      'subject $subject, received $received, size $size)';
}

/// The least the subject keeps beside the other columns, at the reader's
/// text size. Less, and the list goes back to rows without columns.
double minSubject(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(140);

/// The columns for a list [width] wide under [settings], or null where the
/// device is a phone or the list too narrow (see [ColumnLayout]).
///
/// A width nobody has dragged is the text's own: Received as wide as a
/// date from another year, bold, at the reader's text size, so that no
/// row's date is cut off until a drag says so.
ColumnLayout? columnLayoutFor(
  BuildContext context,
  double width,
  ColumnSettings settings,
) {
  if (MediaQuery.sizeOf(context).shortestSide < 600) return null;
  final style = columnTextStyle(Theme.of(context))
      ?.copyWith(fontWeight: FontWeight.w700);
  final year = DateTime.now().year - 1;
  final layout = ColumnLayout(
    width: width,
    files: settings.shows(ListColumn.files) ? ColumnLayout.filesWidth : 0,
    from: settings.from ?? MediaQuery.textScalerOf(context).scale(170),
    received: !settings.shows(ListColumn.received)
        ? 0
        : settings.received ??
              textWidth(
                    context,
                    formatMessageDateColumn(
                      DateTime(year, 9, 30, 10, 16),
                      use24h: MediaQuery.alwaysUse24HourFormatOf(context),
                    ),
                    style,
                  ) +
                  4,
    size: !settings.shows(ListColumn.size)
        ? 0
        : settings.size ??
              math.max(40, textWidth(context, '999 KB', style) + 4),
  );
  return layout.subject >= minSubject(context) ? layout : null;
}

/// Received and Size in a row, and their headers' size: the date's style.
TextStyle? columnTextStyle(ThemeData theme) => theme.textTheme.labelSmall;

/// Hands [layout] to the rows under it; null where the list has no columns.
class ListColumnsScope extends InheritedWidget {
  const ListColumnsScope({
    super.key,
    required this.layout,
    required super.child,
  });

  final ColumnLayout? layout;

  @override
  bool updateShouldNotify(ListColumnsScope oldWidget) =>
      oldWidget.layout != layout;
}

/// The list with Outlook's column headers over it where it is wide enough
/// for columns, and the list alone where it is not.
class ListColumnsArea extends ConsumerWidget {
  const ListColumnsArea({
    super.key,
    required this.outgoing,
    required this.child,
  });

  /// Sent or Drafts, whose columns are To and Sent.
  final bool outgoing;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(listColumnsProvider);
    return LayoutBuilder(
      builder: (context, box) {
        final layout = columnLayoutFor(context, box.maxWidth, settings);
        return Column(
          children: [
            if (layout != null) ...[
              ListColumnHeader(layout: layout, outgoing: outgoing),
              const Divider(height: 1),
            ],
            // Keyed, so the list is the same list with headers over it or
            // without: dragging the pane across the line keeps its place.
            Expanded(
              key: const ValueKey('list'),
              child: ListColumnsScope(layout: layout, child: child),
            ),
          ],
        );
      },
    );
  }
}

/// Outlook's column headers. A tap sorts by the column and a second tap
/// turns the order round; a drag on the edge between two makes a column
/// wider, and a double tap there puts it back; a hold or a right click
/// opens the menu of every order and column.
class ListColumnHeader extends ConsumerWidget {
  const ListColumnHeader({
    super.key,
    required this.layout,
    this.outgoing = false,
  });

  final ColumnLayout layout;

  /// Sent or Drafts: To and Sent, as Outlook heads them there.
  final bool outgoing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = ref.watch(displayProvider);
    final columns = ref.read(listColumnsProvider.notifier);
    // The room a row's checkbox takes while the list is selecting, kept
    // here too so the headers stay over their columns.
    final lead = ref.watch(isSelectingProvider)
        ? RowCheckbox.widthOf(
                context,
                singleLine: ref.watch(listDensityProvider).previewLines == 0,
              ) +
              4
        : 0.0;
    // How much wider any one column can go before the subject is squeezed
    // below its least.
    final room = math.max(0.0, layout.subject - lead - minSubject(context));

    Widget cell(MessageSort sort, String label, {IconData? icon}) =>
        _HeaderCell(
          label: label,
          icon: icon,
          sort: sort,
          current: display.sort,
          reversed: display.sortReversed,
          onTap: () => ref.read(displayProvider.notifier).sortByColumn(sort),
        );

    const gap = SizedBox(width: ColumnLayout.gap);
    final row = Row(
      children: [
        SizedBox(width: ColumnLayout.before + lead),
        if (layout.files > 0)
          SizedBox(
            width: layout.files,
            child: cell(
              MessageSort.attachments,
              'Attachments',
              icon: Icons.attach_file,
            ),
          ),
        SizedBox(
          width: layout.from,
          child: outgoing
              ? cell(MessageSort.recipient, 'To')
              : cell(MessageSort.sender, 'From'),
        ),
        gap,
        Expanded(child: cell(MessageSort.subject, 'Subject')),
        if (layout.received > 0) ...[
          gap,
          SizedBox(
            width: layout.received,
            child: cell(MessageSort.dateNewest, outgoing ? 'Sent' : 'Received'),
          ),
        ],
        if (layout.size > 0) ...[
          gap,
          SizedBox(width: layout.size, child: cell(MessageSort.size, 'Size')),
        ],
        const SizedBox(width: ColumnLayout.after),
      ],
    );

    // Each edge sits in the middle of the gap beside the column it widens:
    // after From, before Received and Size. Those two are kept to the
    // right, so theirs are counted from that end, where nothing on the
    // left moves them.
    final sizeAt = layout.width - ColumnLayout.after - layout.size;
    final edges = <(ListColumn, double, double)>[
      (
        ListColumn.from,
        ColumnLayout.before +
            lead +
            layout.files +
            layout.from +
            ColumnLayout.gap / 2,
        layout.from,
      ),
      if (layout.received > 0)
        (
          ListColumn.received,
          (layout.size > 0 ? sizeAt - ColumnLayout.gap : sizeAt) -
              layout.received -
              ColumnLayout.gap / 2,
          layout.received,
        ),
      if (layout.size > 0)
        (ListColumn.size, sizeAt - ColumnLayout.gap / 2, layout.size),
    ];

    return GestureDetector(
      onLongPressStart: (d) =>
          showArrangeMenu(context, ref, d.globalPosition, columns: true),
      onSecondaryTapUp: (d) =>
          showArrangeMenu(context, ref, d.globalPosition, columns: true),
      child: Stack(
        children: [
          row,
          for (final (column, x, width) in edges)
            Positioned(
              key: ValueKey('column-edge:${column.name}'),
              left: x - _ColumnEdge.hitWidth / 2,
              top: 0,
              bottom: 0,
              child: _ColumnEdge(
                label: '${column.label} column width',
                width: width,
                room: room,
                // From's edge is on its right, the others' on their left.
                rightwards: column == ListColumn.from,
                onWidth: (w) => columns.setWidth(column, w),
                onReset: () => columns.resetWidth(column),
              ),
            ),
        ],
      ),
    );
  }
}

/// One header: its name, and an arrow when the list is in its order.
class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.label,
    required this.sort,
    required this.current,
    required this.reversed,
    required this.onTap,
    this.icon,
  });

  final String label;

  /// Drawn in the label's place, which stays as what it is read out as.
  final IconData? icon;
  final MessageSort sort;
  final MessageSort current;
  final bool reversed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = sort.byDate ? current.byDate : current == sort;
    final colour = active ? scheme.primary : scheme.onSurfaceVariant;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: colour,
      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
    );
    // Outlook's triangles: down for newest, largest or Z first.
    final up = current.ascending != reversed;
    return Semantics(
      button: true,
      selected: active,
      label: 'Sort by $label',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: icon != null
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(icon, size: 14, color: colour),
                )
              : Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    if (active)
                      Icon(
                        up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                        key: const ValueKey('sort-arrow'),
                        size: 16,
                        color: colour,
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The edge between two headers, dragged to make the column beside it
/// wider: a line, and a wider strip a finger can find.
///
/// The width follows the finger from where it went down, counted from the
/// width the drag began at: a step at a time, from whatever the last frame
/// drew, the steps that came between two frames were lost, and the edge
/// fell behind the finger.
class _ColumnEdge extends StatefulWidget {
  const _ColumnEdge({
    required this.label,
    required this.width,
    required this.room,
    required this.rightwards,
    required this.onWidth,
    required this.onReset,
  });

  final String label;

  /// The column's width now, and how much wider it can go.
  final double width;
  final double room;

  /// Whether a drag to the right widens the column: From's edge is on its
  /// right, Received's and Size's on their left.
  final bool rightwards;

  final ValueChanged<double> onWidth;
  final VoidCallback onReset;

  static const double hitWidth = 20;

  @override
  State<_ColumnEdge> createState() => _ColumnEdgeState();
}

class _ColumnEdgeState extends State<_ColumnEdge> {
  bool _active = false;

  /// The width and room the drag began with, and how far it has gone.
  double _from = 0;
  double _room = 0;
  double _moved = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // From where the finger went down, not from where the drag was
        // recognised, or the edge starts out a slop behind it.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (_) => setState(() {
          _active = true;
          _from = widget.width;
          _room = widget.room;
          _moved = 0;
        }),
        onHorizontalDragUpdate: (d) {
          _moved += widget.rightwards ? d.delta.dx : -d.delta.dx;
          widget.onWidth(_from + math.min(_moved, _room));
        },
        onHorizontalDragEnd: (_) => setState(() => _active = false),
        onHorizontalDragCancel: () => setState(() => _active = false),
        onDoubleTap: widget.onReset,
        child: Semantics(
          label: widget.label,
          child: SizedBox(
            width: _ColumnEdge.hitWidth,
            child: Center(
              child: Container(
                width: _active ? 2 : 1,
                margin: EdgeInsets.symmetric(vertical: _active ? 0 : 6),
                color: _active ? scheme.primary : scheme.outlineVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlook's "By Date" over the list, and the arrow beside it that turns
/// the order round. The words open the menu of every order; the arrow
/// says which way the list runs, and points up with the newest, largest
/// or Z on top, as Outlook's does.
class SortButton extends ConsumerWidget {
  const SortButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colour = theme.colorScheme.onSurfaceVariant;
    final display = ref.watch(displayProvider);
    final ascending = display.sort.ascending != display.sortReversed;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Builder(
          builder: (context) => Tooltip(
            message: 'Arrange by',
            child: InkWell(
              key: const ValueKey('arrange-by'),
              onTap: () {
                final box = context.findRenderObject()! as RenderBox;
                showArrangeMenu(
                  context,
                  ref,
                  box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 2, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'By ${display.sort.shortLabel}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colour,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, size: 18, color: colour),
                  ],
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: display.sort.directionLabel(reversed: display.sortReversed),
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: colour,
          icon: Icon(ascending ? Icons.arrow_downward : Icons.arrow_upward),
          onPressed: ref.read(displayProvider.notifier).reverseSort,
        ),
      ],
    );
  }
}

/// The menu of every order, the arrow's Reverse, and Show in groups; with
/// [columns], the column headers' own as well: which columns show, and
/// their widths back as they were.
Future<void> showArrangeMenu(
  BuildContext context,
  WidgetRef ref,
  Offset at, {
  bool columns = false,
}) async {
  final display = ref.read(displayProvider);
  final shown = ref.read(listColumnsProvider);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  PopupMenuItem<String> check(String value, String text, bool on) =>
      CheckedPopupMenuItem<String>(
        value: value,
        height: 40,
        checked: on,
        child: Text(text),
      );
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final sort in MessageSort.values)
        // The dates are one choice here; the arrow says which way.
        if (sort != MessageSort.dateOldest)
          check(
            'sort:${sort.name}',
            sort.shortLabel,
            sort.byDate ? display.sort.byDate : display.sort == sort,
          ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: 'reverse',
        height: 40,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.swap_vert, size: 20),
          title: const Text('Reverse order'),
          subtitle: Text(
            display.sort.directionLabel(reversed: !display.sortReversed),
          ),
        ),
      ),
      check('groups', 'Show in groups', display.showGroups),
      if (columns) ...[
        const PopupMenuDivider(),
        for (final c in ListColumn.values)
          if (c.canHide)
            check('column:${c.name}', '${c.label} column', shown.shows(c)),
        const PopupMenuItem<String>(
          value: 'widths',
          height: 40,
          child: Text('Reset column widths'),
        ),
      ],
    ],
  );
  if (choice == null) return;
  final notifier = ref.read(displayProvider.notifier);
  switch (choice) {
    case 'reverse':
      notifier.reverseSort();
    case 'groups':
      notifier.setShowGroups(!display.showGroups);
    case 'widths':
      ref.read(listColumnsProvider.notifier).resetWidths();
    default:
      if (choice.startsWith('column:')) {
        ref
            .read(listColumnsProvider.notifier)
            .toggle(ListColumn.values.byName(choice.substring(7)));
        return;
      }
      final sort = MessageSort.values.byName(choice.substring(5));
      // The order the list is in already, chosen again, keeps its way.
      if (sort.byDate ? display.sort.byDate : display.sort == sort) return;
      notifier.setSort(sort);
  }
}
