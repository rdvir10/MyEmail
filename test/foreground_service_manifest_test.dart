import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/sync_prefs.dart';

/// The Dart side asks Android to run background sync as a `dataSync`
/// foreground service. Android refuses unless the service is *declared* with
/// that type, and it refuses by killing the process, at every launch, for
/// anyone who has chosen one of the two foreground sync modes.
///
/// The declaration is not in our manifest. It comes from the workmanager
/// plugin, which ships two manifests and picks between them on a Gradle flag:
/// without the flag the service is `shortService` only, and asking for
/// `dataSync` throws
///
///   IllegalArgumentException: foregroundServiceType 0x00000001 is not a
///   subset of foregroundServiceType attribute 0x00000800
///
/// which reads on the device as "the app opens and closes instantly".
///
/// That shipped. Nothing caught it, because the crash needs a foreground sync
/// mode to be switched on and sync is off by default, so every test here and
/// every emulator run started cleanly. These tests are the cheap standing
/// check that the Dart request and the Android declaration still agree.
void main() {
  group('the foreground service the sync modes need', () {
    test('two sync modes ask for one, so the build must allow it', () {
      // If this ever becomes false, the Gradle flag below is dead weight and
      // should go with whatever removed the need for it.
      expect(
        SyncMode.values.where((m) => m.needsForegroundService),
        isNotEmpty,
      );
    });

    test('gradle.properties opts in to the dataSync foreground service', () {
      final properties = File('android/gradle.properties');
      expect(properties.existsSync(), isTrue,
          reason: 'android/gradle.properties is where the opt-in lives');

      expect(
        properties.readAsStringSync(),
        contains('workmanager.enableDataSyncForegroundService=true'),
        reason: 'Without this the workmanager plugin declares its foreground '
            'service as shortService only. The app then asks Android to start '
            'it as dataSync, and Android kills the process at launch for '
            'anyone using the five-minute or push sync modes.',
      );
    });

    test('the manifest still declares the matching permission', () {
      // Android 14+ wants a permission per foreground service type. The
      // plugin adds it through its own manifest; ours has carried it since
      // the sync modes landed, and losing it would be the same crash wearing
      // a different message.
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      );
    });
  });
}
