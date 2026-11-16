import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The notifications plugin is a copy with two changes, and they are the
/// only reason the copy exists. Upgraded by copying a new version over it,
/// they would go without a word; this says so.
void main() {
  const pluginJava = 'third_party/flutter_local_notifications/android/src/'
      'main/java/com/dexterous/flutterlocalnotifications/'
      'FlutterLocalNotificationsPlugin.java';

  test('the app uses the copy', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'dependency_overrides:\s*\n\s*flutter_local_notifications:\s*\n'
              r'\s*path: third_party/flutter_local_notifications')
          .hasMatch(pubspec),
      isTrue,
    );
  });

  test('every notification asks Android 17 for the small icon', () {
    final java = File(pluginJava).readAsStringSync();
    expect(java, contains('getField("EXTRA_PREFER_SMALL_ICON")'));
    final build = java.indexOf('Notification notification = builder.build();');
    final call = java.lastIndexOf('preferSmallIcon(builder);', build);
    expect(build, greaterThan(0));
    expect(call, greaterThan(0), reason: 'asked for before the build');
    expect(java.substring(call, build).split('\n'), hasLength(2),
        reason: 'on the line straight before it');
  });

  test("every button's intent is its own, whatever the request code", () {
    // Two notifications could share their buttons, and Delete on one
    // deleted the other's message.
    final java = File(pluginJava).readAsStringSync();
    final extras = java.indexOf('.putExtra(PAYLOAD, notificationDetails.payload);',
        java.indexOf('actionIntent\n'));
    final unique = java.indexOf(
        'uniqueButtonIntent(actionIntent, notificationDetails, action);');
    final pending = java.indexOf('PendingIntent.getBroadcast(context, requestCode++');
    expect(extras, greaterThan(0));
    expect(unique, greaterThan(extras), reason: 'after the extras');
    expect(pending, greaterThan(unique), reason: 'before the PendingIntent');
    final method = java.substring(
      java.indexOf('private static void uniqueButtonIntent('),
      java.indexOf('private static void preferSmallIcon('),
    );
    for (final part in ['details.id', 'details.tag', 'action.id']) {
      expect(method, contains(part));
    }
    expect(method, contains('intent.setData('));
  });

  // Ron's tablet (Samsung, One UI 8.5 on Android 16, 2026-11-16) has the
  // key from API 36.1, takes the request, and draws the app's launcher icon
  // all the same. With the large icon taken away there, a notification
  // showed neither the account's colour nor a calendar: every picture the
  // app handed over, as a file or as itself, was dropped right here.
  test('where the small icon is asked for, the large one goes, but not '
      'where the shade draws the launcher icon whatever is asked', () {
    final java = File(pluginJava).readAsStringSync();
    final method = java.substring(
      java.indexOf('private static void preferSmallIcon('),
      java.indexOf('private static boolean drawsLauncherIconWhateverIsAsked('),
    );
    final ask = method.indexOf('putBoolean((String) key, true);');
    final drop = method.indexOf('builder.setLargeIcon((android.graphics.Bitmap) null);');
    expect(ask, greaterThan(0));
    expect(drop, greaterThan(ask), reason: 'in the same branch, after it');
    final between = method.substring(ask, drop);
    expect(between, isNot(contains('}')),
        reason: 'only where the small icon is asked for');
    expect(between, contains('if (!drawsLauncherIconWhateverIsAsked()) {'),
        reason: 'and only where asking gets it shown');

    final samsung = java.substring(
      java.indexOf('private static boolean drawsLauncherIconWhateverIsAsked('),
      java.indexOf('private static void setSmallIcon('),
    );
    expect(samsung, contains('"samsung".equalsIgnoreCase(Build.MANUFACTURER)'));
    expect(java, contains('import android.os.Build;'));
  });
}
