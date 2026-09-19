import 'mail_message.dart';

/// What the lower number on a widget counts.
enum WidgetCount {
  /// Everything in the folder. What a Sent or Archive folder wants, where
  /// "unread" is a number that never changes.
  all('Everything in the folder'),

  /// Only what has not been read. What an Inbox usually wants: the number
  /// that goes down as you deal with things.
  unread('Only what is unread');

  const WidgetCount(this.description);

  final String description;

  String get label => switch (this) {
        WidgetCount.all => 'All messages',
        WidgetCount.unread => 'Unread only',
      };
}

/// What colour a widget's tile is.
///
/// A short list rather than a colour wheel. The point is telling two widgets
/// apart at a glance on a busy home screen, which half a dozen clearly
/// different colours does as well as sixteen million, and every one of these
/// is dark enough for white numbers to read on.
enum WidgetColour {
  orange('Orange', 0xFFFF7A18, 0xFFC1420A),
  blue('Blue', 0xFF1D74D0, 0xFF0A3F7A),
  teal('Teal', 0xFF00897B, 0xFF00463D),
  purple('Purple', 0xFF7048C8, 0xFF3B1E78),
  green('Green', 0xFF3F9142, 0xFF1F5221),
  red('Red', 0xFFD93B3B, 0xFF8C1C1C),
  graphite('Graphite', 0xFF4A4F57, 0xFF23262B);

  const WidgetColour(this.label, this.value, this.deep);

  final String label;

  /// The tile colour itself.
  final int value;

  /// The darker end, for where a gradient is drawn rather than a flat fill.
  final int deep;

  static WidgetColour byName(String? name) => WidgetColour.values.firstWhere(
        (c) => c.name == name,
        orElse: () => WidgetColour.orange,
      );
}

/// The numbers a home-screen widget shows for one mailbox.
class MailboxCounts {
  const MailboxCounts({
    required this.folderId,
    required this.label,
    required this.total,
    required this.unread,
    required this.fresh,
  });

  final String folderId;

  /// What the widget calls this mailbox: the folder and whose it is, because
  /// two accounts both have an Inbox and a widget with no name on it is a
  /// number without a subject.
  final String label;

  /// Everything in the folder, as the server counts it.
  final int total;

  /// How much of it has not been read.
  final int unread;

  /// How many arrived since the app was last opened.
  final int fresh;

  /// The number this widget is set to show.
  int countFor(WidgetCount which) =>
      which == WidgetCount.unread ? unread : total;

  @override
  String toString() =>
      'MailboxCounts($label, total $total, unread $unread, new $fresh)';
}

/// How many of [messages] arrived after [mark].
///
/// A null mark means the app has never been opened since the widget was
/// placed. That counts as none rather than all: a fresh install would
/// otherwise announce four thousand new messages, which is true in a useless
/// way.
///
/// Counted by arrival, not by whether anyone has read them. "New since you
/// last opened" is a question about the mail, and reading it on the laptop
/// does not make it not have arrived.
int arrivedSince(Iterable<MailMessage> messages, DateTime? mark) {
  if (mark == null) return 0;
  var count = 0;
  for (final m in messages) {
    if (m.date.isAfter(mark)) count++;
  }
  return count;
}
