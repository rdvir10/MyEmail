import 'package:flutter/foundation.dart';

/// How a mailing list says to leave it, from the headers it puts on every
/// message: `List-Unsubscribe` (RFC 2369) names the ways, an email address
/// to write to and a web address, and `List-Unsubscribe-Post` (RFC 8058)
/// says the web address takes a one-click request. Outlook's and Gmail's
/// Unsubscribe buttons are both made from these.
@immutable
class UnsubscribeOptions {
  const UnsubscribeOptions({this.oneClick, this.mailto, this.web});

  /// A web address that unsubscribes when sent the one-click request:
  /// done in place, with nothing for the person to fill in.
  final Uri? oneClick;

  /// An address to write to, as a mailto: link, with the subject and words
  /// the list wants, where it gave any.
  final Uri? mailto;

  /// The list's own page for leaving it, to be opened in the browser.
  final Uri? web;

  bool get isEmpty => oneClick == null && mailto == null && web == null;

  /// The way the button takes, best first: one click where the list allows
  /// it, then the email, then the page. The email beats the page because
  /// it is done from here; the page wants the person to finish there.
  UnsubscribeWay get way => oneClick != null
      ? UnsubscribeWay.oneClick
      : mailto != null
          ? UnsubscribeWay.email
          : UnsubscribeWay.page;

  /// From the two headers' values, as the message carries them, or null
  /// where they name no way out: no header, or nothing in it a mail app
  /// can act on.
  static UnsubscribeOptions? parse(String? listUnsubscribe, String? post) {
    if (listUnsubscribe == null) return null;
    Uri? mailto;
    Uri? web;
    for (final uri in unsubscribeUris(listUnsubscribe)) {
      switch (uri.scheme) {
        case 'mailto' when uri.path.contains('@'):
          mailto ??= uri;
        case 'https' || 'http' when uri.host.isNotEmpty:
          // https before http: a list giving both means the first, but a
          // plain http one may be all it has.
          if (web == null || (web.scheme == 'http' && uri.scheme == 'https')) {
            web = uri;
          }
      }
    }
    // One click only over https, as RFC 8058 has it: the request carries
    // nothing secret, but it does say this address reads its mail.
    final oneClick = web != null &&
            web.scheme == 'https' &&
            post != null &&
            post.replaceAll(RegExp(r'\s'), '').toLowerCase() ==
                'list-unsubscribe=one-click'
        ? web
        : null;
    final options = UnsubscribeOptions(oneClick: oneClick, mailto: mailto, web: web);
    return options.isEmpty ? null : options;
  }

  @override
  bool operator ==(Object other) =>
      other is UnsubscribeOptions &&
      other.oneClick == oneClick &&
      other.mailto == mailto &&
      other.web == web;

  @override
  int get hashCode => Object.hash(oneClick, mailto, web);

  @override
  String toString() => 'UnsubscribeOptions(oneClick: $oneClick, '
      'mailto: $mailto, web: $web)';
}

enum UnsubscribeWay { oneClick, email, page }

/// The addresses in a `List-Unsubscribe` value, in order: each in angle
/// brackets, commas between, and the folding a long header gets (a line
/// break and a space, even inside the brackets) taken out.
List<Uri> unsubscribeUris(String value) {
  final found = <Uri>[];
  for (final match in RegExp(r'<([^>]*)>').allMatches(value)) {
    final text = match.group(1)!.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri.tryParse(text);
    // Dart gives the scheme in lower case, however the list wrote it.
    if (uri != null && uri.scheme.isNotEmpty) found.add(uri);
  }
  return found;
}
