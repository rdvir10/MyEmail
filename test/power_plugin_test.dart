import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// packages/myemail_power is ours, and nothing but a phone runs its Java.
/// A method renamed on one side only would answer every question with the
/// Dart side's fallback, which for "is the foreground service running" is
/// yes: a refused worker would go back to living on with no service.
void main() {
  const dart = 'packages/myemail_power/lib/myemail_power.dart';
  const java = 'packages/myemail_power/android/src/main/java/com/rdvir/'
      'myemail/power/MyEmailPowerPlugin.java';
  const manifest = 'packages/myemail_power/android/src/main/AndroidManifest.xml';

  test('every method the app asks for is one the plugin answers', () {
    final asked = RegExp(r"_ask\('(\w+)'")
        .allMatches(File(dart).readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();
    final answered = RegExp(r'case "(\w+)":')
        .allMatches(File(java).readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();

    expect(asked, {
      'isIgnoringBatteryOptimizations',
      'requestIgnoreBatteryOptimizations',
      'foregroundServiceRunning',
    });
    expect(answered, containsAll(asked));
  });

  test('both sides use the same channel', () {
    expect(File(dart).readAsStringSync(), contains("'myemail/power'"));
    expect(File(java).readAsStringSync(), contains('"myemail/power"'));
  });

  test('the app may show the dialog it asks for', () {
    // Without the permission Android ignores the request and nothing
    // appears.
    expect(
      File(manifest).readAsStringSync(),
      contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'),
    );
  });
}
