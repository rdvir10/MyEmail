/// Senders whose pictures are loaded without asking.
///
/// Pictures in mail are fetched from the sender's server as the message
/// opens, which tells them when it was read, on what, and roughly from
/// where. That is why they are blocked by default. It is also why the
/// exception is per sender rather than a single switch: a shop whose mail
/// *is* its pictures is worth trusting; the rest are not.
///
/// An entry is either an address (`sales@example.com`) or a whole domain,
/// written with a leading `@` (`@example.com`) so the two cannot be
/// mistaken for each other. A domain entry earns its place with mail from
/// shops and newsletters, which send from a different address every time.
library;

/// The entry that trusts one address.
String trustAddress(String email) => email.trim().toLowerCase();

/// The entry that trusts everyone at an address's domain, or null when
/// there is no domain to take.
String? trustDomain(String email) {
  final at = email.lastIndexOf('@');
  if (at < 0 || at == email.length - 1) return null;
  return '@${email.substring(at + 1).trim().toLowerCase()}';
}

/// Whether [email] is covered by [trusted], by name or by domain.
bool isSenderTrusted(Set<String> trusted, String? email) {
  if (email == null || email.trim().isEmpty) return false;
  if (trusted.contains(trustAddress(email))) return true;
  final domain = trustDomain(email);
  return domain != null && trusted.contains(domain);
}

/// How an entry reads in a list: a domain says so, an address is itself.
String describeTrustEntry(String entry) =>
    entry.startsWith('@') ? 'Everyone at ${entry.substring(1)}' : entry;

/// Trusted entries in the order they should be shown: domains first,
/// since they cover more, then addresses, each alphabetically.
List<String> sortedTrustEntries(Set<String> trusted) {
  final list = trusted.toList()
    ..sort((a, b) {
      final aDomain = a.startsWith('@');
      if (aDomain != b.startsWith('@')) return aDomain ? -1 : 1;
      return a.compareTo(b);
    });
  return list;
}
