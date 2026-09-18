import 'package:flutter/material.dart';

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

  /// The next one round, for the ribbon button that cycles them.
  ///
  /// Right, bottom, off, and back. Off sits last on purpose: it is the one
  /// most likely to be passed through rather than wanted, and putting it at
  /// the end means the two useful positions are one tap apart.
  ReadingPanePosition get next => switch (this) {
        ReadingPanePosition.right => ReadingPanePosition.bottom,
        ReadingPanePosition.bottom => ReadingPanePosition.off,
        ReadingPanePosition.off => ReadingPanePosition.right,
      };

  /// What this position looks like as a button.
  ///
  /// The icon shows where the pane is now, not where it is going. A ribbon
  /// button that previews its own next state reads as a status light that
  /// lies.
  IconData get icon => switch (this) {
        ReadingPanePosition.right => Icons.vertical_split_outlined,
        ReadingPanePosition.bottom => Icons.horizontal_split_outlined,
        ReadingPanePosition.off => Icons.crop_square_outlined,
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

/// What a swipe across a message row does.
///
/// Deliberately a small set. A swipe is one gesture with no confirmation step
/// and no way to see what it is going to do before it happens, so everything
/// here is either reversible in one tap ([toggleRead], [toggleFlag]), asks
/// before it commits ([move]), or lands somewhere it can be retrieved from
/// ([delete] goes to the Deleted folder, [archive] to Archive). Nothing here
/// destroys mail outright.
enum SwipeAction {
  none('Nothing', 'Swiping does nothing'),
  delete('Delete', 'Move to the Deleted folder'),
  move('Move to...', 'Ask which folder, then move'),
  toggleRead('Read / unread', 'Flip whether it has been read'),
  toggleFlag('Flag', 'Flag it, or take the flag off'),
  archive('Archive', 'Move to the Archive folder');

  const SwipeAction(this.label, this.description);

  final String label;
  final String description;

  /// Whether this needs an Archive folder to exist on the account.
  ///
  /// Gmail's "All Mail" is not one of these: archiving there means removing
  /// the Inbox label rather than moving, so the row is left alone and the
  /// swipe says so rather than appearing to work.
  bool get needsArchiveFolder => this == SwipeAction.archive;
}

/// Everything under Settings, View.
@immutable
class DisplaySettings {
  const DisplaySettings({
    this.readingPane = ReadingPanePosition.right,
    this.density = ListDensity.cozy,
    this.conversations = false,
    this.swipeRight = SwipeAction.move,
    this.swipeLeft = SwipeAction.delete,
  });

  final ReadingPanePosition readingPane;
  final ListDensity density;

  /// Dragging a row to the right, and to the left.
  ///
  /// The defaults are what the list did before these were settings, so an
  /// existing install behaves the same until someone changes it.
  final SwipeAction swipeRight;
  final SwipeAction swipeLeft;

  /// Group a list by conversation rather than showing every message.
  ///
  /// Off by default, because it changes what a row means and that is not a
  /// decision to make on someone's behalf on first run.
  final bool conversations;

  DisplaySettings copyWith({
    ReadingPanePosition? readingPane,
    ListDensity? density,
    bool? conversations,
    SwipeAction? swipeRight,
    SwipeAction? swipeLeft,
  }) {
    return DisplaySettings(
      readingPane: readingPane ?? this.readingPane,
      density: density ?? this.density,
      conversations: conversations ?? this.conversations,
      swipeRight: swipeRight ?? this.swipeRight,
      swipeLeft: swipeLeft ?? this.swipeLeft,
    );
  }

  Map<String, Object?> toJson() => {
        'readingPane': readingPane.name,
        'density': density.name,
        'conversations': conversations,
        'swipeRight': swipeRight.name,
        'swipeLeft': swipeLeft.name,
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
      // An install from before swipes were configurable has neither key, and
      // falls back to exactly what it was already doing.
      swipeRight: _byName(
        SwipeAction.values,
        json['swipeRight'],
        SwipeAction.move,
      ),
      swipeLeft: _byName(
        SwipeAction.values,
        json['swipeLeft'],
        SwipeAction.delete,
      ),
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
      other.conversations == conversations &&
      other.swipeRight == swipeRight &&
      other.swipeLeft == swipeLeft;

  @override
  int get hashCode =>
      Object.hash(readingPane, density, conversations, swipeRight, swipeLeft);

  @override
  String toString() => 'DisplaySettings(${readingPane.name}, ${density.name}, '
      'conversations: $conversations, '
      'swipe: ${swipeRight.name}/${swipeLeft.name})';
}
