import 'mail_message.dart';

/// One person who could be meant, while an address is being typed.
class AddressSuggestion {
  const AddressSuggestion({
    required this.email,
    this.name,
    this.fromContacts = false,
    this.timesSeen = 0,
    this.timesSent = 0,
    this.weight = 0,
  });

  final String email;
  final String? name;

  /// From an address book rather than from mail already sent or received:
  /// the device's, or an account's own online (Google contacts, Microsoft's
  /// people and directory). Shown with a different icon, and never dropped
  /// in favour of a mail-history entry for the same address, because the
  /// address book is where a person's name is spelled the way they want it.
  final bool fromContacts;

  /// How many cached messages this address appeared on, each message once
  /// however many folders hold it. Only meaningful for mail-history
  /// entries.
  final int timesSeen;

  /// How many of those were written from one of the accounts here: mail
  /// sent to this person, not mail they sent. What says a person is
  /// someone written to, where a newsletter that arrives daily is only
  /// seen a lot.
  final int timesSent;

  /// [timesSent] with each message counting for less the older it is: a
  /// message sent today counts 1, one a month old a half, one a year old
  /// under a tenth. Ranks the people written to lately above the ones
  /// written to a lot, long ago. See [recencyWeight].
  final double weight;

  MailAddress get asAddress => MailAddress(email: email, name: name);

  /// What goes into the field when this is chosen.
  String get formatted => formatRecipient(name, email);
}

/// One recipient as a recipients field shows it.
///
/// A name holding a comma, semicolon, angle bracket or quote is quoted, as
/// RFC 5322 has it, so reading the field back finds one person and not two.
String formatRecipient(String? name, String email) {
  if (name == null || name.isEmpty) return email;
  if (!RegExp(r'[,;<>"\\]').hasMatch(name)) return '$name <$email>';
  final escaped = name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped" <$email>';
}

/// Where each recipient in a field ends: every comma or semicolon that is
/// not inside a quoted name or an `<address>`.
///
/// `"Levi, Dana" <dana@example.com>` is one person. Split on every comma it
/// was two, `"Levi"` and `Dana" <dana@example.com>`, and the first was
/// refused as not looking like an address.
List<int> recipientSeparators(String text) {
  final at = <int>[];
  var quoted = false;
  var angled = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == '<') {
      angled = true;
    } else if (c == '>') {
      angled = false;
    } else if (!angled && (c == ',' || c == ';')) {
      at.add(i);
    }
  }
  return at;
}

/// A recipients field cut into one piece per recipient, untrimmed.
List<String> splitRecipients(String text) {
  final pieces = <String>[];
  var start = 0;
  for (final cut in recipientSeparators(text)) {
    pieces.add(text.substring(start, cut));
    start = cut + 1;
  }
  pieces.add(text.substring(start));
  return pieces;
}

int _lastSeparator(String text) {
  final all = recipientSeparators(text);
  return all.isEmpty ? -1 : all.last;
}

/// The part of a recipients field that is still being typed: whatever
/// follows the last comma or semicolon, trimmed, without an opening quote.
String lastRecipientToken(String text) {
  final cut = _lastSeparator(text);
  final token = (cut < 0 ? text : text.substring(cut + 1)).trim();
  return token.startsWith('"') ? token.substring(1) : token;
}

/// The field's text with the token being typed replaced by [chosen], and a
/// comma ready for the next one — which is what typing into a recipients
/// field means: one name after another.
String completeLastRecipient(String text, AddressSuggestion chosen) {
  final cut = _lastSeparator(text);
  final kept = cut < 0 ? '' : text.substring(0, cut + 1);
  final lead = kept.isEmpty ? '' : '$kept ';
  return '$lead${chosen.formatted}, ';
}

/// The addresses already written into a recipients field, lower-cased,
/// leaving out the one still being typed after the last comma. Not offered
/// again: a person on the line once is the person meant.
Set<String> recipientsAlreadyIn(String text) {
  final pieces = splitRecipients(text);
  return {
    for (final piece in pieces.take(pieces.length - 1)) ?_addressOf(piece),
  };
}

String? _addressOf(String piece) {
  final angled = RegExp(r'<([^<>]+)>\s*$').firstMatch(piece);
  final email = (angled?.group(1) ?? piece).trim().toLowerCase();
  return email.contains('@') ? email : null;
}

/// Everyone who matches what has been typed, best first.
///
/// [contacts] is the address books' answer for the same query — the
/// device's, and each account's online — and is taken as already matching:
/// an online search matches loosely, "tiler" finding Tyler, and a person
/// it found is not dropped for failing a stricter test here. [history] is
/// everyone on any cached message and is filtered here, so the two can be
/// combined without the history having to be queried through an address
/// book's filter.
///
/// The rules, each of which is a way this reads wrongly:
///
///  * A match is on the start of the name, of any word in the name, of the
///    address, of any part of the address before the @, or of the domain.
///    "dv" finds Ron Dvir and ron.dvir@…; "hadco" finds everyone at
///    hadco.com; "vir" finds neither, because prefixes are what people
///    type.
///  * One entry per address, case-insensitively. The address book's entry
///    wins over the history's, since its spelling of the name was chosen
///    by the person rather than by whichever mail client wrote the header.
///  * People written to first, most lately and most often first. Then the
///    address book, then everyone else who has written, by how often. A
///    newsletter that arrives every day has been seen more than anyone,
///    and written to by nobody.
///  * No-reply addresses are left out unless written to or in an address
///    book: nobody means them.
///  * Nobody in [exclude], which is who is in the field already.
///  * At most [limit], because a list of forty under the field is a wall,
///    and one more letter narrows it better than scrolling would.
List<AddressSuggestion> rankSuggestions(
  String query, {
  required List<AddressSuggestion> contacts,
  required List<AddressSuggestion> history,
  Set<String> exclude = const {},
  int limit = 8,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];

  final byEmail = <String, AddressSuggestion>{};
  for (final c in contacts) {
    final key = c.email.trim().toLowerCase();
    if (key.isEmpty || exclude.contains(key) || byEmail.containsKey(key)) {
      continue;
    }
    byEmail[key] = AddressSuggestion(
      email: c.email.trim(),
      name: c.name,
      fromContacts: true,
      timesSeen: c.timesSeen,
      timesSent: c.timesSent,
      weight: c.weight,
    );
  }
  for (final h in history) {
    final key = h.email.toLowerCase();
    if (key.isEmpty || exclude.contains(key) || !suggestionMatches(h, needle)) {
      continue;
    }
    final existing = byEmail[key];
    if (existing != null) {
      // Keep the address book's spelling; take the history's counts, which
      // say how often this person actually comes up.
      byEmail[key] = AddressSuggestion(
        email: existing.email,
        name: existing.name ?? h.name,
        fromContacts: existing.fromContacts,
        timesSeen: existing.timesSeen + h.timesSeen,
        timesSent: existing.timesSent + h.timesSent,
        weight: existing.weight + h.weight,
      );
      continue;
    }
    if (h.timesSent == 0 && isNoReplyAddress(key)) continue;
    byEmail[key] = h;
  }

  final ranked = byEmail.values.toList()..sort(_bestFirst);
  return ranked.take(limit).toList();
}

int _bestFirst(AddressSuggestion a, AddressSuggestion b) {
  final aWritten = a.timesSent > 0;
  final bWritten = b.timesSent > 0;
  if (aWritten != bWritten) return aWritten ? -1 : 1;
  if (aWritten) {
    if (a.weight != b.weight) return b.weight.compareTo(a.weight);
    if (a.timesSent != b.timesSent) return b.timesSent.compareTo(a.timesSent);
  }
  if (a.fromContacts != b.fromContacts) return a.fromContacts ? -1 : 1;
  if (a.timesSeen != b.timesSeen) return b.timesSeen.compareTo(a.timesSeen);
  return (a.name ?? a.email).toLowerCase().compareTo(
    (b.name ?? b.email).toLowerCase(),
  );
}

/// Whether [s] is what someone typing [needle] could mean.
bool suggestionMatches(AddressSuggestion s, String needle) {
  final email = s.email.toLowerCase();
  if (email.startsWith(needle)) return true;
  if (_addressWords(email).any((w) => w.startsWith(needle))) return true;
  final name = s.name?.toLowerCase();
  if (name == null) return false;
  if (name.startsWith(needle)) return true;
  return name.split(RegExp(r'\s+')).any((word) => word.startsWith(needle));
}

/// Where in an address someone might start typing, besides its start: each
/// part of what comes before the @ ("dvir" in ron.dvir@…), the domain
/// whole, and each name in the domain but the last ("hadco" in
/// mail.hadco.com). Not the last: "co" would find every address in .com.
List<String> _addressWords(String email) {
  final at = email.lastIndexOf('@');
  if (at < 0) return const [];
  final domain = email.substring(at + 1);
  final labels = domain.split('.');
  return [
    ...email.substring(0, at).split(RegExp(r'[._+-]')),
    domain,
    ...labels.take(labels.length > 1 ? labels.length - 1 : labels.length),
  ];
}

/// An address nobody writes to: no-reply, do-not-reply, a mailer daemon,
/// a bounce. Written with dots, dashes or underscores, or none.
bool isNoReplyAddress(String email) {
  final at = email.lastIndexOf('@');
  final local = (at < 0 ? email : email.substring(0, at))
      .toLowerCase()
      .replaceAll(RegExp(r'[._-]'), '');
  return local.contains('noreply') ||
      local.contains('donotreply') ||
      local == 'mailerdaemon' ||
      local == 'postmaster' ||
      local.startsWith('bounce');
}

/// How much one message counts toward [AddressSuggestion.weight], by its
/// age at [now]: 1 today, a half at a month, a tenth at nine months.
/// Falls slowly on purpose: someone written to every week for years is
/// still someone written to after a quiet month.
///
/// The cache's SQL computes the same thing in place; see
/// `DriftCacheStore.addressHistory`.
double recencyWeight(DateTime date, DateTime now) {
  final days = now.difference(date).inSeconds / Duration.secondsPerDay;
  return 30 / (30 + (days < 0 ? 0 : days));
}

/// One address on one cached message. [sent] is whether one of the
/// accounts here wrote the message, and the address is among those it was
/// written to.
///
/// One per message, not per copy: Gmail keeps a message in Inbox, All Mail
/// and under each label, and the caller counts it once.
typedef AddressSeen = ({MailAddress address, DateTime date, bool sent});

/// The address book everyone on the cached messages amounts to: each
/// address once, with the name most recently seen for it, how many times
/// it was seen, and how many of those were messages written to it from
/// here, weighed by age as [recencyWeight] has it.
List<AddressSuggestion> historyFrom(
  Iterable<AddressSeen> seen, {
  required DateTime now,
}) {
  final people = <String, _Tally>{};
  for (final s in seen) {
    final email = s.address.email.trim();
    final key = email.toLowerCase();
    if (key.isEmpty || !key.contains('@')) continue;
    final tally = people.putIfAbsent(key, () => _Tally(email));
    if (s.date.isAfter(tally.newest)) {
      tally
        ..newest = s.date
        ..email = email;
    }
    final name = s.address.name?.trim();
    if (name != null &&
        name.isNotEmpty &&
        (tally.namedAt == null || s.date.isAfter(tally.namedAt!))) {
      tally
        ..name = name
        ..namedAt = s.date;
    }
    tally.seen++;
    if (s.sent) {
      tally
        ..sent += 1
        ..weight += recencyWeight(s.date, now);
    }
  }
  return [
    for (final t in people.values)
      AddressSuggestion(
        email: t.email,
        name: t.name,
        timesSeen: t.seen,
        timesSent: t.sent,
        weight: t.weight,
      ),
  ];
}

class _Tally {
  _Tally(this.email);

  String email;
  String? name;
  DateTime? namedAt;
  DateTime newest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  int seen = 0;
  int sent = 0;
  double weight = 0;
}
