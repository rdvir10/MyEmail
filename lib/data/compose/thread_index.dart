import 'dart:convert';

/// The `Thread-Index` of a reply to a message whose own conversation index
/// is [parentBase64], as Outlook writes one: the parent's index with a
/// five-byte block for this reply after it (MS-OXOMSG 2.2.1.3,
/// PidTagConversationIndex). Null where the parent's is not one.
///
/// What it is for: Exchange files a message in a conversation by the first
/// 22 bytes of this, the header the whole thread shares, and not by
/// In-Reply-To. A reply MyEmail sent through Graph without it started a
/// conversation of its own, in Outlook as much as here: "Re: A teacher in
/// Iceland" and the message it answered had two different conversation ids.
///
/// The block: one bit saying how the time is scaled, 31 bits of time since
/// the thread began, then four bits random and four of sequence. Only the
/// header decides the conversation; the block orders replies within it.
String? replyThreadIndex(String parentBase64, DateTime now, {int random = 0}) {
  final List<int> parent;
  try {
    parent = base64Decode(parentBase64.trim());
  } on FormatException {
    return null;
  }
  // A header is 22 bytes and starts with 1; each reply adds 5.
  if (parent.length < 22 || (parent.length - 22) % 5 != 0 || parent[0] != 1) {
    return null;
  }
  // FILETIME, in 100-nanosecond steps since 1601.
  final nowFiletime =
      (now.toUtc().microsecondsSinceEpoch + 11644473600000000) * 10;
  // The header keeps the top 40 bits of the time the thread began.
  var began = 0;
  for (var i = 1; i <= 5; i++) {
    began = (began << 8) | parent[i];
  }
  began <<= 24;
  final delta = nowFiletime > began ? nowFiletime - began : 0;
  final block = (delta >> 49) == 0
      ? (delta >> 18) & 0x7FFFFFFF
      : 0x80000000 | ((delta >> 23) & 0x7FFFFFFF);
  return base64Encode([
    ...parent,
    (block >> 24) & 0xFF,
    (block >> 16) & 0xFF,
    (block >> 8) & 0xFF,
    block & 0xFF,
    // Four bits random, four of sequence (left at 0).
    (random & 0x0F) << 4,
  ]);
}

/// The subject a thread goes by: [subject] without the Re:, Fw: and the
/// like in front, as Outlook's `Thread-Topic` has it.
String threadTopic(String subject) {
  final prefix = RegExp(
    r'^\s*(re|aw|antwort|sv|vs|fwd?|wg|tr|rif|res|enc)\s*(\[\d+\])?\s*:\s*',
    caseSensitive: false,
  );
  var s = subject.trim();
  while (true) {
    final stripped = s.replaceFirst(prefix, '');
    if (stripped == s) return s;
    s = stripped;
  }
}
