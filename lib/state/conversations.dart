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
/// All three within one account. A conversation's row is acted on whole,
/// archived or moved or deleted, and one spanning two mailboxes carried
/// one's mail into the other.
///
/// Deliberately not the full JWZ algorithm. That one reconstructs a tree from
/// the whole `References` chain, and a tree is not what a mail list shows: a
/// list shows a flat run of messages, newest last. What matters here is only
/// which messages belong together.
class Conversation {
  Conversation(this.messages, {this.others = const []});

  /// Oldest first, the order a thread is read in. The list's own messages:
  /// what the row stands for, and what acting on the row acts on.
  final List<MailMessage> messages;

  /// Messages of the thread from another folder, oldest first: your replies
  /// in Sent, shown in the open thread as Outlook's Show Messages from Other
  /// Folders shows them. Never acted on with the row: deleting the thread
  /// from the Inbox leaves what you sent where it is, as Outlook does.
  final List<MailMessage> others;

  /// The whole thread, oldest first: [messages] and [others] together.
  List<MailMessage> get everything => others.isEmpty
      ? messages
      : ([...messages, ...others]..sort((a, b) => a.date.compareTo(b.date)));

  MailMessage get newest => messages.last;
  MailMessage get oldest => messages.first;

  int get length => messages.length;
  bool get isThread => messages.length > 1;

  /// Whether the row opens to show more than one message: a thread, or one
  /// message with your reply from Sent beside it.
  bool get opens => isThread || others.isNotEmpty;

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
///
/// [folded] says whether a row is under a closed bar, and those rows are
/// left out too. It is asked about the message that stands for the row, a
/// thread's newest, because that is what the bar is decided by: an open
/// thread's older replies sit under the thread's bar, not their own.
///
/// A row with a message in [pinned] (by id) sits under the Pinned bar
/// instead, and is left out when [pinnedClosed]. [others] are messages from
/// other folders an open thread shows as well; see [Conversation.others].
List<MailMessage> visibleMessages(
  List<MailMessage> messages, {
  required bool conversations,
  required Set<String> expandedIds,
  required MessageSort sort,
  bool Function(MailMessage row)? folded,
  Set<String> pinned = const {},
  bool pinnedClosed = false,
  Map<String, int> accountRank = const {},
  List<MailMessage> others = const [],
}) {
  bool hidden(List<MailMessage> row, MailMessage lead) =>
      row.any((m) => pinned.contains(m.id))
          ? pinnedClosed
          : (folded != null && folded(lead));
  if (!conversations) {
    if (folded == null && !pinnedClosed) return messages;
    return [
      for (final m in messages)
        if (!hidden([m], m)) m,
    ];
  }
  return [
    for (final c in conversationsInOrder(
      messages,
      sort,
      accountRank: accountRank,
      pinned: pinned,
      others: others,
    ))
      if (hidden(c.messages, c.newest))
        ...const <MailMessage>[]
      else if (!c.opens || !expandedIds.contains(c.id))
        c.newest
      else
        ...c.everything.reversed,
  ];
}

/// [messages] as conversations, in the order the list shows them: by each
/// one's newest message, under [sort], with the threads holding any of
/// [pinned] first. [others] join the threads they belong to; see
/// [groupIntoConversations].
List<Conversation> conversationsInOrder(
  List<MailMessage> messages,
  MessageSort sort, {
  Map<String, int> accountRank = const {},
  Set<String> pinned = const {},
  List<MailMessage> others = const [],
}) {
  final grouped = groupIntoConversations(messages, others: others);
  final sorted = sort == MessageSort.dateNewest
      ? grouped
      : ([...grouped]
        ..sort((a, b) => compareMessages(
              a.newest,
              b.newest,
              sort,
              accountRank: accountRank,
            )));
  if (pinned.isEmpty) return sorted;
  bool isPinned(Conversation c) => c.messages.any((m) => pinned.contains(m.id));
  return [
    for (final c in sorted)
      if (isPinned(c)) c,
    for (final c in sorted)
      if (!isPinned(c)) c,
  ];
}

/// [messages] grouped into conversations, newest conversation first.
///
/// [others] are messages from another folder, your own in Sent, that join
/// a conversation of [messages] they belong to as [Conversation.others],
/// by the same three signals. One that belongs to none is left out: the
/// Inbox does not grow rows for mail you sent. A copy of a message the
/// list holds (sent to yourself) is left out too.
List<Conversation> groupIntoConversations(
  List<MailMessage> messages, {
  List<MailMessage> others = const [],
}) {
  if (messages.isEmpty) return const [];
  final own = {for (final m in messages) m.id};
  if (others.isNotEmpty) {
    final held = {
      for (final m in messages)
        if (m.messageId != null) (m.accountId, m.messageId!),
    };
    final extra = [
      for (final o in others)
        if (!own.contains(o.id) &&
            (o.messageId == null || !held.contains((o.accountId, o.messageId!))))
          o,
    ];
    if (extra.isNotEmpty) {
      // Ordered by the list's own newest message, as without them: a reply
      // just sent does not lift its thread above mail that came in since.
      return [
        for (final c in groupIntoConversations([...messages, ...extra]))
          if (c.messages.any((m) => own.contains(m.id)))
            Conversation(
              [for (final m in c.messages) if (own.contains(m.id)) m],
              others: [for (final m in c.messages) if (!own.contains(m.id)) m],
            ),
      ]..sort((a, b) => b.newest.date.compareTo(a.newest.date));
    }
  }

  // Scoped to the account, as the server's conversation and the subject are
  // below. A reply in the Gmail to a message in the work mailbox, written to
  // both or copied, made one conversation of the two in the unified Inbox,
  // and whatever was done to its row went across: Archive sent the Gmail
  // mail into the work mailbox's Archive and out of Gmail.
  final byMessageId = <(String, String), MailMessage>{
    for (final m in messages)
      if (m.messageId != null) (m.accountId, m.messageId!): m,
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
    final parentMessage = byMessageId[(m.accountId, answered)];
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
