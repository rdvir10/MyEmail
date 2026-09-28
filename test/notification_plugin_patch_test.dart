import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The notifications plugin is a copy with one change, and the change is
/// the only reason the copy exists. Upgraded by copying a new version over
/// it, the change would go without a word; this says so.
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

  test('where the small icon is asked for, the large one goes', () {
    final java = File(pluginJava).readAsStringSync();
    final method = java.substring(
      java.indexOf('private static void preferSmallIcon('),
      java.indexOf('private static void setSmallIcon('),
    );
    final ask = method.indexOf('putBoolean((String) key, true);');
    final drop = method.indexOf('builder.setLargeIcon((android.graphics.Bitmap) null);');
    expect(ask, greaterThan(0));
    expect(drop, greaterThan(ask), reason: 'in the same branch, after it');
    expect(method.substring(ask, drop), isNot(contains('}')),
        reason: 'only where the small icon is asked for');
  });
}
