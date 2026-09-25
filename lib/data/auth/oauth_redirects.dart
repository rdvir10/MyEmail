import 'dart:async';

import 'package:flutter/services.dart';

/// The way back from the phone's browser after a Google sign-in.
///
/// Google will not sign anyone in inside a WebView, so the sign-in page opens
/// in the phone's own browser, and when it is done the browser follows a
/// redirect to the app's custom URI scheme. Android starts
/// OAuthRedirectActivity for it, which hands the URL to MainActivity, which
/// sends it here over a channel. Whichever sign-in is waiting takes it.
///
/// Only a sign-in that is waiting. A redirect that arrives with nothing
/// waiting, which is what a sign-in the app was killed in the middle of
/// looks like, is dropped: there is no request to match it to, and a code
/// nobody asked for is not one to redeem.
class OAuthRedirects {
  OAuthRedirects({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'mailtree/oauth';

  final MethodChannel _channel;
  final _arrivals = StreamController<Uri>.broadcast();

  /// Every redirect the app is handed, as it arrives.
  Stream<Uri> get arrivals => _arrivals.stream;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'redirect') throw MissingPluginException(call.method);
    final uri = Uri.tryParse('${call.arguments}');
    if (uri != null) _arrivals.add(uri);
    return null;
  }

  /// For tests, and for anything else that has a redirect in hand.
  void deliver(Uri uri) => _arrivals.add(uri);

  /// Bring the app back in front of the browser's tab.
  ///
  /// The loopback way back leaves the tab on top with a "signed in" page
  /// on it; the app has the code by then and this puts it in front, which
  /// closes the tab above it. Nothing to do where there is no platform.
  Future<void> bringAppToFront() async {
    try {
      await _channel.invokeMethod<void>('foreground');
    } on MissingPluginException {
      // A test, or the browser preview.
    }
  }
}
