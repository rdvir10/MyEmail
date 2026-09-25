import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint, mapEquals;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../domain/html_safety.dart';
import '../../domain/trusted_senders.dart';
import '../common/text_size.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// An HTML mail body in a WebView that is locked down as far as it goes:
///
///  * JavaScript off. Mail never needs it and it is the main attack surface.
///  * Remote content (images, stylesheets, fonts, backgrounds) removed from
///    the HTML itself before it reaches the WebView, until the reader taps
///    "Show images". A remote image is a tracking pixel until proven
///    otherwise; the sender learns nothing from a message being opened.
///    Doing this in Dart rather than through a WebView setting means it is
///    the same on every platform and can be unit tested.
///  * Every navigation cancelled inside the WebView. One that follows a tap
///    on the message is handed to the system browser or mail app, so a link
///    can never replace the message with a page that looks like one; one
///    nobody tapped for is dropped, because the message started it by itself.
///  * `<meta>` and `<base>` removed. A `<meta http-equiv=refresh>` works with
///    JavaScript off, and used to open the sender's page in the browser the
///    moment a message was opened, images blocked or not.
///
/// The view fills whatever height it is given, so the host must bound it
/// (the reading pane puts it in an Expanded). Sizing a JavaScript-free
/// WebView to its content is not possible, and enabling JavaScript just to
/// measure it would undo the first point.
class HtmlBodyView extends StatefulWidget {
  const HtmlBodyView({
    super.key,
    required this.html,
    this.showImages = false,
    this.senderEmail,
    this.onTrust,
    this.inlinePictures = const {},
  });

  final String html;

  /// The pictures [html] names by Content-ID, as data: URIs; see
  /// [withInlinePictures]. They come after the body, so a change here
  /// loads the page again without hiding pictures the reader asked for.
  final Map<String, String> inlinePictures;

  /// Start with the pictures already loaded, from the setting of the same
  /// name, or because this sender is trusted. The bar offering to load them
  /// is then never shown, because there is nothing left to offer.
  final bool showImages;

  /// Who sent it, so the bar can offer to trust them. Null where that is
  /// not on offer.
  final String? senderEmail;

  /// Trust this entry from now on: an address, or a domain with a leading
  /// `@`. The screen above decides what trusting means and where it is
  /// kept; this only asks.
  final void Function(String entry)? onTrust;

  @override
  State<HtmlBodyView> createState() => HtmlBodyViewState();
}

/// Public so the reading pane can scroll the body from the keyboard.
class HtmlBodyViewState extends State<HtmlBodyView> {
  late final WebViewController _controller;

  Future<void> scrollBy(double dy) => _controller.scrollBy(0, dy.round());

  /// The WebView clamps to its content, so a huge number is "the bottom".
  Future<void> scrollToEnd({required bool top}) =>
      _controller.scrollTo(0, top ? 0 : 1 << 24);
  late bool _showRemote = widget.showImages;
  Brightness _brightness = Brightness.light;

  /// When the reader last touched or clicked the message. A navigation is
  /// only passed on if it follows one closely.
  DateTime? _touchedAt;

  /// Between handing the WebView a document and it finishing that load.
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            switch (paneNavigation(
              request.url,
              loading: _loading,
              touchedAt: _touchedAt,
              now: DateTime.now(),
            )) {
              case PaneNavigation.load:
                return NavigationDecision.navigate;
              case PaneNavigation.openOutside:
                // One tap, one page: a second navigation riding on the same
                // touch is the message's, not the reader's.
                _touchedAt = null;
                openExternally(Uri.parse(request.url));
                return NavigationDecision.prevent;
              case PaneNavigation.drop:
                return NavigationDecision.prevent;
            }
          },
          onPageFinished: (_) => _loading = false,
        ),
      );

    // Without this the WebView lays every message out at the width of the
    // view and ignores the viewport the message is wrapped in, so mail built
    // to a fixed 600 or 640 pixels — which is nearly all marketing mail —
    // runs off the right-hand edge with no way to see the rest of it. On it,
    // the page is laid out at the width it asks for and scaled to fit, which
    // is what every other mail client shows you.
    final platform = _controller.platform;
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        platform is AndroidWebViewController) {
      try {
        platform.setUseWideViewPort(true);
      } catch (e) {
        debugPrint('[myemail] could not widen the web view: $e');
      }
    }

    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sizeText();
    final next = Theme.of(context).brightness;
    if (next == _brightness) return;
    _brightness = next;
    _load();
  }

  /// The text zoom last given to the WebView, or null for its own.
  int? _textZoom;

  /// The body's text at the app's size (Settings, View, Text size).
  void _sizeText() {
    final zoom = webTextZoomAt(context, applied: _textZoom != null);
    if (zoom == null || zoom == _textZoom) return;
    _textZoom = zoom;
    applyWebTextZoom(_controller, zoom);
  }

  @override
  void didUpdateWidget(HtmlBodyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _showRemote = widget.showImages;
      _load();
    } else if (oldWidget.showImages != widget.showImages &&
        widget.showImages) {
      // The setting was turned on while a message was open.
      _showRemote = true;
      _load();
    } else if (!mapEquals(oldWidget.inlinePictures, widget.inlinePictures)) {
      _load();
    }
  }

  void _show() {
    setState(() => _showRemote = true);
    _load();
  }

  void _load() {
    final source = withInlinePictures(
      _showRemote ? widget.html : stripRemoteContent(widget.html),
      widget.inlinePictures,
    );
    // The WebView's own background shows during the load and behind a short
    // body. Matching it to the document avoids a white flash on a dark screen.
    _loading = true;
    _controller
      ..setBackgroundColor(
        readsAsDark(source, _brightness) ? const Color(0xFF1C1B1F) : Colors.white,
      )
      ..loadHtmlString(wrapHtmlForDisplay(
        source,
        brightness: _brightness,
        remoteAllowed: _showRemote,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsRemote = htmlHasRemoteContent(widget.html);
    return Column(
      children: [
        if (needsRemote && !_showRemote)
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.image_not_supported_outlined,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Images are blocked',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _show,
                    child: const Text('Show images'),
                  ),
                  if (widget.onTrust != null && widget.senderEmail != null)
                    _TrustButton(
                      email: widget.senderEmail!,
                      onTrust: (entry) {
                        widget.onTrust!(entry);
                        _show();
                      },
                    ),
                ],
              ),
            ),
          ),
        Expanded(
          // Sees the pointer on its way to the WebView without taking it.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _touchedAt = DateTime.now(),
            child: WebViewWidget(controller: _controller),
          ),
        ),
      ],
    );
  }
}

/// What the reading pane does with a navigation.
enum PaneNavigation { load, openOutside, drop }

/// How long after a touch a navigation still counts as the reader's.
const tapWindow = Duration(seconds: 2);

/// Decide what happens to a navigation the message's WebView asks for.
///
/// The document's own load arrives as about: or data:, and a data: page is
/// only accepted while that load is under way, so a tapped `data:` link
/// cannot replace the message with a page that imitates one. Anything else
/// leaves the app, and only when the reader touched the message just before:
/// a `<meta http-equiv=refresh>` or an iframe navigates with nobody touching
/// anything, and those are dropped. A link followed from a physical keyboard
/// is dropped too, which is the price of telling the two apart without
/// JavaScript.
PaneNavigation paneNavigation(
  String url, {
  required bool loading,
  required DateTime? touchedAt,
  required DateTime now,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return PaneNavigation.drop;
  if (uri.scheme == 'about') return PaneNavigation.load;
  if (uri.scheme == 'data') {
    return loading ? PaneNavigation.load : PaneNavigation.drop;
  }
  final tapped = touchedAt != null && now.difference(touchedAt) <= tapWindow;
  return tapped ? PaneNavigation.openOutside : PaneNavigation.drop;
}

/// Links leave the app. Only schemes a person would expect to open are
/// passed on; anything else is dropped.
Future<void> openExternally(Uri uri) async {
  const allowed = {'http', 'https', 'mailto', 'tel'};
  if (!allowed.contains(uri.scheme)) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No handler installed: nothing sensible to do inside a mail body.
  }
}

final _remoteRef = RegExp(r'''(https?:)?//''', caseSensitive: false);

/// Whether the message references anything the WebView would fetch from the
/// network. Used to decide whether to offer "Show images".
///
/// Asked of [stripRemoteContent] itself, so the bar shows exactly when
/// showing images would change something. A pattern of its own counted any
/// `href`, a plain link included, and a note with a link in its signature
/// offered to show images that were never there.
bool htmlHasRemoteContent(String html) => stripRemoteContent(html) != html;

/// The message with every remote fetch neutralised, leaving links alone:
///
///  * `src`, `srcset`, `poster` and `background` attributes pointing off the
///    device are renamed to `data-blocked-*`, so the tag stays but loads
///    nothing;
///  * `<link>` elements with a remote `href` (stylesheets) are removed;
///  * `url(...)` in styles and `@import` rules pointing off the device are
///    replaced with `none` / dropped.
///
/// Anchors keep their `href`: a link is only followed when tapped, and the
/// navigation delegate hands it to the browser.
String stripRemoteContent(String html) {
  var s = html;

  // (?<!-) keeps an already-renamed data-blocked-src from matching again, so
  // the function is idempotent.
  s = s.replaceAllMapped(
    RegExp(
      r'''(?<![-\w])(src|srcset|poster|background)\s*=\s*(["']?)(\s*(?:https?:)?//)''',
      caseSensitive: false,
    ),
    (m) => 'data-blocked-${m[1]!.toLowerCase()}=${m[2]}${m[3]}',
  );

  s = s.replaceAll(
    RegExp(
      r'''<link\b[^>]*\bhref\s*=\s*["']?\s*(?:https?:)?//[^>]*>''',
      caseSensitive: false,
    ),
    '',
  );

  // @import before url(): an import written as url(...) must be dropped
  // whole, not left behind as "@import none;".
  s = s.replaceAll(
    RegExp(
      r'''@import\s+(?:url\(\s*)?["']?\s*(?:https?:)?//[^;]*;''',
      caseSensitive: false,
    ),
    '',
  );

  s = s.replaceAll(
    RegExp(r'''url\(\s*["']?\s*(?:https?:)?//[^)]*\)''', caseSensitive: false),
    'none',
  );

  return s;
}

/// Whether a message can safely be shown on a dark background.
///
/// Only when the app is dark *and* the message brings no colours of its own.
/// A sender who set `color:#000` on their own white background is invisible
/// the moment the background is darkened underneath them, and there is no way
/// to know which of their declarations to keep. So a message that styles
/// itself stays on the light sheet it was written for, exactly as Outlook and
/// Gmail do it, and only an unstyled one follows the app.
bool readsAsDark(String html, Brightness brightness) =>
    brightness == Brightness.dark && !messageBringsItsOwnColours(html);

/// Does this HTML set any colour or background of its own?
///
/// Deliberately generous about what counts. A false positive costs a light
/// message on a dark screen, which is merely unfashionable; a false negative
/// costs black text on a near-black background, which is unreadable.
bool messageBringsItsOwnColours(String html) => RegExp(
      r'''(\bbgcolor\s*=|(?<![-\w])color\s*:|background(-color)?\s*:|<font\b)''',
      caseSensitive: false,
    ).hasMatch(html);

/// The width a message was laid out for, if it says so.
///
/// Marketing mail is built on tables of a fixed pixel width — 600 and 640 are
/// almost a standard — with the columns inside them fixed too. Told to fit a
/// phone, the browser cannot honour those widths and cannot ignore them
/// either, so the columns collapse into each other and the message arrives
/// looking broken.
///
/// The answer every mail client reaches for is the same: lay the message out
/// at the width it was written for and scale the whole thing down to fit,
/// which is what a viewport of that width asks the browser to do. It stays
/// readable, and a pinch zooms in.
///
/// Returns null for a message that never states a width, which is most
/// ordinary mail, and those go on being laid out to the screen. Percentages
/// are ignored: a table at 100% is already asking to fit.
int? declaredLayoutWidth(String html) {
  var widest = 0;
  final matches = [
    // width="600" on a table or cell.
    ...RegExp(r'''\bwidth\s*=\s*["']?(\d{2,4})(?![%\d])''', caseSensitive: false)
        .allMatches(html),
    // width:600px in a style attribute or a stylesheet.
    ...RegExp(r'''\bwidth\s*:\s*(\d{2,4})\s*px''', caseSensitive: false)
        .allMatches(html),
  ];
  for (final m in matches) {
    final value = int.tryParse(m.group(1)!) ?? 0;
    // Above the cap is a stray number rather than a layout: a tracking pixel
    // declaring a silly width, or a stylesheet rule for a desktop browser.
    if (value > widest && value <= maxLayoutWidth) widest = value;
  }
  return widest >= minLayoutWidth ? widest : null;
}

/// Below this a message fits a phone anyway, and forcing a viewport would
/// blow a narrow message up to fill the screen.
const minLayoutWidth = 480;

/// Above this it is not a layout anyone intended to be read on a phone.
const maxLayoutWidth = 1400;

/// The message HTML inside a minimal document: a viewport that suits the way
/// the message was built, a readable default font, and images that never
/// overflow. Anything the message brings of its own still applies, since this
/// only sets defaults.
String wrapHtmlForDisplay(
  String html, {
  Brightness brightness = Brightness.light,
  bool remoteAllowed = false,
}) {
  final isDocument =
      RegExp(r'<(html|body)[\s>]', caseSensitive: false).hasMatch(html);
  final body = removeDocumentDirectives(isDocument ? _extractBody(html) : html);
  // The message's own look, which only the inside of its <body> used to
  // survive: the stylesheets in its head, and the body's colours, style,
  // direction and language. A newsletter styled from its head came out as
  // bare text, and a right-to-left message came out left to right.
  final sheets = isDocument ? _headStyles(html) : '';
  final bodyTag = isDocument ? _bodyTag(html) : '<body>';
  final dark = readsAsDark(html, brightness);
  final laidOutFor = declaredLayoutWidth(body);
  final fg = dark ? '#e6e1e5' : '#1c1b1f';
  final bg = dark ? '#1c1b1f' : '#fff';
  final rule = dark ? '#5a585c' : '#ccc';
  final quoted = dark ? '#b6b0b6' : '#444';
  return '<!doctype html><html><head>'
      '<meta charset="utf-8">'
      // First in the head, before anything the message brings.
      '${contentPolicyTag(remoteAllowed: remoteAllowed)}'
      // A message built to a fixed width is laid out at that width and
      // scaled to fit; everything else is laid out to the screen.
      '<meta name="viewport" content="${laidOutFor == null ? 'width=device-width, initial-scale=1' : 'width=$laidOutFor'}">'
      '<style>'
      // Tells the WebView which form controls and scrollbars to draw, so a
      // dark message does not get a light scrollbar down the side of it.
      ':root{color-scheme:${dark ? 'dark' : 'light'}}'
      // No line-height and no paragraph margins of our own.
      //
      // Both were here, and both were added on top of spacing the sender had
      // already decided. Outlook writes a paragraph per line with its own
      // margins; a line-height of 1.45 over that turned a dense note into
      // something you scroll through. The message is shown as it was
      // written, which is the only rule that cannot be wrong for somebody.
      'body{margin:10px 14px;font-family:-apple-system,Roboto,sans-serif;'
      'font-size:15px;'
      'color:$fg;background:$bg;word-wrap:break-word;overflow-wrap:anywhere}'
      'a{color:${dark ? '#a8c8ff' : '#0f6cbd'}}'
      'img{max-width:100%;height:auto}'
      // A blocked image leaves a tag with nothing in it, which collapses and
      // takes the shape of the message with it. A box the size the sender
      // asked for keeps the layout standing and says plainly that something
      // is not being shown.
      // A picture named by Content-ID and not (yet) put in place too.
      'img[data-blocked-src],img[data-blocked-srcset],'
      'img[data-blocked-background],img[src^="cid:" i]{min-width:16px;min-height:16px;'
      'background:${dark ? '#2b2930' : '#f1f1f4'};'
      'border:1px dashed $rule;border-radius:4px;box-sizing:border-box}'
      // Only where the message has not asked for a width of its own. Capping
      // the tables of a 600-wide layout to the screen is what breaks it.
      '${laidOutFor == null ? 'table{max-width:100%}' : ''}'
      'pre{white-space:pre-wrap}'
      'blockquote{margin:8px 0;padding-left:12px;'
      'border-left:3px solid $rule;color:$quoted}'
      // After ours, so the sender's rules win where the two disagree.
      '</style>$sheets</head>$bodyTag$body</body></html>';
}

/// The `<style>` blocks from the message's head, with only their `media`.
String _headStyles(String html) {
  final lower = html.toLowerCase();
  final bodyAt = lower.indexOf('<body');
  final headEnd = lower.indexOf('</head');
  final head = bodyAt >= 0
      ? html.substring(0, bodyAt)
      : headEnd >= 0
          ? html.substring(0, headEnd)
          : '';
  final media = RegExp(r'''\bmedia\s*=\s*("[^"]*"|'[^']*')''',
      caseSensitive: false);
  return [
    for (final m in RegExp(r'<style\b([^>]*)>([\s\S]*?)</style\s*>',
            caseSensitive: false)
        .allMatches(head))
      '<style${switch (media.firstMatch(m[1]!)) {
        final a? => ' media=${a[1]}',
        null => '',
      }}>${m[2]}</style>',
  ].join();
}

/// A `<body>` tag carrying the source body's look: `bgcolor` and `text` as
/// the colours they stand for, then its own `style` (which, as in a
/// browser, beats them), and its `dir`, `lang` and `class`.
String _bodyTag(String html) {
  final tag =
      RegExp(r'<body\b([^>]*)>', caseSensitive: false).firstMatch(html);
  if (tag == null) return '<body>';
  final attrs = <String, String>{};
  for (final m in RegExp(
    r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
  ).allMatches(tag[1]!)) {
    attrs.putIfAbsent(m[1]!.toLowerCase(), () => m[2] ?? m[3] ?? m[4] ?? '');
  }
  // Only what a colour, a direction or a class name can be made of.
  String only(String? value, String allowed) =>
      (value ?? '').replaceAll(RegExp('[^$allowed]'), '').trim();
  final background = only(attrs['bgcolor'], r'#\w(),.% ');
  final text = only(attrs['text'], r'#\w(),.% ');
  final style = (attrs['style'] ?? '').trim().replaceAll('"', '&quot;');
  final css = [
    if (background.isNotEmpty) 'background:$background',
    if (text.isNotEmpty) 'color:$text',
    if (style.isNotEmpty) style,
  ].join(';');
  final dir = only(attrs['dir'], r'\w');
  final lang = only(attrs['lang'], r'\w-');
  final classes = only(attrs['class'], r'\w\- ');
  return '<body'
      '${css.isEmpty ? '' : ' style="$css"'}'
      '${dir.isEmpty ? '' : ' dir="$dir"'}'
      '${lang.isEmpty ? '' : ' lang="$lang"'}'
      '${classes.isEmpty ? '' : ' class="$classes"'}'
      '>';
}

String _extractBody(String html) {
  final m = RegExp(r'<body[^>]*>([\s\S]*?)</body>', caseSensitive: false)
      .firstMatch(html);
  if (m != null) return m.group(1)!;
  // A <html> without <body>: strip the outer tags and keep the rest.
  return html
      .replaceAll(RegExp(r'</?html[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<head[\s\S]*?</head>', caseSensitive: false), '');
}

// Kept for callers that only need the detector's pattern.
bool isRemoteReference(String value) => _remoteRef.hasMatch(value.trim());

/// The menu beside "Show images": trust this sender, or everyone at their
/// domain, and load the pictures now as proof it took.
class _TrustButton extends StatelessWidget {
  const _TrustButton({required this.email, required this.onTrust});

  final String email;
  final void Function(String entry) onTrust;

  @override
  Widget build(BuildContext context) {
    final domain = trustDomain(email);
    return PopupMenuButton<String>(
      tooltip: 'Always show pictures from…',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: onTrust,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: trustAddress(email),
          child: Text('Always show from $email'),
        ),
        if (domain != null)
          PopupMenuItem(
            value: domain,
            child: Text('Always show from everyone at ${domain.substring(1)}'),
          ),
      ],
    );
  }
}
