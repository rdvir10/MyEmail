import 'dart:math';

import 'package:flutter/services.dart';

import '../../domain/html_safety.dart';
import '../../domain/mail_message.dart';

/// Printing a message, which on Android includes saving it as a PDF: the
/// system's print sheet has "Save as PDF" among its printers.
abstract class MessagePrinter {
  Future<bool> available();

  /// Hand the page to the system's print sheet. True once it has it.
  Future<bool> print({required String title, required String html});
}

class AndroidMessagePrinter implements MessagePrinter {
  const AndroidMessagePrinter();

  static const _channel = MethodChannel('mailtree/print');

  @override
  Future<bool> available() async => true;

  @override
  Future<bool> print({required String title, required String html}) async =>
      await _channel.invokeMethod<bool>('print', {
        'title': title,
        'html': html,
      }) ??
      false;
}

/// Records what would have been printed. Tests, and the browser preview.
class FakeMessagePrinter implements MessagePrinter {
  FakeMessagePrinter({this.supported = true});

  final bool supported;
  final List<({String title, String html})> printed = [];

  @override
  Future<bool> available() async => supported;

  @override
  Future<bool> print({required String title, required String html}) async {
    printed.add((title: title, html: html));
    return true;
  }
}

/// The page a message prints as: a header block the way Outlook prints
/// one — subject, who, to whom, when — then the body as it was, at page
/// width. Plain text goes in a `pre` so its line breaks survive.
///
/// [remoteAllowed] follows what the reading pane shows: without it the page
/// fetches nothing from the network, so printing a message cannot tell its
/// sender it was read, however the pictures are written.
String printableMessage(
  MailMessage message,
  MailBody body, {
  required String bodyHtml,
  bool remoteAllowed = false,
}) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  String who(MailAddress a) =>
      a.name == null || a.name!.trim().isEmpty ? a.email : '${a.name} <${a.email}>';
  final when = message.date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final date =
      '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';

  // No <meta> or <base> from the message: a refresh would send the print
  // WebView to the sender's page and print that instead.
  final content = bodyHtml.trim().isNotEmpty
      ? removeDocumentDirectives(bodyHtml)
      : '<pre style="white-space:pre-wrap;font-family:inherit">${esc(body.text)}</pre>';

  // The message is shut in an element only this page knows the name of.
  // A stray </div> in it closed the last div open, and whatever followed
  // was out in the page, free to be laid over the header. The parser only
  // closes an element on an end tag with its own name, and this one is
  // made up afresh for every print.
  final shut = 'mailtree-message-${_unguessable()}';

  return '''<!doctype html>
<html style=""><head><meta charset="utf-8">
${contentPolicyTag(remoteAllowed: remoteAllowed)}
<meta name="viewport" content="width=device-width">
<style>
${_headerRules(shut)}
  img { max-width: 100%; }
</style></head>
<body style="">
<div class="head">
  <h1>${esc(message.subject)}</h1>
  <table>
    <tr><th>From</th><td>${esc(who(message.from))}</td></tr>
    <tr><th>To</th><td>${esc(message.to.map(who).join(', '))}</td></tr>
    <tr><th>Date</th><td>$date</td></tr>
  </table>
</div>
<$shut>
$content
</$shut>
</body></html>''';
}

/// The page's own rules, which the message's CSS cannot touch.
///
/// The message's styles share the page with the header, and it used to
/// take one rule, `.head{display:none}`, to print a message without its
/// real From and Date, and a little more to draw a fake pair in their
/// place. So:
///
/// - These rules are in a cascade layer, and the first one on the page.
///   Among `!important` rules the first layer beats every later layer and
///   everything outside one, whatever the selector. It has no name, so the
///   message cannot add rules to it.
/// - Everything on the header, the page and its body is put back to the
///   browser's defaults (`all: revert`) before these rules set it, so no
///   property is left for the message to set: not display, not colour, not
///   a transform that slides the header off the paper. `direction` and
///   `unicode-bidi` are not part of `all` and are set by name.
/// - Nothing drawn around them either: no `::before` or `::after` on the
///   header or the page, and no text in the page margins.
/// - The message is a stacking context below the header, and the header is
///   opaque, so nothing the message positions can be laid over it.
///
/// The `style` attribute on `<html>` and `<body>` is there for the same
/// reason. A `<body style="...">` in the message is merged into the page's
/// own body by the parser, but only where the page's body has no such
/// attribute, and an inline `!important` would outrank any layer.
String _headerRules(String shut) {
  const head = 'body > .head';
  String each(List<String> selectors, String pseudo) =>
      [for (final s in selectors) '$s$pseudo'].join(', ');
  const page = ['html', 'body', head, '$head *'];
  const margins = [
    'top-left-corner', 'top-left', 'top-center', 'top-right',
    'top-right-corner', 'bottom-left-corner', 'bottom-left',
    'bottom-center', 'bottom-right', 'bottom-right-corner', 'left-top',
    'left-middle', 'left-bottom', 'right-top', 'right-middle', 'right-bottom',
  ];
  return '''@layer {
  ${page.join(', ')} { all: revert !important; }
  ${each(page, '::before')}, ${each(page, '::after')} { content: none !important; }
  ${each(page, '::first-line')}, ${each(page, '::first-letter')} { all: revert !important; }
  body { margin: 0 !important; font-family: sans-serif !important; font-size: 12pt !important; color: #111 !important; }
  $head { position: relative !important; z-index: 2147483647 !important; background: #fff !important; -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; border-bottom: 1px solid #999 !important; padding-bottom: 8pt !important; margin-bottom: 12pt !important; }
  $head, $head * { direction: ltr !important; unicode-bidi: normal !important; }
  $head h1 { font-size: 16pt !important; margin: 0 0 8pt !important; }
  $head table { border-collapse: collapse !important; font-size: 10.5pt !important; }
  $head th { text-align: left !important; padding: 1pt 12pt 1pt 0 !important; font-weight: 600 !important; color: #444 !important; vertical-align: top !important; }
  $head td { padding: 1pt 0 !important; }
  body > $shut { display: block !important; position: relative !important; z-index: 0 !important; isolation: isolate !important; }
  @page { ${[for (final m in margins) '@$m { content: none !important; }'].join(' ')} }
}''';
}

/// Twelve random hex digits.
String _unguessable() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 6; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}
