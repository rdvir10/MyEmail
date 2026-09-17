import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../imap/imap_mapping.dart';

/// Builds the HTML a compose window opens with.
///
/// The quoted original is part of the same document as the new text, not a
/// separate block appended at send time, because the whole point of the
/// WebView editor is that the caret can go inside the quote. That means the
/// original has to be sanitised here: it is about to live in an editable
/// document with JavaScript available to the bridge.

/// The `mailtree-` class prefix below stays after the rename to MyEmail.
/// These class names are written into messages that have already been sent and
/// drafts that are already saved on the server; renaming them would leave a
/// reopened draft's quote unstyled for no visible gain.

/// Where the caret should start, marked so the editor can find it.
const caretMarker = '<span id="mailtree-caret"></span>';

/// An empty line to type into, the caret marker, then the signature, then the
/// quoted original. Outlook's shape: you write above the quote.
String buildComposeHtml({
  required ComposeKind kind,
  MailMessage? original,
  String? originalHtml,
  String? originalText,
  String signatureHtml = '',
  bool signatureOnReply = true,
}) {
  final buffer = StringBuffer('<p>$caretMarker<br></p>');

  final wantsSignature = signatureHtml.trim().isNotEmpty &&
      (kind == ComposeKind.newMessage || signatureOnReply);
  if (wantsSignature) {
    buffer.write('<div class="mailtree-signature">$signatureHtml</div>');
  }

  if (kind != ComposeKind.newMessage && original != null) {
    buffer
      ..write('<div class="mailtree-quote">')
      ..write('<p>${_attributionLine(kind, original)}</p>')
      ..write('<blockquote style="margin:0 0 0 8px;padding-left:12px;'
          'border-left:2px solid #ccc">')
      ..write(quotedOriginal(html: originalHtml, text: originalText))
      ..write('</blockquote></div>');
  }

  return buffer.toString();
}

/// "On Mon 14 Sep 2026 at 09:41, Dana Levi wrote:"
String _attributionLine(ComposeKind kind, MailMessage original) {
  final who = _escape(original.from.display);
  if (kind == ComposeKind.forward) {
    return '---------- Forwarded message ----------<br>'
        'From: $who &lt;${_escape(original.from.email)}&gt;<br>'
        'Subject: ${_escape(original.subject)}';
  }
  final d = original.date.toLocal();
  final date = '${d.day}/${_two(d.month)}/${d.year} at '
      '${_two(d.hour)}:${_two(d.minute)}';
  return 'On $date, $who wrote:';
}

/// The original as safe, editable HTML.
///
/// This is not the reading pane's blocking pass: the message is going into an
/// editable document whose bridge needs JavaScript, so anything executable has
/// to be gone rather than merely inert. Scripts, event handlers,
/// `javascript:` URLs, forms, iframes and objects are removed outright.
/// Remote images are left addressable but neutralised, so the quote looks
/// right without the act of replying phoning home to the sender.
String quotedOriginal({String? html, String? text}) {
  if (html != null && html.trim().isNotEmpty) {
    return sanitiseForEditing(html);
  }
  final plain = (text ?? '').trim();
  if (plain.isEmpty) return '<p></p>';
  return plain
      .split('\n')
      .map((line) => '<p>${_escape(line)}</p>')
      .join();
}

/// Strip everything executable from HTML that is about to become editable.
String sanitiseForEditing(String html) {
  var s = html;

  // Whole elements whose content is code or an embedded document.
  for (final tag in ['script', 'style', 'iframe', 'object', 'embed', 'form']) {
    s = s.replaceAll(
      RegExp('<$tag\\b[^>]*>[\\s\\S]*?</$tag>', caseSensitive: false),
      '',
    );
    s = s.replaceAll(RegExp('<$tag\\b[^>]*/?>', caseSensitive: false), '');
  }

  // Inline event handlers: on*="..." / on*='...' / on*=bare.
  s = s.replaceAll(
    RegExp(r'''\son[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''',
        caseSensitive: false),
    '',
  );

  // Script-bearing URL schemes, in either attribute.
  s = s.replaceAll(
    RegExp(r'''\b(href|src)\s*=\s*(["']?)\s*(javascript|vbscript):[^"'\s>]*\2''',
        caseSensitive: false),
    '',
  );

  // `data:` is a phishing vector in a link, but an inline image is exactly
  // what a data: src is for and mail uses it for embedded logos. Drop it from
  // href only; stripping it from src would blank legitimate images.
  s = s.replaceAll(
    RegExp(r'''\bhref\s*=\s*(["']?)\s*data:[^"'\s>]*\1''',
        caseSensitive: false),
    '',
  );

  // Remote images: keep the tag so the layout survives, drop the fetch.
  s = s.replaceAllMapped(
    RegExp(
      r'''(?<![-\w])(src|srcset|poster|background)\s*=\s*(["']?)(\s*(?:https?:)?//)''',
      caseSensitive: false,
    ),
    (m) => 'data-blocked-${m[1]!.toLowerCase()}=${m[2]}${m[3]}',
  );

  return s;
}

/// The plain-text alternative for the sent message, derived from the editor's
/// HTML so the two halves say the same thing.
String plainTextFromHtml(String html) => htmlToText(html);

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _two(int v) => v.toString().padLeft(2, '0');
