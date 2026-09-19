import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:home_widget/home_widget.dart';

/// The home screen, as far as this app is concerned: a place to put a few
/// values and a way to tell Android they changed.
///
/// A port rather than direct calls to the plugin, for the usual reason —
/// everything interesting about what the widget shows can then be tested
/// without a phone. The real one talks to the plugin; the fake records.
abstract class HomeScreenSurface {
  Future<void> putString(String key, String? value);
  Future<void> putInt(String key, int value);
  Future<String?> getString(String key);

  /// Ask Android to redraw the widgets. Values written before this are what
  /// it will draw, so this is always the last call.
  Future<void> redraw();
}

/// The name Android knows the widget by. It must match the receiver in
/// AndroidManifest.xml, and there is nothing to check it at compile time, so
/// it lives here once rather than at each call.
const mailboxWidgetProvider = 'MailboxCountWidgetProvider';

class AndroidHomeScreenSurface implements HomeScreenSurface {
  const AndroidHomeScreenSurface();

  @override
  Future<void> putString(String key, String? value) =>
      HomeWidget.saveWidgetData<String>(key, value);

  @override
  Future<void> putInt(String key, int value) =>
      HomeWidget.saveWidgetData<int>(key, value);

  @override
  Future<String?> getString(String key) => HomeWidget.getWidgetData<String>(key);

  @override
  Future<void> redraw() =>
      HomeWidget.updateWidget(androidName: mailboxWidgetProvider);
}

/// Does nothing, for the browser preview and anywhere else without a home
/// screen to put a widget on.
class NoHomeScreenSurface implements HomeScreenSurface {
  const NoHomeScreenSurface();

  @override
  Future<void> putString(String key, String? value) async {}

  @override
  Future<void> putInt(String key, int value) async {}

  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> redraw() async {}
}

/// Records what it was asked to show. The default in tests.
class FakeHomeScreenSurface implements HomeScreenSurface {
  final Map<String, Object?> values = {};
  int redraws = 0;

  @override
  Future<void> putString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> putInt(String key, int value) async => values[key] = value;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> redraw() async => redraws++;
}

/// The one to use on this device.
HomeScreenSurface homeScreenSurface() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const AndroidHomeScreenSurface()
        : const NoHomeScreenSurface();

/// The widget id the app was opened to configure, or null in the ordinary
/// case of someone tapping the app icon.
///
/// Android launches the app with a configure intent when a widget is dropped
/// on the home screen, and expects it to be told which widget was set up.
/// Until [finishWidgetSetup] is called the placement is cancelled, which is
/// the right default: an app that crashed halfway through should leave no
/// widget behind.
Future<String?> widgetAwaitingSetup() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await HomeWidget.initiallyLaunchedFromHomeWidgetConfigure();
  } catch (e) {
    debugPrint('[myemail] could not read the widget configure intent: $e');
    return null;
  }
}

/// Tell Android the placement is done, which closes the app back to the home
/// screen with the widget in place.
///
/// Guarded the same way as [widgetAwaitingSetup]: there is no placement to
/// finish anywhere but Android, and a failure here must not leave someone
/// stuck on the picker with no way back.
Future<void> finishWidgetSetup() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await HomeWidget.finishHomeWidgetConfigure();
  } catch (e) {
    debugPrint('[myemail] could not finish the widget placement: $e');
  }
}
