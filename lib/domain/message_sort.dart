import 'mail_message.dart';

/// What a list is ordered by.
///
/// Mail is newest first everywhere, which is right nearly all the time and
/// wrong exactly when someone is looking for a thing rather than reading
/// what arrived: everything from one sender, or a subject they half
/// remember. These are the three orders worth having; anything more is a
/// menu nobody reads.
enum MessageSortField {
  date('Date'),
  sender('Sender'),
  subject('Subject');

  const MessageSortField(this.label);

  final String label;

  /// What the two directions are called for this field. "Ascending" means
  /// nothing to anyone; "Newest first" and "A to Z" do.
  String directionLabel({required bool ascending}) => switch (this) {
        MessageSortField.date => ascending ? 'Oldest first' : 'Newest first',
        _ => ascending ? 'A to Z' : 'Z to A',
      };

  /// The direction this field is normally wanted in, used when the field
  /// changes: dates run newest first, names run A to Z.
  bool get defaultAscending => this != MessageSortField.date;
}

/// The order of two messages under one field.
///
/// Always broken by date, newest first, and then by id: two messages from
/// the same sender with the same subject still need a settled order, or
/// the list shuffles itself on every rebuild.
int compareMessages(
  MailMessage a,
  MailMessage b,
  MessageSortField field, {
  required bool ascending,
}) {
  final sign = ascending ? 1 : -1;
  final first = switch (field) {
    MessageSortField.date => a.date.compareTo(b.date),
    MessageSortField.sender =>
      _text(a.from.display).compareTo(_text(b.from.display)),
    MessageSortField.subject =>
      _text(_withoutReplyPrefix(a.subject)).compareTo(
        _text(_withoutReplyPrefix(b.subject)),
      ),
  };
  if (first != 0) return sign * first;
  if (field != MessageSortField.date) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
  }
  return a.id.compareTo(b.id);
}

List<MailMessage> sortMessages(
  List<MailMessage> messages,
  MessageSortField field, {
  required bool ascending,
}) {
  final sorted = [...messages]
    ..sort((a, b) => compareMessages(a, b, field, ascending: ascending));
  return sorted;
}

/// Sorting by subject with "Re:" in the way puts every reply under R,
/// away from the message it answers, which is the opposite of what
/// sorting by subject is for.
String _withoutReplyPrefix(String subject) {
  var s = subject.trim();
  final prefix = RegExp(r'^\s*(re|fw|fwd)\s*(\[\d+\])?\s*:\s*', caseSensitive: false);
  while (prefix.hasMatch(s)) {
    s = s.replaceFirst(prefix, '');
  }
  return s;
}

String _text(String value) => value.trim().toLowerCase();
