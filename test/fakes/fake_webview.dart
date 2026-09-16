import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A WebView that is a grey box.
///
/// `webview_flutter` has no implementation off a device, so any screen holding
/// one throws in a widget test and every other assertion on that screen goes
/// untested with it. That is why nothing around the reading pane or the
/// compose editor had widget coverage.
///
/// This implements the minimum the platform interface asks for and records
/// what was loaded, so the Flutter half of those screens can be tested. It
/// deliberately does not pretend to run JavaScript: the editor's bridge and
/// the sanitiser are proved by their own unit tests and on a device, and a
/// fake that pretended otherwise would prove nothing while looking like it
/// did.
class FakeWebViewPlatform extends WebViewPlatform {
  /// Install for one test. Restores nothing afterwards, because the platform
  /// instance is a global the real implementation never sets under test.
  static FakeWebViewPlatform install() {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    return platform;
  }

  /// Every document handed to a controller, newest last.
  final List<String> loadedHtml = [];

  /// Every script a controller was asked to run.
  final List<String> ranJavaScript = [];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      _FakeController(params, this);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWidget(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      _FakeNavigationDelegate(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) =>
      _FakeCookieManager(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this._platform) : super.implementation();

  final FakeWebViewPlatform _platform;

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async =>
      _platform.loadedHtml.add(html);

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams params,
  ) async {}

  @override
  Future<void> runJavaScript(String javaScript) async =>
      _platform.ranJavaScript.add(javaScript);

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    _platform.ranJavaScript.add(javaScript);
    return '';
  }
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xFFEEEEEE),
        child: SizedBox.expand(),
      );
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakeCookieManager extends PlatformWebViewCookieManager {
  _FakeCookieManager(super.params) : super.implementation();
}
