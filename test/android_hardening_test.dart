import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What another app on the phone, or Android's own backup, can get at.
///
/// These are settings and guards in the Android half, which no Dart test
/// runs. Each was a way out for private mail or sign-ins, so each is checked
/// where it is written.
void main() {
  const main = 'android/app/src/main';
  String read(String path) => File(path).readAsStringSync();
  final manifest = read('$main/AndroidManifest.xml');
  final application =
      RegExp(r'<application\b[^>]*>').firstMatch(manifest)!.group(0)!;

  group('Android backup', () {
    // Left on, the mail cache went to the Google backup, and a restore
    // brought back secure storage without the key that opens it.
    test('is off', () {
      expect(application, contains('android:allowBackup="false"'));
      expect(application, contains('android:fullBackupContent="false"'));
    });

    test('and nothing goes in a cloud backup or a device transfer', () {
      final rules = RegExp(r'android:dataExtractionRules="@xml/(\w+)"')
          .firstMatch(application)
          ?.group(1);
      expect(rules, isNotNull,
          reason: 'on Android 12 and later, allowBackup alone still lets a '
              'device-to-device transfer through');
      final xml = read('$main/res/xml/$rules.xml');
      for (final section in ['cloud-backup', 'device-transfer']) {
        final body =
            RegExp('<$section>([\\s\\S]*?)</$section>').firstMatch(xml)?.group(1);
        expect(body, isNotNull, reason: section);
        expect(body, contains('<exclude domain="root" path="." />'),
            reason: section);
      }
    });
  });

  group('routes from outside', () {
    // The main activity is exported. Started on a window route naming a
    // file, the app used to read that file and delete it.
    test('the main activity takes none', () {
      expect(read('$main/kotlin/com/rdvir/mailtree/MainActivity.kt'),
          contains('if (this is WindowActivity) super.getInitialRoute() else null'));
    });

    test('and deep links are off on every Flutter activity', () {
      final activities = RegExp(r'<activity\b[\s\S]*?</activity>')
          .allMatches(manifest)
          .map((m) => m.group(0)!)
          .toList();
      expect(activities, hasLength(2));
      for (final activity in activities) {
        expect(
          activity,
          matches(RegExp(r'flutter_deeplinking_enabled"\s+android:value="false"')),
          reason: RegExp(r'android:name="([^"]+)"').firstMatch(activity)!.group(1),
        );
      }
    });
  });

  group('files handed in by other apps', () {
    final bridge = read('$main/kotlin/com/rdvir/mailtree/FilesBridge.kt');

    // Copied with the app's own permissions, a file:// path or the app's
    // own provider reached the mail database and the stored sign-ins.
    test('are checked before anything is read', () {
      final copyIn = RegExp(
        r'private fun copyIn\(uris: List<Uri>\)[\s\S]*?openInputStream',
      ).firstMatch(bridge)?.group(0);
      expect(copyIn, isNotNull);
      expect(copyIn, contains('if (!mayCopyIn(uri))'));
      expect(bridge, contains('if (uri.scheme != ContentResolver.SCHEME_CONTENT) return false'));
    });

    test("the app's own files allowed back in are the ones it hands out", () {
      // A drag between two of the app's windows carries its own URI. The
      // folders allowed must be the folders the Dart side writes to.
      final folders = RegExp(r'SHARED_CACHE_FOLDERS = listOf\(([^)]*)\)')
          .firstMatch(bridge)!
          .group(1)!;
      expect(folders, contains('"attachments"'));
      expect(folders, contains('"eml"'));
      expect(folders, contains('"incoming"'));
      expect(read('lib/data/files/attachment_files.dart'),
          contains('/attachments/'));
      expect(read('lib/data/files/message_files.dart'),
          contains("'eml',"));
      expect(bridge, contains('File(activity.cacheDir, "incoming")'));
    });

    // Named by its display name alone, the second of two files called
    // Scan.pdf overwrote the first, and both attachments held it.
    test('each is copied into a folder of its own', () {
      final copyIn = RegExp(
        r'private fun copyIn\(uris: List<Uri>\)[\s\S]*?openInputStream',
      ).firstMatch(bridge)!.group(0)!;
      expect(copyIn,
          contains('File(incoming, UUID.randomUUID().toString())'));
      expect(copyIn, contains('File(folder, fileNameFor(name))'));
    });

    // Over 255 bytes, which is 128 Hebrew letters, the copy failed and the
    // file was left out without a word.
    test('under a name the disk will take', () {
      final name = RegExp(r'private fun fileNameFor\([\s\S]*?\n    }')
          .firstMatch(bridge)!
          .group(0)!;
      expect(name, contains('toByteArray().size <= 255'));
      expect(name, contains("trimStart('.')"));
      expect(name, contains('Character.toChars'),
          reason: 'cut between characters, not through one');
    });

    // A long video, or a photo that lives only in the cloud, copied on the
    // main thread froze the app until Android offered to close it.
    test('off the main thread', () {
      final calls = RegExp(r'(?<!fun )\bcopyIn\(').allMatches(bridge).toList();
      expect(calls, hasLength(1), reason: 'only copyInBackground copies');
      final background = RegExp(
        r'private fun copyInBackground\([\s\S]*?\n    }',
      ).firstMatch(bridge)!.group(0)!;
      expect(background, contains('copier.execute {'));
      expect(background, contains('copyIn(uris)'));
      expect(background, contains('main.post { done(incoming) }'));
      expect(bridge, contains('Executors.newSingleThreadExecutor()'));
      // A drop's read permission is held until the copy is done.
      final drop = RegExp(r'private fun handleDrop\([\s\S]*?\n    }')
          .firstMatch(bridge)!
          .group(0)!;
      expect(
        drop.indexOf('permissions?.release()'),
        greaterThan(drop.indexOf('copyInBackground(uris) {')),
      );
    });

    // Android restarts a stopped app with the intent it was first started
    // with. A share sent an hour ago opened a new message with the same
    // files again.
    test('a share is taken once, not again when Android restarts the app',
        () {
      final activity = read('$main/kotlin/com/rdvir/mailtree/MainActivity.kt');
      final onCreate = RegExp(r'override fun onCreate\([\s\S]*?\n    }')
          .firstMatch(activity)!
          .group(0)!;
      expect(onCreate, contains('savedInstanceState != null'));
      expect(onCreate, contains('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY'));
      expect(onCreate.indexOf('restarted ='),
          lessThan(onCreate.indexOf('super.onCreate')),
          reason: 'configureFlutterEngine runs inside super.onCreate');
      expect(activity,
          contains('if (!restarted) it.takeShare(intent, pushNow = false)'));
    });
  });

  group('printing', () {
    // A meta refresh in a message sent the print WebView to the sender's
    // page, which then printed as well.
    test('the page being printed cannot go anywhere, and prints once', () {
      final print = read('$main/kotlin/com/rdvir/mailtree/PrintBridge.kt');
      expect(
        RegExp(r'override fun shouldOverrideUrlLoading\([^)]*\) = true')
            .allMatches(print),
        hasLength(2),
      );
      expect(print, contains('if (printed) return'));
    });
  });
}
