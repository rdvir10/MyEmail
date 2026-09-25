import 'mail_message.dart';

/// The folded line under a sender, e.g. "To: Dana Cohen, Sam Levi +7  ·  CC 2".
///
/// As many names as [fits] allows, then how many more there are. Names come
/// from To; a message sent only to copied people names those instead. At
/// least one name always, even if the caller has to cut it short: "To: +9"
/// says nothing about the message at all.
///
/// [fits] is asked about longer and longer lines and stops at the first
/// that does not fit, so a list of two hundred costs a few measurements,
/// not two hundred.
String recipientSummary(
  List<MailAddress> to,
  List<MailAddress> cc, {
  required bool Function(String line) fits,
}) {
  final named = to.isNotEmpty ? to : cc;
  final label = to.isNotEmpty ? 'To' : 'CC';
  if (named.isEmpty) return '';

  String line(int shown) {
    final names = named.take(shown).map((a) => a.display).join(', ');
    final rest = named.length - shown;
    final first = rest > 0 ? '$label: $names +$rest' : '$label: $names';
    return to.isNotEmpty && cc.isNotEmpty
        ? '$first  ·  CC ${cc.length}'
        : first;
  }

  var best = line(1);
  for (var shown = 2; shown <= named.length; shown++) {
    final longer = line(shown);
    if (!fits(longer)) break;
    best = longer;
  }
  return best;
}
