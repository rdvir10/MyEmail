import 'package:flutter/services.dart';

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
String printableMessage(
  MailMessage message,
  MailBody body, {
  required String bodyHtml,
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

  final content = bodyHtml.trim().isNotEmpty
      ? bodyHtml
      : '<pre style="white-space:pre-wrap;font-family:inherit">${esc(body.text)}</pre>';

  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<style>
  body { font-family: sans-serif; font-size: 12pt; color: #111; margin: 0; }
  .head { border-bottom: 1px solid #999; padding-bottom: 8pt; margin-bottom: 12pt; }
  .head h1 { font-size: 16pt; margin: 0 0 8pt; }
  .head table { border-collapse: collapse; font-size: 10.5pt; }
  .head th { text-align: left; padding: 1pt 12pt 1pt 0; font-weight: 600; color: #444; vertical-align: top; }
  .head td { padding: 1pt 0; }
  img { max-width: 100%; }
</style></head>
<body>
<div class="head">
  <h1>${esc(message.subject)}</h1>
  <table>
    <tr><th>From</th><td>${esc(who(message.from))}</td></tr>
    <tr><th>To</th><td>${esc(message.to.map(who).join(', '))}</td></tr>
    <tr><th>Date</th><td>$date</td></tr>
  </table>
</div>
$content
</body></html>''';
}
