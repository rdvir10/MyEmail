import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

/// An HTML mail body in a WebView that is locked down as far as it goes:
///
///  * JavaScript off. Mail never needs it and it is the main attack surface.
///  * Remote loads (images, stylesheets, fonts) blocked until the reader taps
///    "Show images". A remote image is a tracking pixel until proven
///    otherwise; the sender learns nothing from a message being opened.
///  * File and content URL access off, so nothing in the message can reach
///    the app's own storage.
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
  bool _showRemote = false;

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
                    onPressed: () => setState(() => _showRemote = true),
                    child: const Text('Show images'),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: InAppWebView(
            // A new key rebuilds the WebView when the setting flips; settings
            // that gate network access are read at creation.
            key: ValueKey(_showRemote),
            initialData: InAppWebViewInitialData(
              data: wrapHtmlForDisplay(widget.html),
              mimeType: 'text/html',
              encoding: 'utf-8',
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: false,
              blockNetworkImage: !_showRemote,
              blockNetworkLoads: !_showRemote,
              loadsImagesAutomatically: true,
              allowFileAccess: false,
              allowContentAccess: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              useShouldOverrideUrlLoading: true,
              mediaPlaybackRequiresUserGesture: true,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
              useWideViewPort: false,
              allowsLinkPreview: false,
            ),
            shouldOverrideUrlLoading: (controller, action) async {
              final url = action.request.url;
              if (url == null) return NavigationActionPolicy.CANCEL;
              // The initial data load is about:blank; let that through.
              if (url.scheme == 'about' || url.scheme == 'data') {
                return NavigationActionPolicy.ALLOW;
              }
              await openExternally(url.uriValue);
              return NavigationActionPolicy.CANCEL;
            },
          ),
        ),
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

/// Whether the message references anything the WebView would fetch from the
/// network if allowed. Used to decide whether to offer "Show images".
bool htmlHasRemoteContent(String html) => RegExp(
      r'''(src|href|url\()\s*=?\s*["']?\s*(https?:)?//''',
      caseSensitive: false,
    ).hasMatch(html);

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
