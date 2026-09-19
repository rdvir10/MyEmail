import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Android asking, while the app is already running, which mailbox a
/// just-placed home-screen widget should count.
///
/// The cold-start case is the plugin's own
/// `initiallyLaunchedFromHomeWidgetConfigure`. This is the other one: the app
/// was already running, so Android handed the configure intent to the
/// activity that was there and Dart's main() never ran again.
const _channel = MethodChannel('mailtree/widget');

void listenForWidgetSetup(void Function(String appWidgetId) onConfigure) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'configure') return null;
    final id = call.arguments;
    if (id is String && id.isNotEmpty) onConfigure(id);
    return null;
  });
}
