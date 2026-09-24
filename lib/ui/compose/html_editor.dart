import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../domain/error_report.dart';

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Theme.of(context).brightness;
    final dark = next == Brightness.dark;
    _web.setBackgroundColor(dark ? const Color(0xFF1C1B1F) : Colors.white);
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

  /// Put [html] in place of the signature, or take the signature out when
  /// it is empty. Waits for the page, so a From changed while the editor is
  /// still loading is not lost.
  Future<void> setSignature(String html) async {
    await ready;
    await _web?.runJavaScript(
        'window.mailtreeSetSignature(${jsonEncode(html)});');
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
    --quote-fg:#1c1b1f; --quote-bg:transparent; --quote-pad:0;
    --blocked-bg:#eee; --blocked-rule:#bbb; --link:#0f6cbd;
  }
  html[data-theme="dark"]{
    color-scheme:dark;
    --fg:#e6e1e5; --bg:#1c1b1f; --muted:#b6b0b6; --rule:#5a585c;
    /* The quote holds the sender's own HTML, authored against a light
       background. Darkening underneath it turns their black text invisible,
       so in dark mode it keeps a light sheet of its own and the text you are
       actually writing is the part that goes dark. */
    --quote-fg:#1c1b1f; --quote-bg:#f4f2f5; --quote-pad:10px;
    --blocked-bg:#ddd; --blocked-rule:#aaa; --link:#a8c8ff;
  }
  html,body{margin:0;padding:0;height:100%}
  body{
    box-sizing:border-box;padding:12px 16px;
    font:15px/1.45 -apple-system,Roboto,sans-serif;
    color:var(--fg);background:var(--bg);
    outline:none;word-wrap:break-word;overflow-wrap:anywhere;
    -webkit-tap-highlight-color:transparent;
  }
  a{color:var(--link)}
  img{max-width:100%;height:auto}
  blockquote{margin:8px 0;padding-left:12px;border-left:2px solid var(--rule)}
  .mailtree-signature{color:var(--muted)}
  .mailtree-quote{
    color:var(--quote-fg);background:var(--quote-bg);
    padding:var(--quote-pad);border-radius:6px;margin-top:8px;
  }
  .mailtree-quote a{color:#0f6cbd}
  /* A blocked remote image still needs to occupy space, or the quote
     reflows as the user types and the layout jumps. */
  img[data-blocked-src],img[data-blocked-srcset]{
    min-width:24px;min-height:24px;
    background:var(--blocked-bg);border:1px dashed var(--blocked-rule);
  }
</style></head>
<body contenteditable="true">$bodyHtml</body>
<script nonce="$nonce">
(function () {
  function post(payload) {
    if (window.MyEmail) window.MyEmail.postMessage(JSON.stringify(payload));
  }

  window.mailtreeGetHtml = function () { return document.body.innerHTML; };

  // Repainting rather than reloading: a theme change mid-message must not
  // discard what has been written.
  window.mailtreeSetTheme = function (name) {
    document.documentElement.setAttribute('data-theme', name);
  };

  window.mailtreeFormat = function (command, value) {
    document.execCommand(command, false, value);
    document.body.focus();
    reportFormats();
  };

  window.mailtreeInsert = function (html) {
    document.execCommand('insertHTML', false, html);
    reportFormats();
  };

  // The signature is the sending account's, so a change of From swaps it.
  // Only the one written for this message, directly in the body: a quoted
  // message sent from here carries a signature div of its own.
  window.mailtreeSetSignature = function (html) {
    var sig = document.querySelector('body > .mailtree-signature');
    if (!html) {
      if (sig) sig.remove();
      return;
    }
    if (!sig) {
      sig = document.createElement('div');
      sig.className = 'mailtree-signature';
      // Above the quote, where the builder puts it; at the end without one.
      document.body.insertBefore(
          sig, document.querySelector('body > .mailtree-quote'));
    }
    sig.innerHTML = html;
  };

  window.mailtreeFocus = function () {
    document.body.focus();
    placeCaret();
  };

  var FORMATS = ['bold', 'italic', 'underline',
                 'insertUnorderedList', 'insertOrderedList'];

  function reportFormats() {
    var active = [];
    for (var i = 0; i < FORMATS.length; i++) {
      try {
        if (document.queryCommandState(FORMATS[i])) active.push(FORMATS[i]);
      } catch (e) { /* not every command is queryable everywhere */ }
    }
    post({type: 'formats', value: active});
  }

  // Start where the compose builder asked, which is above the quote.
  function placeCaret() {
    var marker = document.getElementById('mailtree-caret');
    var range = document.createRange();
    if (marker) {
      range.setStartBefore(marker);
    } else {
      range.selectNodeContents(document.body);
      range.collapse(true);
    }
    range.collapse(true);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  document.addEventListener('selectionchange', reportFormats);
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

  placeCaret();
  reportFormats();
})();
</script>
</html>
''';
}

/// Bold, italic, underline, lists, clear: the formatting a message or a
/// signature needs, driving the editor's document.
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
