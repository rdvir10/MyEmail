import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

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
/// [typedHtml] is for a reply written where there is no editor — the
/// notification shade — and takes the place of the empty line the caret
/// would have gone on. Everything under it is the same either way.
String buildComposeHtml({
  required ComposeKind kind,
  MailMessage? original,
  String? originalHtml,
  String? originalText,
  String signatureHtml = '',
  bool signatureOnReply = true,
  String typedHtml = '',
}) {
  final buffer = StringBuffer(
    typedHtml.isEmpty ? '<p>$caretMarker<br></p>' : typedHtml,
  );

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
///
/// The HTML is parsed, the way the WebView will parse it, and rebuilt from
/// what is known to be safe: an allow-list of elements and attributes.
/// Anything else is either removed with its contents (scripts, styles,
/// embedded documents, forms, `<meta>`, `<base>`, `<link>`, SVG and MathML)
/// or unwrapped so its text survives (unknown tags such as Office's `<o:p>`).
///
/// This used to be a set of regular expressions, and they were bypassed:
/// `<img src="x"onerror=...>` and `<svg/onload=...>` carry a handler with no
/// space before it, which the browser accepts and the pattern did not, and a
/// `<meta http-equiv=refresh>` could replace the whole editor with a page of
/// the sender's. Both let a received message send mail from the account the
/// moment Reply was tapped. A parser sees attributes the way the browser
/// does, so there is no spelling of a handler it can miss.
///
/// Links keep http, https, mailto and tel targets only. Images keep inline
/// `data:image/` and `cid:` sources; remote ones are renamed to
/// `data-blocked-src` so the layout survives without the act of replying
/// telling the sender. `url(...)` in inline styles is neutralised for the
/// same reason.
///
/// [ownDraft] is for a draft reopened from the Drafts folder: the same
/// cleaning, except remote pictures keep their `src`. They are the writer's
/// own, and renaming them would send them to the recipients broken. The
/// editor's policy still stops them loading while it is open.
String sanitiseForEditing(String html, {bool ownDraft = false}) {
  final fragment = html_parser.parseFragment(html);
  _cleanChildren(fragment, keepRemoteImages: ownDraft);
  return fragment.outerHtml;
}

/// Removed together with everything inside them.
const _dropped = {
  'script', 'style', 'noscript', 'template', 'iframe', 'frame', 'frameset',
  'object', 'embed', 'applet', 'param', 'form', 'input', 'button', 'select',
  'option', 'optgroup', 'textarea', 'datalist', 'output', 'meta', 'base',
  'link', 'title', 'head', 'audio', 'video', 'source', 'track', 'canvas',
  'map', 'area', 'portal', 'dialog', 'slot',
};

/// Kept as they are, less any attribute not on [_attributes].
const _elements = {
  'a', 'abbr', 'address', 'article', 'aside', 'b', 'bdi', 'bdo', 'big',
  'blockquote', 'br', 'caption', 'center', 'cite', 'code', 'col', 'colgroup',
  'dd', 'del', 'details', 'dfn', 'div', 'dl', 'dt', 'em', 'figcaption',
  'figure', 'font', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header',
  'hr', 'i', 'img', 'ins', 'kbd', 'li', 'main', 'mark', 'nav', 'ol', 'p',
  'pre', 'q', 's', 'samp', 'section', 'small', 'span', 'strike', 'strong',
  'sub', 'summary', 'sup', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead',
  'time', 'tr', 'tt', 'u', 'ul', 'var', 'wbr',
};

/// Presentation attributes mail actually uses. No `id`: the editor finds its
/// caret by id, and a quote must not be able to move it.
const _attributes = {
  'abbr', 'align', 'alt', 'bgcolor', 'border', 'cellpadding', 'cellspacing',
  'class', 'color', 'colspan', 'datetime', 'dir', 'face', 'headers', 'height',
  'hspace', 'lang', 'name', 'nowrap', 'reversed', 'rowspan', 'scope', 'size',
  'span', 'start', 'style', 'summary', 'title', 'type', 'valign', 'value',
  'vspace', 'width',
  // Written by this function on an earlier pass, so a reopened draft keeps
  // its blocked pictures in place.
  'data-blocked-src', 'data-blocked-srcset', 'data-blocked-background',
  'data-blocked-poster',
};

const _linkSchemes = {'http', 'https', 'mailto', 'tel'};

void _cleanChildren(dom.Node parent, {required bool keepRemoteImages}) {
  for (final node in parent.nodes.toList()) {
    if (node is dom.Element) {
      _cleanElement(node, keepRemoteImages: keepRemoteImages);
    } else if (node is! dom.Text) {
      // Comments and anything else that is not text or an element. A comment
      // is invisible, and was the hiding place for the SMTP injection.
      node.remove();
    }
  }
}

void _cleanElement(dom.Element el, {required bool keepRemoteImages}) {
  final name = (el.localName ?? '').toLowerCase();
  final foreign = el.namespaceUri != null &&
      el.namespaceUri != 'http://www.w3.org/1999/xhtml';
  if (foreign || _dropped.contains(name)) {
    el.remove();
    return;
  }

  _cleanChildren(el, keepRemoteImages: keepRemoteImages);

  if (!_elements.contains(name)) {
    // Keep the words, lose the tag.
    final parent = el.parentNode;
    if (parent == null) return;
    for (final child in el.nodes.toList()) {
      parent.insertBefore(child, el);
    }
    el.remove();
    return;
  }

  final kept = <Object, String>{};
  el.attributes.forEach((key, value) {
    final attr = key.toString().toLowerCase();
    if (attr.startsWith('on')) return;
    if (attr == 'href') {
      if (name == 'a' && _isAllowedLink(value)) kept['href'] = value;
      return;
    }
    if (attr == 'src' || attr == 'srcset' || attr == 'background' ||
        attr == 'poster') {
      final safe = _imageSource(attr, value,
          onImage: name == 'img', keepRemote: keepRemoteImages);
      if (safe != null) kept[safe] = value;
      return;
    }
    if (!_attributes.contains(attr)) return;
    kept[attr] = attr == 'style' ? _neutraliseStyle(value) : value;
  });
  el.attributes
    ..clear()
    ..addAll(kept);
}

/// A URL with the characters browsers ignore taken out, so `java\tscript:`
/// is seen for what it is.
String _normalisedUrl(String value) =>
    value.replaceAll(RegExp(r'[\x00-\x20]'), '').toLowerCase();

String? _schemeOf(String normalised) =>
    RegExp(r'^([a-z][a-z0-9+.\-]*):').firstMatch(normalised)?.group(1);

bool _isAllowedLink(String value) {
  final scheme = _schemeOf(_normalisedUrl(value));
  // No scheme is a relative link, which in the editor goes nowhere.
  return scheme == null || _linkSchemes.contains(scheme);
}

/// Where an image-like attribute ends up: kept as it is (inline data or a
/// cid part), renamed so it fetches nothing (remote), or dropped (null).
String? _imageSource(String attr, String value,
    {required bool onImage, required bool keepRemote}) {
  final url = _normalisedUrl(value);
  final scheme = _schemeOf(url);
  final remote = scheme == 'http' || scheme == 'https' || url.startsWith('//');
  if (remote) return keepRemote ? attr : 'data-blocked-$attr';
  if (attr == 'src' && onImage &&
      (scheme == 'cid' || url.startsWith('data:image/'))) {
    return 'src';
  }
  return null;
}

/// Inline styles keep their look but not their fetches.
String _neutraliseStyle(String style) => style
    .replaceAll(RegExp(r'url\s*\([^)]*\)', caseSensitive: false), 'none')
    .replaceAll(RegExp(r'expression\s*\(', caseSensitive: false), '(');

/// The plain-text alternative for the sent message, derived from the editor's
/// HTML so the two halves say the same thing.
String plainTextFromHtml(String html) => htmlToText(html);

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _two(int v) => v.toString().padLeft(2, '0');
