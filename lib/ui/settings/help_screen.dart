import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The two documents that came with the app: how to use it, and what it
/// can do.
///
/// Carried inside the app rather than linked to, so they open with no
/// signal and always describe the version in your hand. They are the same
/// pages that sit in the project folder, generated from the same source.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, required this.page});

  final HelpPage page;

  static Future<void> open(BuildContext context, HelpPage page) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => HelpScreen(page: page)),
      );

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

enum HelpPage {
  manual('User manual', 'assets/help/user-manual.html'),
  features('What it can do', 'assets/help/features.html');

  const HelpPage(this.title, this.asset);

  final String title;
  final String asset;

  /// The page a link between the two documents means.
  static HelpPage? forLink(String url) {
    final name = Uri.tryParse(url)?.path.split('/').last ?? '';
    final decoded = Uri.decodeComponent(name).toLowerCase();
    if (decoded.startsWith('user manual')) return HelpPage.manual;
    if (decoded.startsWith('features')) return HelpPage.features;
    return null;
  }
}

class _HelpScreenState extends State<HelpScreen> {
  late final WebViewController _web;
  late HelpPage _page = widget.page;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      // The pages are ours and hold no scripts; nothing here needs it.
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            // Loading the document itself, and jumping to a heading in it.
            if (uri == null || uri.scheme == 'about' || uri.scheme == 'data') {
              return NavigationDecision.navigate;
            }
            // The link across to the other document, which is a file name
            // beside this one rather than anywhere on the web.
            final other = HelpPage.forLink(request.url);
            if (other != null) {
              _show(other);
              return NavigationDecision.prevent;
            }
            if (uri.scheme == 'http' || uri.scheme == 'https') {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          },
        ),
      );
    _show(_page);
  }

  Future<void> _show(HelpPage page) async {
    final html = await rootBundle.loadString(page.asset);
    if (!mounted) return;
    setState(() => _page = page);
    await _web.loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_page.title),
        centerTitle: false,
        actions: [
          // The other document, without going back to Settings for it.
          for (final page in HelpPage.values)
            if (page != _page)
              TextButton(
                onPressed: () => _show(page),
                child: Text(page.title),
              ),
        ],
      ),
      // The browser preview has no WebView; the manual is a file there.
      body: kIsWeb
          ? const Center(child: Text('Open the manual from the project folder.'))
          : WebViewWidget(controller: _web),
    );
  }
}
