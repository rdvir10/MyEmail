import 'mail_message.dart';

/// What a list is ordered by.
///
/// Four choices on one list rather than a field and a direction to set
/// separately: the only direction anyone wants for a name is A to Z, and
/// for dates the two are different enough to deserve their own words.
///
/// Mail is newest first everywhere, which is right nearly all the time and
/// wrong exactly when someone is looking for a thing rather than reading
/// what arrived: everything from one sender, or a subject half remembered.
enum MessageSort {
  dateNewest('Date (newest first)'),
  dateOldest('Date (oldest first)'),
  sender('Sender'),
  subject('Subject');

  const MessageSort(this.label);

  final String label;

  /// Only dates are ever read backwards; names and subjects run A to Z.
  bool get ascending => this != MessageSort.dateNewest;
}

/// The order of two messages under one choice.
///
/// Always broken by date, newest first, and then by id: two messages from
/// the same sender with the same subject still need a settled order, or
/// the list shuffles itself on every rebuild.
int compareMessages(MailMessage a, MailMessage b, MessageSort sort) {
  final sign = sort.ascending ? 1 : -1;
  final first = switch (sort) {
    MessageSort.dateNewest || MessageSort.dateOldest => a.date.compareTo(b.date),
    MessageSort.sender => _text(a.from.display).compareTo(_text(b.from.display)),
    MessageSort.subject => _text(_withoutReplyPrefix(a.subject))
        .compareTo(_text(_withoutReplyPrefix(b.subject))),
  };
  if (first != 0) return sign * first;
  if (sort != MessageSort.dateNewest && sort != MessageSort.dateOldest) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
  }
  return a.id.compareTo(b.id);
}

List<MailMessage> sortMessages(List<MailMessage> messages, MessageSort sort) =>
    [...messages]..sort((a, b) => compareMessages(a, b, sort));

/// Sorting by subject with "Re:" in the way puts every reply under R,
/// away from the message it answers, which is the opposite of what
/// sorting by subject is for.
String _withoutReplyPrefix(String subject) {
  var s = subject.trim();
  final prefix =
      RegExp(r'^\s*(re|fw|fwd)\s*(\[\d+\])?\s*:\s*', caseSensitive: false);
  while (prefix.hasMatch(s)) {
    s = s.replaceFirst(prefix, '');
  }
  return s;
}

String _text(String value) => value.trim().toLowerCase();
