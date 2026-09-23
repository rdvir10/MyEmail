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

/// The widgets Android says are on the home screen right now, or null when
/// it could not be asked.
///
/// Asked for rather than remembered, because nothing tells the app when a
/// widget is dragged to the bin: without this, its mailbox would be
/// recounted at every sync forever after it had gone.
///
/// Null and empty are different answers. Both used to be an empty list,
/// read as "not known", so removing the last widget was never noticed: it
/// went on being counted, and Settings went on listing it.
Future<List<String>?> placedWidgetIds() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await _channel.invokeListMethod<String>('placedWidgets');
  } catch (e) {
    // An older build of the Android half, or no platform at all.
    debugPrint('[myemail] could not ask which widgets are placed: $e');
    return null;
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
