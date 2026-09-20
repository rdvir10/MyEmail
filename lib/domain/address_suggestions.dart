import 'mail_message.dart';

/// One person who could be meant, while an address is being typed.
class AddressSuggestion {
  const AddressSuggestion({
    required this.email,
    this.name,
    this.fromContacts = false,
    this.timesSeen = 0,
  });

  final String email;
  final String? name;

  /// From the device's address book rather than from mail already sent or
  /// received. Shown with a different icon, and never dropped in favour of
  /// a mail-history entry for the same address, because the address book
  /// is where a person's name is spelled the way they want it.
  final bool fromContacts;

  /// How many cached messages this address appeared on. Only meaningful
  /// for mail-history entries; ranks the people written to most above the
  /// ones written to once.
  final int timesSeen;

  MailAddress get asAddress => MailAddress(email: email, name: name);

  /// What goes into the field when this is chosen.
  String get formatted => name == null || name!.isEmpty
      ? email
      : '$name <$email>';
}

/// The part of a recipients field that is still being typed: whatever
/// follows the last comma or semicolon, trimmed.
String lastRecipientToken(String text) {
  final cut = text.lastIndexOf(RegExp(r'[,;]'));
  return (cut < 0 ? text : text.substring(cut + 1)).trim();
}

/// The field's text with the token being typed replaced by [chosen], and a
/// comma ready for the next one — which is what typing into a recipients
/// field means: one name after another.
String completeLastRecipient(String text, AddressSuggestion chosen) {
  final cut = text.lastIndexOf(RegExp(r'[,;]'));
  final kept = cut < 0 ? '' : text.substring(0, cut + 1);
  final lead = kept.isEmpty ? '' : '$kept ';
  return '$lead${chosen.formatted}, ';
}

/// Everyone who matches what has been typed, best first.
///
/// [contacts] is the address book's answer for the same query and is taken
/// as already matching. [history] is everyone on any cached message and is
/// filtered here, so the two can be combined without the history having to
/// be queried through the address book's filter.
///
/// The rules, each of which is a way this reads wrongly:
///
///  * A match is on the start of the name, of any word in the name, or of
///    the address. "dv" finds Ron Dvir; "ron" finds him too; "vir" does
///    not, because prefixes are what people type.
///  * One entry per address, case-insensitively. The address book's entry
///    wins over the history's, since its spelling of the name was chosen
///    by the person rather than by whichever mail client wrote the header.
///  * Contacts first, then history by how often the address was seen, then
///    by name. A person in the address book is a person, not a mailing list
///    that happened to write a lot.
///  * At most [limit], because a list of forty under the field is a wall,
///    and one more letter narrows it better than scrolling would.
List<AddressSuggestion> rankSuggestions(
  String query, {
  required List<AddressSuggestion> contacts,
  required List<AddressSuggestion> history,
  int limit = 8,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];

  final byEmail = <String, AddressSuggestion>{};
  for (final c in contacts) {
    final key = c.email.toLowerCase();
    if (key.isEmpty || byEmail.containsKey(key)) continue;
    byEmail[key] = AddressSuggestion(
      email: c.email,
      name: c.name,
      fromContacts: true,
      timesSeen: c.timesSeen,
    );
  }
  for (final h in history) {
    final key = h.email.toLowerCase();
    if (key.isEmpty || !suggestionMatches(h, needle)) continue;
    final existing = byEmail[key];
    if (existing != null) {
      // Keep the address book's spelling; take the history's count, which
      // says how often this person actually comes up.
      byEmail[key] = AddressSuggestion(
        email: existing.email,
        name: existing.name ?? h.name,
        fromContacts: existing.fromContacts,
        timesSeen: existing.timesSeen + h.timesSeen,
      );
      continue;
    }
    byEmail[key] = h;
  }

  final ranked = byEmail.values.toList()
    ..sort((a, b) {
      if (a.fromContacts != b.fromContacts) return a.fromContacts ? -1 : 1;
      if (a.timesSeen != b.timesSeen) return b.timesSeen.compareTo(a.timesSeen);
      return (a.name ?? a.email).toLowerCase().compareTo(
            (b.name ?? b.email).toLowerCase(),
          );
    });
  return ranked.take(limit).toList();
}

/// Whether [s] is what someone typing [needle] could mean.
bool suggestionMatches(AddressSuggestion s, String needle) {
  if (s.email.toLowerCase().startsWith(needle)) return true;
  final name = s.name?.toLowerCase();
  if (name == null) return false;
  if (name.startsWith(needle)) return true;
  return name.split(RegExp(r'\s+')).any((word) => word.startsWith(needle));
}

/// The address book everyone on the cached messages amounts to: each
/// address once, with the name most recently seen for it and a count of how
/// often it appeared. [messages] is newest first, as the cache hands it
/// over, which is what makes "most recent name" the first one met.
List<AddressSuggestion> historyFrom(Iterable<MailAddress> seen) {
  final counts = <String, int>{};
  final names = <String, String?>{};
  final emails = <String, String>{};
  for (final a in seen) {
    final key = a.email.trim().toLowerCase();
    if (key.isEmpty || !key.contains('@')) continue;
    counts[key] = (counts[key] ?? 0) + 1;
    emails.putIfAbsent(key, () => a.email.trim());
    if (!names.containsKey(key) && a.name != null && a.name!.trim().isNotEmpty) {
      names[key] = a.name!.trim();
    }
  }
  return [
    for (final key in counts.keys)
      AddressSuggestion(
        email: emails[key]!,
        name: names[key],
        timesSeen: counts[key]!,
      ),
  ];
}
