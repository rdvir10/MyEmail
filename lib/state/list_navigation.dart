import '../domain/mail_message.dart';

/// Where to land when a folder opens.
///
/// In order: whatever is already open and still there, then wherever this
/// folder was left, then the top of the list.
///
/// Keeping an existing selection first matters more than it looks. The list
/// rebuilds whenever anything in it changes — a flag, a read mark, a sync
/// arriving — and a rule that reached for the remembered message each time
/// would drag the person back off whatever they had moved to.
String? messageToLandOn({
  required List<MailMessage> messages,
  String? lastOpened,
  String? current,
}) {
  if (messages.isEmpty) return null;
  if (current != null && messages.any((m) => m.id == current)) return current;
  if (lastOpened != null && messages.any((m) => m.id == lastOpened)) {
    return lastOpened;
  }
  return messages.first.id;
}

/// The message [delta] rows away, for the arrow keys and Page Up and Down.
///
/// Stops at the ends rather than wrapping. Wrapping from the last message to
/// the first is the kind of cleverness that loses someone's place in a list
/// of four hundred, and holding an arrow key to the bottom should come to
/// rest there rather than start again. A move that would go past an end
/// goes to it: Page Down with fewer than a page left used not to move at
/// all, which looked like the key had stopped working.
///
/// Only the rows in [shown] count, where it is given: the rest are folded
/// under a closed date bar. The selection can be one of those, closed in
/// with its group, and from there Down goes on to the first row after the
/// group and Up back to the last one before it.
String? neighbourOf(
  List<MailMessage> messages,
  String? current,
  int delta, {
  Set<String>? shown,
}) {
  final rows = shown == null
      ? messages
      : [for (final m in messages) if (shown.contains(m.id)) m];
  if (rows.isEmpty) return null;
  if (current == null) {
    return delta > 0 ? rows.first.id : rows.last.id;
  }
  final at = messages.indexWhere((m) => m.id == current);
  // Selected something that is no longer in the list — deleted elsewhere, or
  // filtered out. The top is a better answer than nothing.
  if (at < 0) return rows.first.id;
  // Where the selection falls among the rows that count: the first after
  // it is rows[before], so one that is itself folded away is a step short.
  final before = shown == null
      ? at
      : messages.take(at).where((m) => shown.contains(m.id)).length;
  final folded = shown != null && !shown.contains(current);
  final to = folded && delta > 0 ? before + delta - 1 : before + delta;
  return rows[to.clamp(0, rows.length - 1)].id;
}
