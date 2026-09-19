import 'mail_message.dart';

/// The two numbers a home-screen widget shows for one mailbox.
class MailboxCounts {
  const MailboxCounts({
    required this.folderId,
    required this.label,
    required this.total,
    required this.fresh,
  });

  final String folderId;

  /// What the widget calls this mailbox: the folder and whose it is, because
  /// two accounts both have an Inbox and a widget with no name on it is a
  /// number without a subject.
  final String label;

  /// Everything in the folder, as the server counts it.
  final int total;

  /// How many arrived since the app was last opened.
  final int fresh;

  @override
  String toString() => 'MailboxCounts($label, total $total, new $fresh)';
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
