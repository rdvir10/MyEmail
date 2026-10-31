import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import 'providers.dart';

/// The message list's columns, where it is wide enough to have them: which
/// are showing, and how wide the ones a drag can change are. Remembered per
/// device, as the panes' widths are.
///
/// From and Subject always show: a row with neither is not a row. Subject
/// has no width of its own; it takes what the others leave.
class ListColumns extends Notifier<ColumnSettings> {
  @override
  ColumnSettings build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf(
      (_, next) => store.writeOrder(UiStateKeys.listColumns, {
        if (next.from != null) 'from': next.from!.round(),
        if (next.received != null) 'received': next.received!.round(),
        if (next.size != null) 'size': next.size!.round(),
        for (final c in next.hidden) 'hide.${c.name}': 1,
      }),
    );
    final saved = store.readOrder(UiStateKeys.listColumns);
    return ColumnSettings(
      from: saved['from']?.toDouble(),
      received: saved['received']?.toDouble(),
      size: saved['size']?.toDouble(),
      hidden: {
        for (final c in ListColumn.values)
          if (c.canHide && saved['hide.${c.name}'] == 1) c,
      },
    );
  }

  /// [column] made [width] wide, within its bounds.
  void setWidth(ListColumn column, double width) {
    final w = column.clamp(width);
    state = switch (column) {
      ListColumn.from => state.copyWith(from: w),
      ListColumn.received => state.copyWith(received: w),
      ListColumn.size => state.copyWith(size: w),
      ListColumn.files || ListColumn.subject => state,
    };
  }

  void toggle(ListColumn column) {
    if (!column.canHide) return;
    final hidden = {...state.hidden};
    if (!hidden.remove(column)) hidden.add(column);
    state = state.copyWith(hidden: hidden);
  }

  /// [column] back to the width its text is drawn at: a double tap on its
  /// edge, as a double click on one fits it in Outlook.
  void resetWidth(ListColumn column) => state = ColumnSettings(
    from: column == ListColumn.from ? null : state.from,
    received: column == ListColumn.received ? null : state.received,
    size: column == ListColumn.size ? null : state.size,
    hidden: state.hidden,
  );

  /// Every column back to the width its text is drawn at. Offered because
  /// a drag can leave a column somewhere the user did not mean, as the
  /// panes' Reset is.
  void resetWidths() => state = ColumnSettings(hidden: state.hidden);
}

final listColumnsProvider = NotifierProvider<ListColumns, ColumnSettings>(
  ListColumns.new,
);

/// The list's columns, left to right, as Outlook's are.
enum ListColumn {
  files('Attachment'),
  from('From'),
  subject('Subject'),
  received('Received'),
  size('Size');

  const ListColumn(this.label);

  /// What the column's entry in the header's menu calls it.
  final String label;

  bool get canHide => this == files || this == received || this == size;

  /// Bounds, not preferences: narrower and nothing in the column can be
  /// read, wider and it starves the subject.
  double clamp(double width) => switch (this) {
    from => width.clamp(80, 400),
    received => width.clamp(60, 260),
    size => width.clamp(36, 120),
    files || subject => width,
  };
}

class ColumnSettings {
  const ColumnSettings({
    this.from,
    this.received,
    this.size,
    this.hidden = const {},
  });

  /// Widths dragged to, or null for the width the text is drawn at.
  final double? from;
  final double? received;
  final double? size;

  /// Columns put away from the header's menu.
  final Set<ListColumn> hidden;

  bool shows(ListColumn column) => !hidden.contains(column);

  ColumnSettings copyWith({
    double? from,
    double? received,
    double? size,
    Set<ListColumn>? hidden,
  }) => ColumnSettings(
    from: from ?? this.from,
    received: received ?? this.received,
    size: size ?? this.size,
    hidden: hidden ?? this.hidden,
  );

  @override
  bool operator ==(Object other) =>
      other is ColumnSettings &&
      other.from == from &&
      other.received == received &&
      other.size == size &&
      other.hidden.length == hidden.length &&
      other.hidden.containsAll(hidden);

  @override
  int get hashCode =>
      Object.hash(from, received, size, Object.hashAllUnordered(hidden));

  @override
  String toString() =>
      'ColumnSettings(from: $from, received: $received, '
      'size: $size, hidden: ${hidden.map((c) => c.name).join(',')})';
}
