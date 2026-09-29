import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A notification's buttons are broadcasts to the plugin's receiver, and the
/// plugin's manifest does not declare it: the app has to. It never did, and
/// from 2.30.0 to 2.65.0 Reply, Reply all and Delete on a notification did
/// nothing at all, with nothing in any log to say why. No test ran anything
/// Android would deliver to, so this reads the manifests.
void main() {
  const app = 'android/app/src/main/AndroidManifest.xml';
  const plugin = 'third_party/flutter_local_notifications/android/src/main/'
      'java/com/dexterous/flutterlocalnotifications/'
      'FlutterLocalNotificationsPlugin.java';
  const receiver =
      'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver';

  test('the buttons are still broadcasts to the plugin receiver', () {
    // If the plugin ever stops sending them there, this test is about the
    // wrong class and needs rethinking, not deleting.
    expect(
      File(plugin).readAsStringSync(),
      contains('ActionBroadcastReceiver.class'),
    );
  });

  test('the app declares that receiver', () {
    final manifest = File(app).readAsStringSync();
    final declared = RegExp(
      r'<receiver\b[^>]*android:name="' + RegExp.escape(receiver) + r'"[^>]*>',
      multiLine: true,
    ).firstMatch(manifest);
    expect(declared, isNotNull, reason: 'every button press goes nowhere');
    expect(
      declared!.group(0),
      contains('android:exported="false"'),
      reason: 'only the notification itself may send to it',
    );
  });
}
