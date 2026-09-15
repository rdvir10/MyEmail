import '../../domain/mail_message.dart';

/// Deciding what counts as "new mail worth interrupting someone for".
///
/// Kept free of plugins, isolates and IO so the rules can be tested directly.
/// Every one of them exists because of a way this goes wrong:
///
///  * Announcing everything on the first run. A fresh install syncs an inbox
///    with thousands of messages in it. The first scan of a folder therefore
///    announces nothing and only records where it got to.
///  * Announcing the same message twice. The pass runs every fifteen minutes
///    over an overlapping window, so the watermark, not the window, decides.
///  * Announcing mail the user has already read. They may have read it on the
///    web, on another device, or in this app between passes.
///  * Announcing old mail after a server-side rebuild. When UIDVALIDITY
///    changes, UIDs restart from a lower number and every cached message looks
///    new. A window whose highest UID is *below* the watermark is the visible
///    symptom, and the answer is to rebase silently.
///  * Announcing a backlog after the phone has been off. Mail older than
///    [defaultMaxAge] is caught up on, not announced.

/// How far back a message can be dated and still be worth a notification.
const defaultMaxAge = Duration(days: 2);

/// The messages in [messages] that deserve a notification, newest first.
///
/// [messages] is one folder's newest-first window as the cache holds it, and
/// [watermark] is the highest UID already announced for that folder.
List<MailMessage> selectNotifiable({
  required List<MailMessage> messages,
  required int? watermark,
  required DateTime now,
  Duration maxAge = defaultMaxAge,
}) {
  // First scan of this folder: record the position, announce nothing.
  if (watermark == null) return const [];
  if (messages.isEmpty) return const [];

  // UIDs went backwards, so the server renumbered them. Nothing here is
  // reliably new; rebase quietly rather than announce the whole folder.
  final highest = messages.map((m) => m.uid).reduce((a, b) => a > b ? a : b);
  if (highest < watermark) return const [];

  final cutoff = now.subtract(maxAge);
  final fresh = [
    for (final m in messages)
      if (m.uid > watermark && !m.isRead && m.date.isAfter(cutoff)) m,
  ]..sort((a, b) => b.uid.compareTo(a.uid));
  return fresh;
}

/// Where the watermark should sit once a pass has looked at [messages].
///
/// Returns null when there is nothing to record, which only happens for a
/// folder that is empty and has never been scanned. Note this moves past
/// messages that were *not* announced — already read, too old, or arriving
/// during the first scan — which is the point: they are accounted for, and a
/// later pass must not reconsider them.
int? nextWatermark({
  required List<MailMessage> messages,
  required int? watermark,
}) {
  if (messages.isEmpty) {
    // An empty folder still needs a mark, or its first delivered message is
    // treated as a first scan and silently swallowed.
    return watermark ?? 0;
  }
  final highest = messages.map((m) => m.uid).reduce((a, b) => a > b ? a : b);
  // Deliberately not max(highest, watermark): a lower highest UID means the
  // server renumbered, and following it downward is how the watermark gets
  // back in step with the new numbering.
  return highest;
}
