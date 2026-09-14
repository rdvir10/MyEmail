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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.white)
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
    _controller.loadHtmlString(wrapHtmlForDisplay(source));
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

/// The message HTML inside a minimal document: a viewport for phone widths,
/// a readable default font, and images that never overflow. Anything the
/// message brings of its own still applies, since this only sets defaults.
String wrapHtmlForDisplay(String html) {
  final hasHtmlTag = RegExp(r'<html[\s>]', caseSensitive: false).hasMatch(html);
  final body = hasHtmlTag ? _extractBody(html) : html;
  return '<!doctype html><html><head>'
      '<meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>'
      'body{margin:12px 16px;font:15px/1.45 -apple-system,Roboto,sans-serif;'
      'color:#1c1b1f;background:#fff;word-wrap:break-word;overflow-wrap:anywhere}'
      'img{max-width:100%;height:auto}'
      'table{max-width:100%}'
      'pre{white-space:pre-wrap}'
      'blockquote{margin:8px 0;padding-left:12px;border-left:3px solid #ccc;color:#444}'
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
