import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// An HTML mail body in a WebView that is locked down as far as it goes:
///
///  * JavaScript off. Mail never needs it and it is the main attack surface.
///  * Remote content (images, stylesheets, fonts, backgrounds) removed from
///    the HTML itself before it reaches the WebView, until the reader taps
///    "Show images". A remote image is a tracking pixel until proven
///    otherwise; the sender learns nothing from a message being opened.
///    Doing this in Dart rather than through a WebView setting means it is
///    the same on every platform and can be unit tested.
///  * Every navigation cancelled inside the WebView and handed to the system
///    browser or mail app instead, so a link can never replace the message
///    with a page that looks like one.
///
/// The view fills whatever height it is given, so the host must bound it
/// (the reading pane puts it in an Expanded). Sizing a JavaScript-free
/// WebView to its content is not possible, and enabling JavaScript just to
/// measure it would undo the first point.
class HtmlBodyView extends StatefulWidget {
  const HtmlBodyView({super.key, required this.html});

  final String html;

  @override
  State<HtmlBodyView> createState() => _HtmlBodyViewState();
}

class _HtmlBodyViewState extends State<HtmlBodyView> {
  late final WebViewController _controller;
  bool _showRemote = false;
  Brightness _brightness = Brightness.light;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            // The html-string load itself arrives as about:blank / data.
            if (uri.scheme == 'about' || uri.scheme == 'data') {
              return NavigationDecision.navigate;
            }
            openExternally(uri);
            return NavigationDecision.prevent;
          },
        ),
      );
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Theme.of(context).brightness;
    if (next == _brightness) return;
    _brightness = next;
    _load();
  }

  @override
  void didUpdateWidget(HtmlBodyView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      _showRemote = false;
      _load();
    }
  }

  void _load() {
    final source =
        _showRemote ? widget.html : stripRemoteContent(widget.html);
    // The WebView's own background shows during the load and behind a short
    // body. Matching it to the document avoids a white flash on a dark screen.
    _controller
      ..setBackgroundColor(
        readsAsDark(source, _brightness) ? const Color(0xFF1C1B1F) : Colors.white,
      )
      ..loadHtmlString(wrapHtmlForDisplay(source, brightness: _brightness));
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
                    onPressed: () {
                      setState(() => _showRemote = true);
                      _load();
                    },
                    child: const Text('Show images'),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }
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
bool htmlHasRemoteContent(String html) => RegExp(
      r'''(\b(src|srcset|poster|background|href)\s*=\s*["']?\s*|url\(\s*["']?\s*|@import\s+["']?\s*)(https?:)?//''',
      caseSensitive: false,
    ).hasMatch(html);

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
}) {
  final hasHtmlTag = RegExp(r'<html[\s>]', caseSensitive: false).hasMatch(html);
  final body = hasHtmlTag ? _extractBody(html) : html;
  final dark = readsAsDark(html, brightness);
  final laidOutFor = declaredLayoutWidth(body);
  final fg = dark ? '#e6e1e5' : '#1c1b1f';
  final bg = dark ? '#1c1b1f' : '#fff';
  final rule = dark ? '#5a585c' : '#ccc';
  final quoted = dark ? '#b6b0b6' : '#444';
  return '<!doctype html><html><head>'
      '<meta charset="utf-8">'
      // A message built to a fixed width is laid out at that width and
      // scaled to fit; everything else is laid out to the screen.
      '<meta name="viewport" content="${laidOutFor == null ? 'width=device-width, initial-scale=1' : 'width=$laidOutFor'}">'
      '<style>'
      // Tells the WebView which form controls and scrollbars to draw, so a
      // dark message does not get a light scrollbar down the side of it.
      ':root{color-scheme:${dark ? 'dark' : 'light'}}'
      'body{margin:12px 16px;font:15px/1.45 -apple-system,Roboto,sans-serif;'
      'color:$fg;background:$bg;word-wrap:break-word;overflow-wrap:anywhere}'
      'a{color:${dark ? '#a8c8ff' : '#0f6cbd'}}'
      'img{max-width:100%;height:auto}'
      // A blocked image leaves a tag with nothing in it, which collapses and
      // takes the shape of the message with it. A box the size the sender
      // asked for keeps the layout standing and says plainly that something
      // is not being shown.
      'img[data-blocked-src],img[data-blocked-srcset],'
      'img[data-blocked-background]{min-width:16px;min-height:16px;'
      'background:${dark ? '#2b2930' : '#f1f1f4'};'
      'border:1px dashed $rule;border-radius:4px;box-sizing:border-box}'
      // Only where the message has not asked for a width of its own. Capping
      // the tables of a 600-wide layout to the screen is what breaks it.
      '${laidOutFor == null ? 'table{max-width:100%}' : ''}'
      'pre{white-space:pre-wrap}'
      'blockquote{margin:8px 0;padding-left:12px;'
      'border-left:3px solid $rule;color:$quoted}'
      '</style></head><body>$body</body></html>';
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
