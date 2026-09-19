import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The icons, and the two ways they go missing without anyone noticing.
///
/// The first is the status bar. Android draws a notification icon from its
/// alpha channel alone, so the launcher icon — opaque to its corners — comes
/// out as a plain white square. It needs a silhouette of its own.
///
/// The second is worse, because it only happens in a release build. Anything
/// the Android half does not reference is stripped when the app is packaged,
/// and the notification icon is named nowhere but in a Dart string. It was
/// dropped from the APK exactly once, which is what these tests are here to
/// prevent happening twice.
void main() {
  const res = 'android/app/src/main/res';
  const densities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];

  String read(String path) => File(path).readAsStringSync();

  test('the notification icon the Dart side asks for exists', () {
    final source = read('lib/data/notifications/android_mail_notifier.dart');
    final asked = RegExp(r"AndroidInitializationSettings\('@drawable/(\w+)'\)")
        .firstMatch(source);
    expect(asked, isNotNull,
        reason: 'the notifier names its icon in one place, and this is it');
    final name = asked!.group(1)!;

    for (final density in densities) {
      expect(
        File('$res/drawable-$density/$name.png').existsSync(),
        isTrue,
        reason: '$name is missing at $density',
      );
    }
  });

  test('and survives the shrinker', () {
    // A release build strips resources nothing in the Android half refers to.
    // res/raw/keep.xml is the list of exceptions.
    final source = read('lib/data/notifications/android_mail_notifier.dart');
    final name = RegExp(r"AndroidInitializationSettings\('@drawable/(\w+)'\)")
        .firstMatch(source)!
        .group(1)!;

    expect(read('$res/raw/keep.xml'), contains('@drawable/$name'));
  });

  test('the launcher icon is there at every size', () {
    for (final density in densities) {
      expect(
        File('$res/mipmap-$density/ic_launcher.png').existsSync(),
        isTrue,
        reason: 'launcher icon missing at $density',
      );
    }
  });

  test('and is adaptive on the versions that ask for it', () {
    // Both layers, because a foreground on its own shows the launcher's
    // default grey behind it as the icon is tilted.
    final adaptive = read('$res/mipmap-anydpi-v26/ic_launcher.xml');

    expect(adaptive, contains('ic_launcher_background'));
    expect(adaptive, contains('ic_launcher_foreground'));
    expect(adaptive, contains('monochrome'),
        reason: 'themed icons on Android 13 need a flat one-colour layer');
    for (final layer in [
      'ic_launcher_background',
      'ic_launcher_foreground',
      'ic_launcher_monochrome',
    ]) {
      expect(File('$res/drawable/$layer.xml').existsSync(), isTrue,
          reason: layer);
    }
  });

  test('the widget icon is a tintable tile and a glyph, not one bitmap', () {
    // The tile is coloured per widget, so it cannot be a picture with one
    // colour baked into it. It is a white shape the widget tints, with the
    // dart drawn over the top.
    final layout = read('$res/layout/mailbox_count_widget.xml');

    expect(layout, contains('@drawable/mailbox_widget_tile'));
    expect(layout, contains('@drawable/ic_launcher_foreground'));
    expect(
      File('$res/drawable/mailbox_widget_tile.xml').existsSync(),
      isTrue,
    );
    // White, or a colour filter over it comes out muddied by whatever was
    // underneath.
    expect(read('$res/drawable/mailbox_widget_tile.xml'), contains('#FFFFFFFF'));
  });
}
