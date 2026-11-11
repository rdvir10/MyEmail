import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;
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

  /// Write [values] that changed, a null removing its key, and redraw the
  /// mailbox widgets. True when any value changed.
  ///
  /// Redrawn even when none did, as every refresh has redrawn them: a
  /// widget's size is worked out as it is drawn, and a tablet turned round
  /// since the last time is put right by the next.
  Future<bool> show(Map<String, Object?> values);

  /// The same for the calendar widget, from what `CalendarUpkeep` wrote.
  Future<void> redrawCalendar();
}

/// The name Android knows the widget by. It must match the receiver in
/// AndroidManifest.xml, and there is nothing to check it at compile time, so
/// it lives here once rather than at each call.
const mailboxWidgetProvider = 'MailboxCountWidgetProvider';

/// The calendar widget's, likewise.
const calendarWidgetProvider = 'CalendarWidgetProvider';

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

  @override
  Future<void> redrawCalendar() =>
      HomeWidget.updateWidget(androidName: calendarWidgetProvider);

  /// The app's own half of the widget, in MainActivity.
  static const _app = MethodChannel('mailtree/widget');

  /// Not there: this is the background isolate, which has the plugins and
  /// not MainActivity's channels.
  static bool _noApp = false;

  /// Every value in one call and one write, and the widgets drawn there and
  /// then rather than by a broadcast, where the app's own half is there to
  /// take them. The plugin writes one value per call and each to disk before
  /// it answers, and a refresh was twenty-odd of those in a row before the
  /// widget moved: the numbers changed a moment after you reached the home
  /// screen rather than as you got there.
  ///
  /// The background isolate goes through the plugin, reading each value
  /// first and writing only the ones that changed. A pass that changes
  /// nothing then writes nothing to disk, which is most passes.
  @override
  Future<bool> show(Map<String, Object?> values) async {
    if (!_noApp) {
      try {
        return await _app.invokeMethod<bool>('showValues', values) ?? false;
      } on MissingPluginException {
        _noApp = true;
      }
    }
    var changed = false;
    for (final MapEntry(:key, :value) in values.entries) {
      if (await HomeWidget.getWidgetData<Object>(key) == value) continue;
      await HomeWidget.saveWidgetData<Object>(key, value);
      changed = true;
    }
    await redraw();
    return changed;
  }
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

  @override
  Future<void> redrawCalendar() async {}

  @override
  Future<bool> show(Map<String, Object?> values) async => false;
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

  int calendarRedraws = 0;

  @override
  Future<void> redrawCalendar() async => calendarRedraws++;

  /// Values written by [show] that changed what was there.
  int writes = 0;

  @override
  Future<bool> show(Map<String, Object?> values) async {
    final before = writes;
    for (final MapEntry(:key, :value) in values.entries) {
      // A key that is not there reads as null, as on the phone.
      if (this.values[key] == value) continue;
      if (value == null) {
        this.values.remove(key);
      } else {
        this.values[key] = value;
      }
      writes++;
    }
    redraws++;
    return writes > before;
  }
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
