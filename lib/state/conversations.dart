import '../domain/mail_message.dart';
import '../domain/message_sort.dart';

/// Grouping a message list into conversations.
///
/// Three signals, in that order of trust:
///
///  1. `In-Reply-To` pointing at another message's `Message-ID`. Exact, and
///     survives a renamed subject, which is what happens whenever a thread
///     drifts onto a new topic and someone edits the line.
///  2. The conversation the server keeps, where it keeps one: Exchange puts
///     one on every message and it is what Outlook groups by. A message
///     that has one is grouped by it alone, never by its subject: the
///     server knows two unrelated "SEO"s apart, and the subject does not.
///  3. The normalised subject, for the rest. Needed because the headers are
///     optional in practice and absent from everything cached before
///     threading existed, and because plenty of real mail answers a message
///     without saying so.
///
/// Deliberately not the full JWZ algorithm. That one reconstructs a tree from
/// the whole `References` chain, and a tree is not what a mail list shows: a
/// list shows a flat run of messages, newest last. What matters here is only
/// which messages belong together.
class Conversation {
  Conversation(this.messages);

  /// Oldest first, the order a thread is read in.
  final List<MailMessage> messages;

  MailMessage get newest => messages.last;
  MailMessage get oldest => messages.first;

  int get length => messages.length;
  bool get isThread => messages.length > 1;

  /// A conversation is unread if anything in it is. Marking one message read
  /// must not make the row look dealt with while two others are still unread.
  bool get hasUnread => messages.any((m) => !m.isRead);
  int get unreadCount => messages.where((m) => !m.isRead).length;

  bool get isFlagged => messages.any((m) => m.isFlagged);
  bool get hasAttachments => messages.any((m) => m.hasAttachments);

  /// What the collapsed row is keyed on. Stable across a refresh so an
  /// expanded conversation stays expanded.
  String get id => oldest.id;

  /// The subject of the message that started it, not the newest. A reply that
  /// changed "Re: Contract" to "Re: Contract (final)" should not rename the
  /// whole conversation in the list on arrival.
  String get subject => oldest.subject;

  /// Everyone who has written, oldest first, without repeats. Outlook shows
  /// this instead of one sender, because in a thread "who is this from" has
  /// more than one answer.
  List<MailAddress> get participants {
    final seen = <String>{};
    return [
      for (final m in messages)
        if (seen.add(m.from.email.toLowerCase())) m.from,
    ];
  }

  @override
  String toString() => 'Conversation(${messages.length}x $subject)';
}

/// Group [messages] into conversations, newest conversation first.
///
/// [messages] may be in any order. Within a conversation the messages come
/// back oldest first; the conversations themselves are ordered by their newest
/// message, so a thread that someone has just replied to rises to the top the
/// way it does in every mail client.
/// The messages the list shows as rows, top to bottom, which is the order
/// the arrow keys walk. With conversations off it is the list itself. On, a
/// closed thread is one row, stood for by its newest message, and an open
/// one is its messages newest first. The messages folded into a closed
/// thread are not there: landing on one would select a row nobody can see.
///
/// [sort] orders the threads, as the rows are drawn. The keys used to walk
/// them newest first whatever was chosen, so with oldest first Home went to
/// the bottom of the screen and Down went up.
List<MailMessage> visibleMessages(
  List<MailMessage> messages, {
  required bool conversations,
  required Set<String> expandedIds,
  required MessageSort sort,
}) {
  if (!conversations) return messages;
  return [
    for (final c in conversationsInOrder(messages, sort))
      if (!c.isThread || !expandedIds.contains(c.id))
        c.newest
      else
        ...c.messages.reversed,
  ];
}

/// [messages] as conversations, in the order the list shows them: by each
/// one's newest message, under [sort].
List<Conversation> conversationsInOrder(
  List<MailMessage> messages,
  MessageSort sort,
) {
  final grouped = groupIntoConversations(messages);
  if (sort == MessageSort.dateNewest) return grouped;
  return [...grouped]
    ..sort((a, b) => compareMessages(a.newest, b.newest, sort));
}

List<Conversation> groupIntoConversations(List<MailMessage> messages) {
  if (messages.isEmpty) return const [];

  final byMessageId = <String, MailMessage>{
    for (final m in messages)
      if (m.messageId != null) m.messageId!: m,
  };

  // Union-find over message ids, so a chain A <- B <- C ends up as one group
  // however the messages are ordered and whichever link is seen first.
  final parent = <String, String>{};

  String find(String x) {
    var root = x;
    while (parent[root] != null && parent[root] != root) {
      root = parent[root]!;
    }
    // Path compression, so a long thread does not walk the chain every time.
    var cursor = x;
    while (parent[cursor] != null && parent[cursor] != cursor) {
      final next = parent[cursor]!;
      parent[cursor] = root;
      cursor = next;
    }
    return root;
  }

  void union(String a, String b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  for (final m in messages) {
    parent.putIfAbsent(m.id, () => m.id);
  }

  // 1. Explicit links.
  for (final m in messages) {
    final answered = m.inReplyTo;
    if (answered == null) continue;
    final parentMessage = byMessageId[answered];
    if (parentMessage != null) union(m.id, parentMessage.id);
  }

  // 2. The server's conversation. Scoped to the account, as the subject is
  //    below: the ids are the server's, and two servers may agree on one.
  final byConversation = <(String, String), String>{};
  for (final m in messages) {
    final conversation = m.conversationId;
    if (conversation == null || conversation.isEmpty) continue;
    final key = (m.accountId, conversation);
    final existing = byConversation[key];
    if (existing == null) {
      byConversation[key] = m.id;
    } else {
      union(m.id, existing);
    }
  }

  // 3. Subject, for everything the headers did not already join, and only
  //    where the server has not spoken: a message with a conversation from
  //    it joins by that alone, or the subject would undo the server's word
  //    and put the two "SEO"s back together. Scoped to the account: two
  //    people can both send "Lunch?" and they are not one conversation just
  //    because both landed in a unified inbox.
  final bySubject = <(String, String), String>{};
  for (final m in messages) {
    if (m.conversationId != null && m.conversationId!.isNotEmpty) continue;
    final subject = normaliseSubject(m.subject);
    // A blank subject joins nothing, or every "(No subject)" in a
    // mailbox becomes one enormous conversation.
    if (subject.isEmpty) continue;
    // A record, not a joined string: an account id and a subject glued
    // with any separator can collide with a different pair containing it.
    final key = (m.accountId, subject);
    final existing = bySubject[key];
    if (existing == null) {
      bySubject[key] = m.id;
    } else {
      union(m.id, existing);
    }
  }

  final groups = <String, List<MailMessage>>{};
  for (final m in messages) {
    groups.putIfAbsent(find(m.id), () => []).add(m);
  }

  final conversations = [
    for (final group in groups.values)
      Conversation(group..sort((a, b) => a.date.compareTo(b.date))),
  ];
  conversations.sort((a, b) => b.newest.date.compareTo(a.newest.date));
  return conversations;
}

/// A subject with the reply and forward prefixes stripped, for comparison.
///
/// Handles the stacked ones a thread collects after passing through a few
/// clients, and the localised forms Outlook and others still send. Case and
/// runs of whitespace are flattened, because those are the differences a
/// human would not call a different subject.
String normaliseSubject(String subject) {
  var s = subject.trim();
  // `Re:`, `RE :`, `Fwd:`, `FW:`, `Re[2]:`, `Antwort:`, `SV:`, `VS:`, `Aw:`.
  final prefix = RegExp(
    r'^\s*(re|aw|antwort|sv|vs|fwd?|wg|tr|rif|res|enc)\s*(\[\d+\])?\s*:\s*',
    caseSensitive: false,
  );
  while (true) {
    final stripped = s.replaceFirst(prefix, '');
    if (stripped == s) break;
    s = stripped;
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}
