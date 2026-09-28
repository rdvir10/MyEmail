import 'package:flutter/services.dart';

/// Whether Android lets MyEmail keep running in the background.
///
/// Android only. Everywhere else there is no such thing to ask about, and
/// each call answers as if it were allowed rather than throwing.
class MyEmailPower {
  const MyEmailPower();

  static const _channel = MethodChannel('myemail/power');

  /// Whether the app is "Unrestricted" in Android's battery settings.
  Future<bool> isIgnoringBatteryOptimizations() =>
      _ask('isIgnoringBatteryOptimizations', orElse: true);

  /// Show Android's dialog asking to let the app run in the background.
  /// Whether anything could be shown; the answer is read afterwards with
  /// [isIgnoringBatteryOptimizations].
  Future<bool> requestIgnoreBatteryOptimizations() =>
      _ask('requestIgnoreBatteryOptimizations', orElse: false);

  /// Whether one of the app's services is running in the foreground.
  Future<bool> foregroundServiceRunning() =>
      _ask('foregroundServiceRunning', orElse: true);

  static Future<bool> _ask(String method, {required bool orElse}) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? orElse;
    } on MissingPluginException {
      return orElse;
    }
  }
}
