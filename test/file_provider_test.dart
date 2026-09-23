import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The one FileProvider, and everything that has to agree with it.
///
/// The updater hands Android's installer the downloaded APK through this
/// provider, and attachments are opened, shared and dragged through it.
/// In 2.10.0 a second provider element of the same class broke the
/// updater on every phone: Android makes one instance per class, the
/// second authority was served by an instance that knew only the first
/// one's paths, and the installer was handed a URL it could not open. An
/// updater that cannot install cannot deliver its own fix, so every device
/// needed a reinstall by hand.
///
/// Nothing else in the suite reads these files, and a mismatch between them
/// fails only on a device, after a release.
void main() {
  const main = 'android/app/src/main';
  String read(String path) => File(path).readAsStringSync();

  final manifest = read('$main/AndroidManifest.xml');

  test('there is exactly one FileProvider', () {
    expect(
      'androidx.core.content.FileProvider'.allMatches(manifest).length,
      1,
      reason: 'a second one of the same class is the 2.10.0 failure',
    );
  });

  final provider = RegExp(
    r'<provider\b[^>]*androidx\.core\.content\.FileProvider[\s\S]*?</provider>',
  ).firstMatch(manifest)?.group(0);

  test('it answers to both names, and is not exported', () {
    expect(provider, isNotNull);
    final authorities =
        RegExp(r'android:authorities="([^"]*)"').firstMatch(provider!)!.group(1)!;
    expect(authorities.split(';'),
        containsAll([r'${applicationId}.updates', r'${applicationId}.files']));
    expect(provider, contains('android:exported="false"'));
    expect(provider, contains('android:grantUriPermissions="true"'));
  });

  test('the Kotlin asks for the names the manifest gives', () {
    expect(read('$main/kotlin/com/rdvir/mailtree/MainActivity.kt'),
        contains(r'"$packageName.updates"'),
        reason: 'the authority the installer URI is built with');
    expect(read('$main/kotlin/com/rdvir/mailtree/FilesBridge.kt'),
        contains(r'.files"'));
  });

  test('its paths cover where the update is written', () {
    final resource = RegExp(r'android:resource="@xml/(\w+)"')
        .firstMatch(provider!)!
        .group(1)!;
    final paths = read('$main/res/xml/$resource.xml');
    // apk_installer writes into getApplicationSupportDirectory, which on
    // Android is the app's files directory: files-path.
    expect(read('lib/data/updates/apk_installer.dart'),
        contains('getApplicationSupportDirectory'));
    expect(paths, contains('<files-path'));
  });
}
