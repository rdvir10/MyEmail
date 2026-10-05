import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../domain/error_report.dart';
import '../../domain/message_colours.dart';
import '../../theme/app_theme.dart';
import '../common/text_size.dart';

/// A rich-text editor backed by a `contenteditable` WebView.
///
/// This is a WebView and not a Flutter editor because the quoted original has
/// to be editable in place: the caret goes anywhere in it, including inside
/// the quote, the way Outlook desktop behaves. A Flutter editor would have to
/// parse the original into its own model first, and no Dart model represents
/// arbitrary mail HTML without destroying it.
///
/// The document has JavaScript on, because the bridge needs it, so what a
/// received message can do inside it is closed off three ways. Everything
/// quoted, and every draft reopened from the server, has been through
/// `sanitiseForEditing`, which rebuilds it from an allow-list. The document
/// carries a Content-Security-Policy that lets only its own script run (by
/// nonce) and fetches nothing from the network, so a handler that got past
/// the sanitiser still could not execute or phone home. And once the document has loaded, nothing may navigate it: a
/// `<meta http-equiv=refresh>` or a tapped link cannot swap the editor for a
/// page of the sender's that talks to the bridge.
///
/// Height: the editor fills what it is given. A contenteditable cannot report
/// its own height to Flutter without polling, so the host bounds it.
class HtmlEditor extends StatefulWidget {
  const HtmlEditor({
    super.key,
    required this.controller,
    this.onReady,
  });

  final HtmlEditorController controller;
  final VoidCallback? onReady;

  @override
  State<HtmlEditor> createState() => _HtmlEditorState();
}

class _HtmlEditorState extends State<HtmlEditor> {
  late final WebViewController _web;

  /// Set when the editor document has finished loading. From then on every
  /// navigation is refused, including about: and data:, which are only
  /// allowed for the load itself.
  bool _documentLoaded = false;

  /// The one script allowed to run in the document, named by the CSP.
  final String _nonce = base64Url
      .encode(List<int>.generate(18, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(
        'MyEmail',
        onMessageReceived: (message) {
          widget.controller._onBridgeMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          // Nothing in an editor should navigate. Tapping a link in the quote
          // must not replace the document being written, and neither may
          // anything the quote does by itself.
          onNavigationRequest: (request) =>
              editorAllowsNavigation(request.url, loaded: _documentLoaded)
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent,
          onPageFinished: (_) {
            _documentLoaded = true;
            widget.controller._attach(_web);
            widget.onReady?.call();
          },
        ),
      );
    // Loading waits for didChangeDependencies: the document needs to know
    // which palette to start in, and the theme is not reachable from initState.
  }

  bool _loaded = false;
  Brightness _brightness = Brightness.light;

  /// The text zoom last given to the WebView, or null for its own.
  int? _textZoom;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // What is being written is shown at the size everything else is. The
    // zoom is the view's, not the document's: nothing sent changes with it.
    final zoom = webTextZoomAt(context, applied: _textZoom != null);
    if (zoom != null && zoom != _textZoom) {
      _textZoom = zoom;
      applyWebTextZoom(_web, zoom);
    }
    final next = Theme.of(context).brightness;
    final dark = next == Brightness.dark;
    _web.setBackgroundColor(dark ? darkPageColour : Colors.white);
    if (!_loaded) {
      _loaded = true;
      _brightness = next;
      _web.loadHtmlString(
        editorDocument(widget.controller.initialHtml, dark: dark, nonce: _nonce),
      );
      return;
    }
    if (next == _brightness) return;
    _brightness = next;
    // Repaint, never reload: the message being written lives in the document.
    widget.controller._setTheme(dark ? 'dark' : 'light');
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}

/// Drives the editor from Dart: read the document, apply formatting, learn
/// what the caret is sitting in.
class HtmlEditorController extends ChangeNotifier {
  HtmlEditorController({required this.initialHtml});

  final String initialHtml;

  WebViewController? _web;
  final _readyCompleter = Completer<void>();

  /// A key the page reports rather than handles: 'send' for Ctrl+Enter,
  /// 'close' for Esc. The compose screen decides what they mean.
  void Function(String key)? onKey;
  Set<String> _activeFormats = const {};

  /// Which formats apply where the caret is, so the toolbar can light up.
  Set<String> get activeFormats => _activeFormats;

  Future<void> get ready => _readyCompleter.future;

  bool get isReady => _web != null;

  void _attach(WebViewController web) {
    _web = web;
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  void _onBridgeMessage(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['type'] == 'formats') {
        final formats = (data['value'] as List<dynamic>).cast<String>().toSet();
        if (formats.length != _activeFormats.length ||
            !formats.containsAll(_activeFormats)) {
          _activeFormats = formats;
          notifyListeners();
        }
      } else if (data['type'] == 'key' && data['value'] is String) {
        onKey?.call(data['value'] as String);
      }
    } on FormatException {
      // A malformed bridge message is not worth crashing the editor over.
    }
  }

  /// The document as HTML, for sending or saving.
  Future<String> getHtml() async {
    final web = _web;
    if (web == null) return initialHtml;
    final result =
        await web.runJavaScriptReturningResult('window.mailtreeGetHtml();');
    // A page whose script failed answers JavaScript's null, which Android
    // hands back as the word. Taken as the message, it went out reading
    // "null", and what was typed was lost with it. Real HTML is never that.
    if (result.toString() == 'null') {
      throw const EditorUnreadable();
    }
    return _decodeJsString(result);
  }

  /// Apply a formatting command. Names match `document.execCommand`, which is
  /// deprecated in the spec but is still the only thing every Android WebView
  /// implements for contenteditable; there is no replacement to migrate to.
  Future<void> format(String command, [String? value]) async {
    final encoded = value == null ? 'null' : jsonEncode(value);
    await _web?.runJavaScript('window.mailtreeFormat(${jsonEncode(command)}, $encoded);');
  }

  Future<void> insertHtml(String html) async {
    await _web?.runJavaScript('window.mailtreeInsert(${jsonEncode(html)});');
  }

  Future<void> focus() async {
    await _web?.runJavaScript('window.mailtreeFocus();');
  }

  /// Line spacing for the lines selected, or for all that is written when
  /// nothing is: null for single, else a CSS line height such as `150%`.
  Future<void> setLineSpacing(String? lineHeight) async {
    await _web?.runJavaScript(
        'window.mailtreeLineSpacing(${jsonEncode(lineHeight ?? '')});');
  }

  /// Put [html] in place of the signature, or take the signature out when
  /// it is empty. Waits for the page, so a From changed while the editor is
  /// still loading is not lost.
  Future<void> setSignature(String html) async {
    await ready;
    await _web?.runJavaScript(
        'window.mailtreeSetSignature(${jsonEncode(bothWays(html, dark: false))});');
  }

  /// Switch palettes in place. Safe before the page has loaded: the document
  /// starts in the right one, so a dropped call changes nothing.
  Future<void> _setTheme(String name) async {
    await _web?.runJavaScript('window.mailtreeSetTheme(${jsonEncode(name)});');
  }

  /// Strings come back from the WebView JSON-encoded on Android and bare on
  /// some platforms; handle both rather than assuming.
  static String _decodeJsString(Object? result) {
    final s = result?.toString() ?? '';
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        return jsonDecode(s) as String;
      } on FormatException {
        return s;
      }
    }
    return s;
  }
}

/// The editor's page did not hand the message over.
class EditorUnreadable implements Exception, ReadableError {
  const EditorUnreadable();

  @override
  String get message => 'The message could not be read from the editor, so '
      'nothing was sent or saved. What you wrote is still on screen.';

  @override
  String toString() => message;
}

/// Whether the editor may follow a navigation to [url].
///
/// Only the document's own load, which arrives as about: or data:, and only
/// before it has finished. Public so the rule can be tested without a
/// WebView.
bool editorAllowsNavigation(String url, {required bool loaded}) {
  if (loaded) return false;
  final scheme = Uri.tryParse(url)?.scheme;
  return scheme == 'about' || scheme == 'data';
}

/// [html] able to show in either theme, with its own colours turned in the
/// dark and put back in what is sent; see markDarkColours.
String bothWays(String html, {required bool dark}) => markDarkColours(
      html,
      page: darkPageColour.toARGB32() & 0xFFFFFF,
      text: darkTextColour.toARGB32() & 0xFFFFFF,
      dark: dark,
    );

/// The editor document: the body is the editable surface, and a small script
/// exposes the three things Dart needs.
///
/// The Content-Security-Policy is the backstop behind the sanitiser: only the
/// script carrying [nonce] runs, inline handlers do not, and nothing is
/// fetched from the network (images come from `data:` only; signatures carry
/// theirs inline and remote ones in a quote are already blocked).
String editorDocument(String bodyHtml,
    {required bool dark, required String nonce}) {
  return '''
<!doctype html><html data-theme="${dark ? 'dark' : 'light'}"><head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; base-uri 'none'; form-action 'none'">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  /* Both palettes ship in the document and the theme attribute picks one, so
     following the system at night never means reloading the document and
     throwing away what has been typed. */
  :root{
    color-scheme:light;
    --fg:#1c1b1f; --bg:#fff; --muted:#555; --rule:#ccc;
    --blocked-bg:#eee; --blocked-rule:#bbb; --link:#0f6cbd;
  }
  /* The quote goes dark with the rest. It used to keep a light sheet of its
     own, because darkening under the sender's black text hid it; now its
     colours are turned instead, and put back in what is sent. */
  html[data-theme="dark"]{
    color-scheme:dark;
    --fg:${cssHex(darkTextColour)}; --bg:${cssHex(darkPageColour)}; --muted:#b6b0b6; --rule:#5a585c;
    --blocked-bg:#2b2930; --blocked-rule:#5a585c; --link:#a8c8ff;
  }
  html,body{margin:0;padding:0;height:100%}
  /* The first line close under the header, and lines a little apart but
     with no gap between them: each Enter is a new line, as in Outlook and
     Gmail, and a blank line is Enter twice. It was 12px and 1.45, with a
     paragraph's gap under every line, which made a note double-spaced
     before a word of it was sent. */
  body{
    box-sizing:border-box;padding:6px 16px;
    font:15px/1.35 -apple-system,Roboto,sans-serif;
    color:var(--fg);background:var(--bg);
    outline:none;word-wrap:break-word;overflow-wrap:anywhere;
    -webkit-tap-highlight-color:transparent;
  }
  a{color:var(--link)}
  img{max-width:100%;height:auto}
  blockquote{margin:8px 0;padding-left:12px;border-left:2px solid var(--rule)}
  .mailtree-signature{color:var(--muted)}
  /* Paragraphs from before lines were lines: an old draft, a signature
     saved then. They go out with no gap as well; see mailtreeGetHtml. */
  body > p, .mailtree-signature p{margin:0}
  /* A blocked remote image still needs to occupy space, or the quote
     reflows as the user types and the layout jumps. */
  img[data-blocked-src],img[data-blocked-srcset]{
    min-width:24px;min-height:24px;
    background:var(--blocked-bg);border:1px dashed var(--blocked-rule);
  }
</style></head>
<body contenteditable="true">${bothWays(bodyHtml, dark: dark)}</body>
<script nonce="$nonce">
(function () {
  function post(payload) {
    if (window.MyEmail) window.MyEmail.postMessage(JSON.stringify(payload));
  }

  // Every paragraph's direction brought up to date first, so what is sent
  // says which way each one reads; see orientAll. And without a script:
  // this one is written after the body, and the browser moves it inside,
  // so the body as it stands carried the editor's own code into every
  // message sent and every signature saved. An old signature saved that
  // way carries it still, and loses it here.
  window.mailtreeGetHtml = function () {
    orientAll();
    var copy = document.body.cloneNode(true);
    var scripts = copy.querySelectorAll('script');
    for (var i = 0; i < scripts.length; i++) scripts[i].remove();
    // The colours as they came, and none of the marks that carry them.
    paintColours(copy, false);
    unmark(copy);
    // A paragraph of this message's own (an old draft's, a signature's)
    // goes out with no gap under it, as it shows here. Every mail program
    // puts one under a paragraph that does not say otherwise. The quote's
    // are left as the sender wrote them.
    var paragraphs = copy.querySelectorAll('p');
    for (var p = 0; p < paragraphs.length; p++) {
      if (!paragraphs[p].closest('.mailtree-quote') &&
          !paragraphs[p].style.margin) {
        paragraphs[p].style.margin = '0';
      }
    }
    return copy.innerHTML;
  };

  // Line spacing, written the way Outlook writes it (a line height in
  // percent), so it arrives looking as it does here. On the lines
  // selected, or with nothing selected on all that has been written; never
  // on the signature or the quote, which are not this message's text. An
  // empty value is single spacing.
  window.mailtreeLineSpacing = function (value) {
    var sel = window.getSelection();
    var range = sel.rangeCount && !sel.isCollapsed ? sel.getRangeAt(0) : null;
    var lines = document.body.querySelectorAll(BLOCKS);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.closest('.mailtree-quote') ||
          line.closest('.mailtree-signature')) {
        continue;
      }
      if (range ? !range.intersectsNode(line)
                : line.parentElement !== document.body) {
        continue;
      }
      respace(line, 'style', value);
      // The colours' stored versions too, so a line whose colours are
      // turned for the dark still swaps back as it should.
      respace(line, LIGHT + 'style', value);
      respace(line, DARK + 'style', value);
    }
    reportFormats();
  };

  // The style in [name] with its line height set to [value], or taken off.
  function respace(el, name, value) {
    if (name !== 'style' && !el.hasAttribute(name)) return;
    var probe = document.createElement('div');
    probe.setAttribute('style', el.getAttribute(name) || '');
    if (value) {
      probe.style.lineHeight = value;
    } else {
      probe.style.removeProperty('line-height');
    }
    var style = probe.getAttribute('style') || '';
    if (style) {
      el.setAttribute(name, style);
    } else if (name === 'style') {
      el.removeAttribute('style');
    } else {
      el.setAttribute(name, '');
    }
  }

  // Repainting rather than reloading: a theme change mid-message must not
  // discard what has been written.
  window.mailtreeSetTheme = function (name) {
    document.documentElement.setAttribute('data-theme', name);
    paintColours(document.body, name === 'dark');
  };

  // The colours the quote (or a signature) brought. Where they differ in
  // the dark, an element is marked and carries the dark one beside its own
  // (markDarkColours); in the dark its own waits aside, under LIGHT.
  var MARKED = 'data-mt-colours', DARK = 'data-mt-dark-',
      LIGHT = 'data-mt-light-';

  function valueOf(el, name) {
    return name === 'css' ? el.textContent : el.getAttribute(name);
  }

  function setValue(el, name, value) {
    if (name === 'css') el.textContent = value;
    else el.setAttribute(name, value);
  }

  // Each marked colour to the theme's. One that has changed while the dark
  // one showed, by formatting or typing, is left as it now is: that is
  // what was written. A new line takes its paragraph's marks with it, so
  // it turns with the rest.
  function paintColours(root, dark) {
    var marked = root.querySelectorAll('[' + MARKED + ']');
    for (var i = 0; i < marked.length; i++) {
      var el = marked[i];
      var names = el.getAttributeNames();
      for (var j = 0; j < names.length; j++) {
        if (names[j].indexOf(DARK) !== 0) continue;
        var name = names[j].substring(DARK.length);
        var darkValue = el.getAttribute(names[j]);
        var showing = valueOf(el, name);
        if (dark) {
          if (el.hasAttribute(LIGHT + name) || showing === null) continue;
          el.setAttribute(LIGHT + name, showing);
          setValue(el, name, darkValue);
        } else if (el.hasAttribute(LIGHT + name)) {
          if (showing === darkValue) {
            setValue(el, name, el.getAttribute(LIGHT + name));
          }
          el.removeAttribute(LIGHT + name);
        }
      }
    }
  }

  function unmark(root) {
    var marked = root.querySelectorAll('[' + MARKED + ']');
    for (var i = 0; i < marked.length; i++) {
      var names = marked[i].getAttributeNames();
      for (var j = 0; j < names.length; j++) {
        if (names[j] === MARKED || names[j].indexOf(DARK) === 0 ||
            names[j].indexOf(LIGHT) === 0) {
          marked[i].removeAttribute(names[j]);
        }
      }
    }
  }

  window.mailtreeFormat = function (command, value) {
    document.execCommand(command, false, value);
    document.body.focus();
    orientAll();
    reportFormats();
  };

  window.mailtreeInsert = function (html) {
    document.execCommand('insertHTML', false, html);
    orientAll();
    reportFormats();
  };

  // The signature is the sending account's, so a change of From swaps it.
  // Only the one written for this message, directly in the body: a quoted
  // message sent from here carries a signature div of its own.
  window.mailtreeSetSignature = function (html) {
    var sig = document.querySelector('body > .mailtree-signature');
    var quote = document.querySelector('body > .mailtree-quote');
    if (!html) {
      if (sig) {
        // With the blank line that kept it apart from the quote.
        var after = sig.nextElementSibling;
        if (quote && after !== quote && isBlankLine(after)) after.remove();
        sig.remove();
      }
      return;
    }
    if (!sig) {
      sig = document.createElement('div');
      sig.className = 'mailtree-signature';
      // Above the quote, where the builder puts it; at the end without one.
      // A blank line above it and one between it and the quote, as the
      // builder writes them.
      document.body.insertBefore(sig, quote);
      if (quote) document.body.insertBefore(blankLine(), quote);
      if (!isBlankLine(sig.previousElementSibling)) {
        document.body.insertBefore(blankLine(), sig);
      }
    }
    sig.innerHTML = html;
    paintColours(sig,
        document.documentElement.getAttribute('data-theme') === 'dark');
    orientAll();
  };

  // A line with nothing on it, which is how a blank line is written.
  function isBlankLine(el) {
    return !!el && el.tagName === 'DIV' && !el.className &&
        el.textContent.trim() === '' && !el.querySelector('img');
  }

  function blankLine() {
    var line = document.createElement('div');
    line.appendChild(document.createElement('br'));
    return line;
  }

  window.mailtreeFocus = function () {
    document.body.focus();
    placeCaret();
  };

  var FORMATS = ['bold', 'italic', 'underline',
                 'insertUnorderedList', 'insertOrderedList'];

  // Right-to-left writing. Each paragraph written here takes the direction
  // of its first letter, as Gmail's and Outlook's editors set it, and
  // carries it as a dir attribute, so it goes out that way to every mail
  // client: a Hebrew line sits on the right, an English one on the left,
  // in one message. A paragraph with no letter yet keeps the direction it
  // has, so a new line after Hebrew starts on the right. The quoted
  // original is the sender's, and is left as they wrote it.
  var RTL = /[\\u0590-\\u08FF\\uFB1D-\\uFDFF\\uFE70-\\uFEFF]/;
  var LETTER = /\\p{L}/u;
  var BLOCKS = 'p,div,li,ul,ol,h1,h2,h3,h4,h5,h6,blockquote';

  function directionOf(text) {
    var m = LETTER.exec(text);
    if (!m) return null;
    return RTL.test(m[0]) ? 'rtl' : 'ltr';
  }

  // An attribute only where the paragraph reads against what it sits in:
  // an English message carries none at all.
  function orient(el) {
    var dir = directionOf(el.textContent || '');
    if (!dir) return;
    var parent = el.parentElement;
    var inherited = parent ? getComputedStyle(parent).direction : 'ltr';
    if (dir === inherited) {
      if (el.hasAttribute('dir')) el.removeAttribute('dir');
    } else if (el.getAttribute('dir') !== dir) {
      el.setAttribute('dir', dir);
    }
  }

  // Outer before inner, which is document order, so a paragraph is
  // compared with its container as it now reads.
  function orientAll() {
    var tops = document.body.children;
    for (var i = 0; i < tops.length; i++) {
      var top = tops[i];
      if (top.classList.contains('mailtree-quote')) continue;
      if (top.matches(BLOCKS)) orient(top);
      var inner = top.querySelectorAll(BLOCKS);
      for (var j = 0; j < inner.length; j++) {
        if (!inner[j].closest('.mailtree-quote')) orient(inner[j]);
      }
    }
  }

  function reportFormats() {
    var active = [];
    for (var i = 0; i < FORMATS.length; i++) {
      try {
        if (document.queryCommandState(FORMATS[i])) active.push(FORMATS[i]);
      } catch (e) { /* not every command is queryable everywhere */ }
    }
    post({type: 'formats', value: active});
  }

  // Start where the compose builder asked, which is above the quote, or
  // else at the start of the first paragraph.
  function placeCaret() {
    var marker = document.getElementById('mailtree-caret');
    var range = document.createRange();
    if (marker) {
      range.setStartBefore(marker);
    } else {
      var first = document.body.firstChild;
      range.selectNodeContents(
          first && first.nodeType === 1 ? first : document.body);
      range.collapse(true);
    }
    range.collapse(true);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  document.addEventListener('selectionchange', reportFormats);
  document.body.addEventListener('input', orientAll);
  document.body.addEventListener('input', reportFormats);

  // Keys pressed in here never reach Flutter, so the two the compose
  // screen answers to are reported across. Ctrl+Enter is stopped from
  // also putting a line break in.
  document.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
      e.preventDefault();
      post({ type: 'key', value: 'send' });
    } else if (e.key === 'Escape') {
      post({ type: 'key', value: 'close' });
    }
  });

  // Keep the caret visible as the soft keyboard resizes the viewport. The
  // WebView does not scroll to the caret on its own when the document is
  // taller than the visible area.
  function keepCaretVisible() {
    var sel = window.getSelection();
    if (!sel.rangeCount) return;
    var rect = sel.getRangeAt(0).getBoundingClientRect();
    if (!rect || (rect.top === 0 && rect.bottom === 0)) return;
    var margin = 24;
    if (rect.bottom > window.innerHeight - margin) {
      window.scrollBy(0, rect.bottom - window.innerHeight + margin);
    } else if (rect.top < margin) {
      window.scrollBy(0, rect.top - margin);
    }
  }
  document.body.addEventListener('input', keepCaretVisible);
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', keepCaretVisible);
  }

  // Enter starts a line, not a paragraph: a div, which no mail program
  // puts a gap under. Inside a line Enter copies it anyway; this is for
  // the places that are not in one.
  document.execCommand('defaultParagraphSeparator', false, 'div');

  // An empty document, a signature not yet written, is given a line to
  // type into: text typed straight into the body belongs to no line, and
  // would have no direction of its own.
  if (!document.body.innerHTML.trim()) {
    document.body.innerHTML = '<div><br></div>';
  }
  orientAll();
  placeCaret();
  reportFormats();
})();
</script>
</html>
''';
}

/// Bold, italic, underline, lists, line spacing, clear: the formatting a
/// message or a signature needs, driving the editor's document.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({super.key, required this.controller, required this.enabled});

  final HtmlEditorController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = controller.activeFormats;

    Widget button(String command, IconData icon, String tooltip) {
      final isActive = active.contains(command);
      return IconButton(
        tooltip: tooltip,
        isSelected: isActive,
        icon: Icon(icon),
        color: isActive ? theme.colorScheme.primary : null,
        onPressed: enabled ? () => controller.format(command) : null,
      );
    }

    return SafeArea(
      top: false,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Row(
          children: [
            button('bold', Icons.format_bold, 'Bold'),
            button('italic', Icons.format_italic, 'Italic'),
            button('underline', Icons.format_underlined, 'Underline'),
            const VerticalDivider(width: 8, indent: 10, endIndent: 10),
            button('insertUnorderedList', Icons.format_list_bulleted, 'Bullets'),
            button('insertOrderedList', Icons.format_list_numbered, 'Numbers'),
            // Outlook's three. For the lines selected, or with nothing
            // selected, for everything written so far.
            PopupMenuButton<String>(
              tooltip: 'Line spacing',
              enabled: enabled,
              icon: const Icon(Icons.format_line_spacing),
              onSelected: (value) =>
                  controller.setLineSpacing(value.isEmpty ? null : value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: '', child: Text('Single')),
                PopupMenuItem(value: '150%', child: Text('1.5 lines')),
                PopupMenuItem(value: '200%', child: Text('Double')),
              ],
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Remove formatting',
              icon: const Icon(Icons.format_clear),
              onPressed: enabled ? () => controller.format('removeFormat') : null,
            ),
          ],
        ),
      ),
    );
  }
}
