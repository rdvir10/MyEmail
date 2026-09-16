import 'package:flutter/foundation.dart';

/// Where the message being read appears.
///
/// Outlook's three, and for the same reasons. The choice only bites on a
/// screen wide or tall enough to split; a phone always opens a message as its
/// own screen because there is nowhere else for it to go.
enum ReadingPanePosition {
  /// Beside the list. The default, and what a landscape tablet wants.
  right,

  /// Under the list. Better in portrait, where a right-hand pane would leave
  /// both halves too narrow to read.
  bottom,

  /// No pane. A message opens as its own screen, which gives it the whole
  /// width and is what some people simply prefer.
  off;

  String get label => switch (this) {
        ReadingPanePosition.right => 'Right',
        ReadingPanePosition.bottom => 'Bottom',
        ReadingPanePosition.off => 'Off',
      };

  String get description => switch (this) {
        ReadingPanePosition.right => 'Beside the message list',
        ReadingPanePosition.bottom => 'Below the message list',
        ReadingPanePosition.off => 'Messages open on their own screen',
      };
}

/// How much room each row in the message list gets.
enum ListDensity {
  /// Two lines: who and when, then the subject. The most mail on screen.
  compact,

  /// Three lines: the above plus a line of preview. The default.
  cozy,

  /// Three lines with room to breathe, and an easier tap target.
  comfortable;

  String get label => switch (this) {
        ListDensity.compact => 'Compact',
        ListDensity.cozy => 'Cozy',
        ListDensity.comfortable => 'Comfortable',
      };

  /// How many lines of the message body the row previews. Zero drops the
  /// preview line entirely, which is what makes compact compact.
  int get previewLines => switch (this) {
        ListDensity.compact => 0,
        ListDensity.cozy => 1,
        ListDensity.comfortable => 2,
      };

  /// Vertical padding per row. The horizontal padding does not change: the
  /// text should stay on the same left edge as the density changes, or the
  /// whole list appears to shift sideways.
  double get verticalPadding => switch (this) {
        ListDensity.compact => 7,
        ListDensity.cozy => 10,
        ListDensity.comfortable => 14,
      };
}

/// Everything under Settings, View.
@immutable
class DisplaySettings {
  const DisplaySettings({
    this.readingPane = ReadingPanePosition.right,
    this.density = ListDensity.cozy,
    this.conversations = false,
  });

  final ReadingPanePosition readingPane;
  final ListDensity density;

  /// Group a list by conversation rather than showing every message.
  ///
  /// Off by default, because it changes what a row means and that is not a
  /// decision to make on someone's behalf on first run.
  final bool conversations;

  DisplaySettings copyWith({
    ReadingPanePosition? readingPane,
    ListDensity? density,
    bool? conversations,
  }) {
    return DisplaySettings(
      readingPane: readingPane ?? this.readingPane,
      density: density ?? this.density,
      conversations: conversations ?? this.conversations,
    );
  }

  Map<String, Object?> toJson() => {
        'readingPane': readingPane.name,
        'density': density.name,
        'conversations': conversations,
      };

  /// Tolerant of anything: a value written by a newer build, or a corrupted
  /// record, falls back to the default rather than leaving the app unable to
  /// draw a message list.
  factory DisplaySettings.fromJson(Map<String, dynamic> json) {
    return DisplaySettings(
      readingPane: _byName(
        ReadingPanePosition.values,
        json['readingPane'],
        ReadingPanePosition.right,
      ),
      density: _byName(ListDensity.values, json['density'], ListDensity.cozy),
      conversations: json['conversations'] is bool
          ? json['conversations'] as bool
          : false,
    );
  }

  static T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is DisplaySettings &&
      other.readingPane == readingPane &&
      other.density == density &&
      other.conversations == conversations;

  @override
  int get hashCode => Object.hash(readingPane, density, conversations);

  @override
  String toString() => 'DisplaySettings(${readingPane.name}, ${density.name}, '
      'conversations: $conversations)';
}
