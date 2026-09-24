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
String? neighbourOf(List<MailMessage> messages, String? current, int delta) {
  if (messages.isEmpty) return null;
  if (current == null) {
    return delta > 0 ? messages.first.id : messages.last.id;
  }
  final at = messages.indexWhere((m) => m.id == current);
  // Selected something that is no longer in the list — deleted elsewhere, or
  // filtered out. The top is a better answer than nothing.
  if (at < 0) return messages.first.id;
  return messages[(at + delta).clamp(0, messages.length - 1)].id;
}
