import 'mail_message.dart';

/// What a list is ordered by.
///
/// One list of choices rather than a field and a direction to set
/// separately: the only direction anyone wants for a name is A to Z, and
/// for dates the two are different enough to deserve their own words.
///
/// Mail is newest first everywhere, which is right nearly all the time and
/// wrong exactly when someone is looking for a thing rather than reading
/// what arrived: everything from one sender, or a subject half remembered.
/// The rest are Outlook's Arrange By: the largest mail when the mailbox is
/// full, what has files, what is flagged, and in All Inboxes which account.
enum MessageSort {
  dateNewest('Date (newest first)'),
  dateOldest('Date (oldest first)'),
  sender('Sender'),
  recipient('To'),
  subject('Subject'),
  size('Size (largest first)'),
  attachments('Attachments'),
  flag('Flag'),
  account('Account');

  const MessageSort(this.label);

  final String label;

  /// Whether the first key runs from small to large. Dates newest first,
  /// sizes largest first, and what has files or a flag before what has not;
  /// names and subjects run A to Z.
  bool get ascending => switch (this) {
        dateNewest || size || attachments || flag => false,
        _ => true,
      };

  /// In date order, where the list has its date bars.
  bool get byDate => this == dateNewest || this == dateOldest;

  /// Whether the list draws bars over its groups: a day, a size, flagged or
  /// not. Sorted by a name or a subject there is a group for every name,
  /// and a bar over each would be a list of bars.
  bool get hasBars => switch (this) {
        dateNewest || dateOldest || size || attachments || flag || account =>
          true,
        sender || recipient || subject => false,
      };
}

/// The order of two messages under one choice.
///
/// Always broken by date, newest first, and then by id: two messages from
/// the same sender with the same subject still need a settled order, or
/// the list shuffles itself on every rebuild.
///
/// [accountRank] is each account's place in the folder pane, for
/// [MessageSort.account]; an account not in it goes last.
int compareMessages(
  MailMessage a,
  MailMessage b,
  MessageSort sort, {
  Map<String, int> accountRank = const {},
}) {
  final first = switch (sort) {
    MessageSort.dateNewest => b.date.compareTo(a.date),
    MessageSort.dateOldest => a.date.compareTo(b.date),
    MessageSort.sender => _text(a.from.display).compareTo(_text(b.from.display)),
    MessageSort.recipient => _byName(_firstRecipient(a), _firstRecipient(b)),
    MessageSort.subject => _text(_withoutReplyPrefix(a.subject))
        .compareTo(_text(_withoutReplyPrefix(b.subject))),
    MessageSort.size => b.sizeBytes.compareTo(a.sizeBytes),
    MessageSort.attachments => _yesFirst(a.hasAttachments, b.hasAttachments),
    MessageSort.flag => _yesFirst(a.isFlagged, b.isFlagged),
    MessageSort.account => (accountRank[a.accountId] ?? _last)
        .compareTo(accountRank[b.accountId] ?? _last),
  };
  if (first != 0) return first;
  if (!sort.byDate) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
  }
  return a.id.compareTo(b.id);
}

/// [messages] in the order [sort] puts them, with the [pinned] ones (by id)
/// at the top, in that same order among themselves.
List<MailMessage> sortMessages(
  List<MailMessage> messages,
  MessageSort sort, {
  Map<String, int> accountRank = const {},
  Set<String> pinned = const {},
}) {
  final sorted = [...messages]
    ..sort((a, b) => compareMessages(a, b, sort, accountRank: accountRank));
  if (pinned.isEmpty) return sorted;
  return [
    for (final m in sorted)
      if (pinned.contains(m.id)) m,
    for (final m in sorted)
      if (!pinned.contains(m.id)) m,
  ];
}

const _last = 1 << 30;

/// True before false.
int _yesFirst(bool a, bool b) => a == b ? 0 : (a ? -1 : 1);

/// A to Z, with nobody at all after everyone: a draft with no recipients
/// yet is not the first thing anyone looks for under To.
int _byName(String a, String b) {
  if (a.isEmpty || b.isEmpty) return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? 1 : -1);
  return _text(a).compareTo(_text(b));
}

/// Who a message went to first: the first name on To, or on Cc where To
/// is empty.
String _firstRecipient(MailMessage m) {
  final named = m.to.isNotEmpty ? m.to : m.cc;
  return named.isEmpty ? '' : named.first.display;
}

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
