import '../../domain/mail_message.dart';
import '../../domain/message_sort.dart';
import 'date_format.dart';

/// The bar a row of the list sits under: a day, a size, flagged or not, an
/// account, or Pinned, depending on how the list is arranged.
///
/// Keyed so the bar's closed state survives a refresh: the same group has
/// the same key for as long as the arrangement is the same.
class ListGroup {
  const ListGroup(this.key, this.label);

  /// Equal for two rows under the same bar.
  final String key;

  /// What the bar says.
  final String label;

  /// Above everything else, whatever the arrangement: new Outlook's pinned
  /// messages.
  static const pinned = ListGroup('pinned', 'Pinned');

  @override
  bool operator ==(Object other) => other is ListGroup && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The group [lead] belongs to under [sort], the message that stands for a
/// row, or null where [sort] draws no bars. [accountNames] names the
/// groups of [MessageSort.account].
ListGroup? listGroupOf(
  MailMessage lead,
  MessageSort sort, {
  DateTime? now,
  Map<String, String> accountNames = const {},
}) {
  switch (sort) {
    case MessageSort.dateNewest || MessageSort.dateOldest:
      final day = DateGroup.of(lead.date, now: now);
      return ListGroup(day.key, day.label);
    case MessageSort.size:
      return sizeGroup(lead.sizeBytes);
    case MessageSort.attachments:
      return lead.hasAttachments
          ? const ListGroup('files:yes', 'With attachments')
          : const ListGroup('files:no', 'Without attachments');
    case MessageSort.flag:
      return lead.isFlagged
          ? const ListGroup('flag:yes', 'Flagged')
          : const ListGroup('flag:no', 'Not flagged');
    case MessageSort.account:
      return ListGroup(
        'account:${lead.accountId}',
        accountNames[lead.accountId] ?? 'Other',
      );
    case MessageSort.sender || MessageSort.recipient || MessageSort.subject:
      return null;
  }
}

/// Outlook's size groups, by what the server says the whole message
/// weighs.
ListGroup sizeGroup(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes <= 0) return const ListGroup('size:unknown', 'Size not known');
  if (bytes > 5 * mb) {
    return const ListGroup('size:enormous', 'Enormous (over 5 MB)');
  }
  if (bytes > mb) return const ListGroup('size:huge', 'Huge (1 to 5 MB)');
  if (bytes > 500 * kb) {
    return const ListGroup('size:very-large', 'Very large (500 KB to 1 MB)');
  }
  if (bytes > 100 * kb) {
    return const ListGroup('size:large', 'Large (100 to 500 KB)');
  }
  if (bytes > 25 * kb) {
    return const ListGroup('size:medium', 'Medium (25 to 100 KB)');
  }
  if (bytes > 10 * kb) {
    return const ListGroup('size:small', 'Small (10 to 25 KB)');
  }
  return const ListGroup('size:tiny', 'Tiny (under 10 KB)');
}

/// Whether a row sits under one of the [closed] bars, as `visibleMessages`
/// asks it of the message that stands for the row. Null when none can:
/// nothing closed, or a list sorted by sender, recipient or subject, which
/// has no bars to close. Pinned rows are decided apart from this; see
/// `visibleMessages`.
bool Function(MailMessage row)? foldedUnder(
  Set<String>? closed,
  MessageSort sort, {
  DateTime? now,
  Map<String, String> accountNames = const {},
}) {
  if (closed == null || closed.isEmpty || !sort.hasBars) return null;
  final n = now ?? DateTime.now();
  return (row) => closed.contains(
        listGroupOf(row, sort, now: n, accountNames: accountNames)!.key,
      );
}
