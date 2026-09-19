import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter/services.dart';

/// Android asking, while the app is already running, which mailbox a
/// just-placed home-screen widget should count.
///
/// The cold-start case is the plugin's own
/// `initiallyLaunchedFromHomeWidgetConfigure`. This is the other one: the app
/// was already running, so Android handed the configure intent to the
/// activity that was there and Dart's main() never ran again.
const _channel = MethodChannel('mailtree/widget');

/// The widgets Android says are on the home screen right now.
///
/// Asked for rather than remembered, because nothing tells the app when a
/// widget is dragged to the bin: without this, its mailbox would be
/// recounted at every sync forever after it had gone.
Future<List<String>> placedWidgetIds() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return const [];
  try {
    final ids = await _channel.invokeListMethod<String>('placedWidgets');
    return ids ?? const [];
  } catch (e) {
    // An older build of the Android half, or no platform at all. Knowing
    // nothing is different from knowing there are none, and the caller
    // treats an empty list as "do not prune".
    debugPrint('[myemail] could not ask which widgets are placed: $e');
    return const [];
  }
}

void listenForWidgetSetup(void Function(String appWidgetId) onConfigure) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'configure') return null;
    final id = call.arguments;
    if (id is String && id.isNotEmpty) onConfigure(id);
    return null;
  });
}
