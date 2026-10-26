import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

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

  /// The page's place in Flutter's focus: it has it while the page does.
  /// See [EditorPage].
  final _pageFocus = FocusNode(debugLabel: 'Editor page', skipTraversal: true);

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
    widget.controller._pageFocus = _pageFocus;
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
  void didUpdateWidget(HtmlEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller._pageFocus, _pageFocus)) {
        oldWidget.controller._pageFocus = null;
      }
      widget.controller._pageFocus = _pageFocus;
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller._pageFocus, _pageFocus)) {
      widget.controller._pageFocus = null;
    }
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      return EditorPage(
        webView: platform.webViewIdentifier,
        focusNode: _pageFocus,
      );
    }
    return Focus(
      focusNode: _pageFocus,
      onKeyEvent: _keysForThePage,
      child: WebViewWidget(controller: _web),
    );
  }
}

/// Every key, while the page has the focus, is the page's. Flutter's own
/// shortcuts would take the arrows on the way, to move the focus about,
/// and Space and Enter to press whatever it was on. Skipped rather than
/// handled, so Android hands each one on to the page, whose script
/// reports back the ones the screen answers to: Tab, Esc and Ctrl+Enter.
KeyEventResult _keysForThePage(FocusNode _, KeyEvent _) =>
    KeyEventResult.skipRemainingHandlers;

/// The editor's WebView on Android, and its place in Flutter's focus.
///
/// Built as the WebView plugin builds its own, but for the one thing the
/// plugin leaves out: Android's focus going to the page is passed on to
/// Flutter's. Without it a tap in the message left Flutter's focus, and
/// its cursor, in the field above: two cursors showed, and what a
/// keyboard typed went on into the field (3.6.1).
///
/// [focusNode] has the focus while the page does. Taking it, however it
/// came (a tap, Tab, the keyboard's Next, a dialog closing), the page
/// takes Android's focus as well, and Flutter's text input is told the
/// keyboard is the page's, as Flutter's own platform views tell it: the
/// field the cursor came from lets go of the keyboard without taking it
/// down, and stops catching what is typed. Losing it to something else on
/// the same screen that is not a text field, the page lets go of Android's:
/// a text field takes that itself as it shows its keyboard, and letting go
/// first would take the keyboard down between the two. To a menu or a
/// dialog in front it keeps it, and Flutter's comes back as they close.
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.webView,
    required this.focusNode,
  });

  /// The WebView as the plugin knows it: what the platform view is made
  /// from, and what the editor bridge finds it by.
  final int webView;

  final FocusNode focusNode;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  /// The platform view, as Flutter's text input knows it, once made.
  int? _viewId;

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: widget.focusNode,
        onFocusChange: _focusChanged,
        onKeyEvent: _keysForThePage,
        child: PlatformViewLink(
          viewType: _webViewType,
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          ),
          onCreatePlatformView: (params) {
            _viewId = params.id;
            return PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: _webViewType,
              layoutDirection: TextDirection.ltr,
              creationParams: widget.webView,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () {
                if (mounted) widget.focusNode.requestFocus();
              },
            )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
          },
        ),
      );

  void _focusChanged(bool focused) {
    if (focused) {
      final id = _viewId;
      if (id != null) unawaited(_keyboardIsThePages(id));
      unawaited(focusEditorView(widget.webView));
      return;
    }
    // Once the focus has finished moving: a text field taking it has by
    // then shown its keyboard, and taken Android's focus with it.
    scheduleMicrotask(() {
      if (!mounted || widget.focusNode.hasFocus) return;
      final now = FocusManager.instance.primaryFocus;
      final screen = widget.focusNode.enclosingScope;
      if (now == null || screen == null) return;
      // A menu, a dialog or another screen in front gives Flutter's focus
      // back as it closes. The page keeps Android's meanwhile, and the
      // keyboard stays up, as it did for a formatting menu before.
      if (now != screen && !now.ancestors.contains(screen)) return;
      unawaited(blurEditorView(widget.webView));
    });
  }
}

/// What the WebView plugin registers its Android views under.
const _webViewType = 'plugins.flutter.io/webview';

/// Flutter's text input told that the keyboard belongs to the platform
/// view [viewId], as Flutter's own platform views tell it.
Future<void> _keyboardIsThePages(int viewId) async {
  try {
    await SystemChannels.textInput.invokeMethod<void>(
      'TextInput.setPlatformViewClient',
      <String, Object>{'platformViewId': viewId},
    );
  } on PlatformException {
    // The page still has Android's focus, and with it the keys.
  }
}

const _editorChannel = MethodChannel('mailtree/editor');

/// Android's focus for the editor's WebView, which the WebView plugin knows
/// by [webView]. False where there is no such view, and nothing is thrown:
/// the caret is still put in the page.
Future<bool> focusEditorView(int webView) async {
  try {
    return await _editorChannel
            .invokeMethod<bool>('focus', {'webView': webView}) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Android's focus taken off the editor's WebView, which the plugin knows
/// by [webView], where it has it. False where there is no such view.
Future<bool> blurEditorView(int webView) async {
  try {
    return await _editorChannel
            .invokeMethod<bool>('blur', {'webView': webView}) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Drives the editor from Dart: read the document, apply formatting, learn
/// what the caret is sitting in.
class HtmlEditorController extends ChangeNotifier {
  HtmlEditorController({required this.initialHtml});

  final String initialHtml;

  WebViewController? _web;
  final _readyCompleter = Completer<void>();

  /// A key the page reports rather than handles: 'send' for Ctrl+Enter,
  /// 'close' for Esc, 'tab' and 'backTab' for Tab and Shift+Tab. The
  /// compose screen decides what they mean.
  void Function(String key)? onKey;
  Set<String> _activeFormats = const {};

  /// Which formats apply where the caret is, so the toolbar can light up.
  Set<String> get activeFormats => _activeFormats;

  /// What is being typed after an @ in the message, for the people it could
  /// mean; null when the caret is not in one. See [insertMention].
  final mention = ValueNotifier<String?>(null);

  @override
  void dispose() {
    mention.dispose();
    super.dispose();
  }

  Future<void> get ready => _readyCompleter.future;

  bool get isReady => _web != null;

  /// The page's place in Flutter's focus, while the editor is on screen.
  FocusNode? _pageFocus;

  /// Whether the cursor is in the message, rather than somewhere around it.
  bool get hasFocus => _pageFocus?.hasFocus ?? false;

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
      } else if (data['type'] == 'mention') {
        final value = data['value'];
        mention.value = value is String && value.isNotEmpty ? value : null;
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

  /// A link to [url] on what is selected, or with nothing selected, [text]
  /// (or the address itself) put in as one.
  Future<void> insertLink(String url, {String? text}) async {
    await _web?.runJavaScript(
      'window.mailtreeLink(${jsonEncode(url)}, ${jsonEncode(text ?? '')});',
    );
  }

  /// The link the caret is in, taken off: the words stay.
  Future<void> unlink() async {
    await _web?.runJavaScript('window.mailtreeUnlink();');
  }

  /// The @ being typed, and what follows it, replaced by [name] as a link
  /// to [email]: Outlook's @mention.
  Future<void> insertMention(String name, String email) async {
    mention.value = null;
    await _web?.runJavaScript(
      'window.mailtreeMention(${jsonEncode(name)}, ${jsonEncode(email)});',
    );
  }

  /// Give the body the keyboard, with the caret back where it last was,
  /// or where writing starts (above the quote) if it has not been in yet.
  ///
  /// Flutter's focus comes first, so the field the cursor comes from lets
  /// go of it. Then Android's: a WebView takes keys only once Android has
  /// focused it, and without that the caret showed in the body and the
  /// keys went on to the field above. The page taking Flutter's focus asks
  /// for Android's too (see [EditorPage]), but not where it had Flutter's
  /// already.
  Future<void> focus() async {
    final web = _web;
    if (web == null) return;
    _pageFocus?.requestFocus();
    final platform = web.platform;
    if (platform is AndroidWebViewController) {
      await focusEditorView(platform.webViewIdentifier);
    }
    await web.runJavaScript('window.mailtreeFocus();');
  }

  /// The words the phone's AI is to work on: those selected, or with none
  /// selected, all the message's own (not the signature, not the quote).
  /// Where they came from is kept, for [replaceAiText].
  Future<String> aiText() async {
    final web = _web;
    if (web == null) return '';
    final result =
        await web.runJavaScriptReturningResult('window.mailtreeAiText();');
    if (result.toString() == 'null') return '';
    return _decodeJsString(result);
  }

  /// [text] in place of the words [aiText] read.
  Future<void> replaceAiText(String text) async {
    await _web?.runJavaScript('window.mailtreeAiReplace(${jsonEncode(text)});');
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
  a.mailtree-mention{font-weight:600;text-decoration:none}
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
  // The body itself, through the document's own getter, and never asked
  // for by name again. A picture with a name is a property of the document
  // ahead of that getter, so a quote's <img name="body"> was the body as
  // the script saw it: what was typed was never read, and an empty message
  // was sent. The sanitiser takes such names off; this holds if one ever
  // gets past it.
  var body = Object.getOwnPropertyDescriptor(Document.prototype, 'body')
      .get.call(document);

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
    var copy = body.cloneNode(true);
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
    var lines = body.querySelectorAll(BLOCKS);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.closest('.mailtree-quote') ||
          line.closest('.mailtree-signature')) {
        continue;
      }
      if (range ? !range.intersectsNode(line)
                : line.parentElement !== body) {
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
    paintColours(body, name === 'dark');
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

  // Colour, highlight, size and font are written as styles, as Outlook
  // writes them, and not as <font> tags; the rest as the browser does.
  var STYLED = ['foreColor', 'hiliteColor', 'fontSize', 'fontName'];

  window.mailtreeFormat = function (command, value) {
    var styled = STYLED.indexOf(command) >= 0;
    if (styled) document.execCommand('styleWithCSS', false, true);
    document.execCommand(command, false, value);
    if (styled) document.execCommand('styleWithCSS', false, false);
    body.focus();
    orientAll();
    reportFormats();
  };

  function escapeText(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // A link on the words selected, or with none selected, the words given
  // (or the address) put in as one.
  window.mailtreeLink = function (url, text) {
    var sel = window.getSelection();
    body.focus();
    if (sel.rangeCount && !sel.isCollapsed) {
      document.execCommand('createLink', false, url);
    } else {
      document.execCommand('insertHTML', false,
          '<a href="' + escapeText(url) + '">' + escapeText(text || url) +
          '</a>&nbsp;');
    }
    reportFormats();
  };

  window.mailtreeUnlink = function () {
    var sel = window.getSelection();
    var a = sel.anchorNode && (sel.anchorNode.nodeType === 1
        ? sel.anchorNode : sel.anchorNode.parentElement);
    a = a && a.closest('a');
    if (a) {
      var range = document.createRange();
      range.selectNodeContents(a);
      sel.removeAllRanges();
      sel.addRange(range);
    }
    document.execCommand('unlink', false, null);
    reportFormats();
  };

  // An @ typed after a space or at the start of a line, and what follows
  // it: reported, for the people it could mean, until a space ends it.
  // Never in the quote, and never in a link: "ron@" in an address is not
  // a mention.
  var mentionAt = null, mentionShown = false;
  function checkMention() {
    var sel = window.getSelection();
    var found = null;
    if (sel.rangeCount && sel.isCollapsed) {
      var node = sel.anchorNode, offset = sel.anchorOffset;
      if (node && node.nodeType === 3 &&
          !node.parentElement.closest('.mailtree-quote, a')) {
        var m = /(^|[\\s(\\u00a0])@([^\\s@\\u00a0]{1,40})\$/u
            .exec(node.data.substring(0, offset));
        if (m) {
          found = m[2];
          mentionAt = {node: node, start: offset - m[2].length - 1,
                       end: offset};
        }
      }
    }
    if (found === null) {
      mentionAt = null;
      if (mentionShown) post({type: 'mention', value: null});
      mentionShown = false;
      return;
    }
    mentionShown = true;
    post({type: 'mention', value: found});
  }

  window.mailtreeMention = function (name, email) {
    if (!mentionAt || !body.contains(mentionAt.node)) return;
    var range = document.createRange();
    range.setStart(mentionAt.node, mentionAt.start);
    range.setEnd(mentionAt.node, mentionAt.end);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    document.execCommand('insertHTML', false,
        '<a class="mailtree-mention" href="mailto:' + escapeText(email) +
        '">@' + escapeText(name) + '</a>&nbsp;');
    mentionAt = null;
    mentionShown = false;
    post({type: 'mention', value: null});
    orientAll();
  };

  // The phone's AI on what is written: the words selected, or with none
  // selected all this message's own, up to the signature or the quote.
  // The range is kept, so the answer goes back where the words came from
  // after the dialog showing it has had the focus.
  var aiRange = null;
  function ownRange() {
    var range = document.createRange();
    range.setStart(body, 0);
    var stop = null;
    for (var n = body.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 1 && (n.tagName === 'BLOCKQUOTE' ||
          n.classList.contains('mailtree-signature') ||
          n.classList.contains('mailtree-quote'))) {
        stop = n;
        break;
      }
    }
    if (stop) range.setEndBefore(stop);
    else range.setEnd(body, body.childNodes.length);
    return range;
  }

  window.mailtreeAiText = function () {
    var sel = window.getSelection();
    aiRange = sel.rangeCount && !sel.isCollapsed &&
        body.contains(sel.getRangeAt(0).commonAncestorContainer)
      ? sel.getRangeAt(0).cloneRange()
      : ownRange();
    // Laid out, off the page, so its lines read as lines: a range's own
    // text runs the paragraphs together.
    var holder = document.createElement('div');
    holder.style.position = 'fixed';
    holder.style.left = '-10000px';
    holder.style.width = '600px';
    holder.appendChild(aiRange.cloneContents());
    document.documentElement.appendChild(holder);
    var text = holder.innerText;
    holder.remove();
    return text;
  };

  window.mailtreeAiReplace = function (text) {
    if (!aiRange) return;
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(aiRange);
    document.execCommand('insertText', false, text);
    aiRange = null;
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
      body.insertBefore(sig, quote);
      if (quote) body.insertBefore(blankLine(), quote);
      if (!isBlankLine(sig.previousElementSibling)) {
        body.insertBefore(blankLine(), sig);
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

  // Where the caret last was in the body, so coming back to it from the
  // fields above puts it back there rather than at the top.
  var lastCaret = null;
  document.addEventListener('selectionchange', function () {
    var sel = window.getSelection();
    if (sel.rangeCount && body.contains(sel.anchorNode)) {
      lastCaret = sel.getRangeAt(0).cloneRange();
    }
  });

  window.mailtreeFocus = function () {
    body.focus();
    if (lastCaret && body.contains(lastCaret.startContainer)) {
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(lastCaret);
    } else {
      placeCaret();
    }
    keepCaretVisible();
  };

  var FORMATS = ['bold', 'italic', 'underline', 'strikeThrough',
                 'insertUnorderedList', 'insertOrderedList',
                 'justifyCenter', 'justifyRight'];

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
    var tops = body.children;
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
    // In a link, so the link button offers to change or take it off.
    var sel = window.getSelection();
    var at = sel.anchorNode && (sel.anchorNode.nodeType === 1
        ? sel.anchorNode : sel.anchorNode.parentElement);
    if (at && body.contains(at) && at.closest('a')) active.push('link');
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
      var first = body.firstChild;
      range.selectNodeContents(
          first && first.nodeType === 1 ? first : body);
      range.collapse(true);
    }
    range.collapse(true);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  document.addEventListener('selectionchange', reportFormats);
  body.addEventListener('input', orientAll);
  body.addEventListener('input', reportFormats);
  body.addEventListener('input', checkMention);
  body.addEventListener('keyup', function (e) {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' ||
        e.key === 'Home' || e.key === 'End') {
      checkMention();
    }
  });

  // Keys pressed in here never reach Flutter, so the ones the compose
  // screen answers to are reported across. Ctrl+Enter is stopped from
  // also putting a line break in. Tab moves between the message's fields,
  // as it does above, and the screen says where to: never a tab in the
  // text, and never the browser's own move to whatever else is on the page.
  document.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
      e.preventDefault();
      post({ type: 'key', value: 'send' });
    } else if (e.key === 'Escape') {
      post({ type: 'key', value: 'close' });
    } else if (e.key === 'Tab' && !e.ctrlKey && !e.altKey && !e.metaKey) {
      e.preventDefault();
      post({ type: 'key', value: e.shiftKey ? 'backTab' : 'tab' });
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
  body.addEventListener('input', keepCaretVisible);
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
  if (!body.innerHTML.trim()) {
    body.innerHTML = '<div><br></div>';
  }
  orientAll();
  placeCaret();
  reportFormats();
})();
</script>
</html>
''';
}

/// The formatting a message or a signature needs, as Outlook's Format Text
/// has it, driving the editor's document: bold, italic, underline and
/// strikethrough; colour, highlight and size; lists, indent and alignment;
/// links; line spacing; and clear. One row, which slides sideways where the
/// screen is narrower than it.
///
/// [onPicture] and [signatures] are the message's own, where it has them:
/// a picture put where the cursor is, and the Signature menu.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.enabled,
    this.onPicture,
    this.signatures,
    this.assistant,
  });

  final HtmlEditorController controller;
  final bool enabled;

  /// Proofread or rewrite, by the phone's AI, where it has it.
  final Widget? assistant;

  /// A picture in the text, from the gallery or the camera.
  final VoidCallback? onPicture;

  /// The Signature menu, which the compose screen builds.
  final Widget? signatures;

  /// Outlook's font colours, the few anyone uses in mail.
  static const colours = <(String, String)>[
    ('Black', '#000000'),
    ('Red', '#c50f1f'),
    ('Orange', '#ca5010'),
    ('Green', '#107c10'),
    ('Blue', '#0f6cbd'),
    ('Purple', '#5c2e91'),
    ('Grey', '#616161'),
  ];

  /// And its highlighter's.
  static const highlights = <(String, String)>[
    ('No highlight', 'transparent'),
    ('Yellow', '#ffff00'),
    ('Green', '#00ff00'),
    ('Turquoise', '#00ffff'),
    ('Pink', '#ff00ff'),
  ];

  /// Sizes as the browser's seven steps, which it writes as CSS.
  static const sizes = <(String, String)>[
    ('Small', '2'),
    ('Normal', '3'),
    ('Large', '5'),
    ('Huge', '6'),
  ];

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

    Widget swatches(
      String tooltip,
      IconData icon,
      String command,
      List<(String, String)> choices,
    ) =>
        PopupMenuButton<String>(
          tooltip: tooltip,
          enabled: enabled,
          icon: Icon(icon),
          onSelected: (value) => controller.format(command, value),
          itemBuilder: (_) => [
            for (final (name, value) in choices)
              PopupMenuItem(
                value: value,
                child: Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: value == 'transparent'
                            ? null
                            : Color(int.parse('ff${value.substring(1)}',
                                radix: 16)),
                        border: Border.all(color: theme.dividerColor),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(name),
                  ],
                ),
              ),
          ],
        );

    const divider = VerticalDivider(width: 8, indent: 10, endIndent: 10);
    return SafeArea(
      top: false,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: SizedBox(
          height: kMinInteractiveDimension,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              button('bold', Icons.format_bold, 'Bold'),
              button('italic', Icons.format_italic, 'Italic'),
              button('underline', Icons.format_underlined, 'Underline'),
              button('strikeThrough', Icons.format_strikethrough,
                  'Strikethrough'),
              swatches('Font colour', Icons.format_color_text, 'foreColor',
                  colours),
              swatches('Highlight', Icons.border_color_outlined,
                  'hiliteColor', highlights),
              PopupMenuButton<String>(
                tooltip: 'Size',
                enabled: enabled,
                icon: const Icon(Icons.format_size),
                onSelected: (value) => controller.format('fontSize', value),
                itemBuilder: (_) => [
                  for (final (name, value) in sizes)
                    PopupMenuItem(value: value, child: Text(name)),
                ],
              ),
              divider,
              button('insertUnorderedList', Icons.format_list_bulleted,
                  'Bullets'),
              button('insertOrderedList', Icons.format_list_numbered,
                  'Numbers'),
              button('outdent', Icons.format_indent_decrease,
                  'Decrease indent'),
              button('indent', Icons.format_indent_increase,
                  'Increase indent'),
              PopupMenuButton<String>(
                tooltip: 'Align',
                enabled: enabled,
                icon: Icon(
                  active.contains('justifyCenter')
                      ? Icons.format_align_center
                      : active.contains('justifyRight')
                          ? Icons.format_align_right
                          : Icons.format_align_left,
                ),
                onSelected: (value) => controller.format(value),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'justifyLeft', child: Text('Left')),
                  PopupMenuItem(value: 'justifyCenter', child: Text('Centre')),
                  PopupMenuItem(value: 'justifyRight', child: Text('Right')),
                ],
              ),
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
              divider,
              IconButton(
                key: const ValueKey('editor-link'),
                tooltip: active.contains('link') ? 'Link' : 'Insert link',
                isSelected: active.contains('link'),
                color: active.contains('link') ? theme.colorScheme.primary : null,
                icon: const Icon(Icons.link),
                onPressed: enabled ? () => _link(context) : null,
              ),
              if (onPicture != null)
                IconButton(
                  key: const ValueKey('editor-picture'),
                  tooltip: 'Picture',
                  icon: const Icon(Icons.image_outlined),
                  onPressed: enabled ? onPicture : null,
                ),
              ?signatures,
              ?assistant,
              IconButton(
                tooltip: 'Remove formatting',
                icon: const Icon(Icons.format_clear),
                onPressed:
                    enabled ? () => controller.format('removeFormat') : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Insert a link, or change or take off the one the cursor is in.
  Future<void> _link(BuildContext context) async {
    final inLink = controller.activeFormats.contains('link');
    if (inLink) {
      final choice = await showDialog<String>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: const Text('Link'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialog).pop('change'),
              child: const Text('Change the address'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialog).pop('remove'),
              child: const Text('Remove the link'),
            ),
          ],
        ),
      );
      if (choice == 'remove') {
        await controller.unlink();
        return;
      }
      if (choice != 'change' || !context.mounted) return;
    }
    if (!context.mounted) return;
    final link = await showDialog<({String url, String text})>(
      context: context,
      builder: (_) => const _LinkDialog(),
    );
    if (link == null) return;
    await controller.insertLink(
      linkAddress(link.url),
      text: link.text.trim().isEmpty ? null : link.text.trim(),
    );
  }
}

/// What was typed as a link's address, made one a mail app follows: an
/// email address as mailto:, and a bare web address as https://.
String linkAddress(String typed) {
  final text = typed.trim();
  if (RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(text)) {
    return text;
  }
  if (RegExp(r'^[^@\s/]+@[^@\s/]+\.[^@\s/]+$').hasMatch(text)) {
    return 'mailto:$text';
  }
  return 'https://$text';
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog();

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _url = TextEditingController();
  final _text = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _text.dispose();
    super.dispose();
  }

  void _done() {
    if (_url.text.trim().isEmpty) return;
    Navigator.of(context).pop((url: _url.text, text: _text.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Insert link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('link-address'),
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Address'),
              onSubmitted: (_) => _done(),
            ),
            TextField(
              key: const ValueKey('link-text'),
              controller: _text,
              decoration: const InputDecoration(
                labelText: 'Text to show (if nothing is selected)',
              ),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: _done, child: const Text('Insert')),
        ],
      );
}
