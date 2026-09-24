import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/updates/apk_installer.dart';
import 'package:myemail/data/updates/update_service.dart';
import 'package:myemail/domain/app_release.dart';

/// The real download and the real release check, against a server that
/// misbehaves. Every other updater test uses fakes that can do neither a
/// status code nor a download cut short, so a 404 page saved as the update,
/// or half an APK handed to Android, would have passed them all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the release check', () {
    UpdateService serviceOver(http.Client client) => UpdateService(
          feed: HttpReleaseFeed(url: 'https://example.com/latest.json', client: client),
          installed: FakeInstalledVersion(
            const InstalledVersion(version: '2.40.0', build: 60),
          ),
          manifestUrl: 'https://example.com/latest.json',
        );

    test('a 404 says what the server answered', () async {
      // What the feed is before the first release is published.
      final status = await serviceOver(
        http_testing.MockClient((_) async => http.Response('Not Found', 404)),
      ).check();

      expect(status, isA<UpdateCheckFailed>());
      expect((status as UpdateCheckFailed).reason, 'The server answered 404.');
    });

    test('a file that is not a manifest says it could not be read', () async {
      final status = await serviceOver(
        http_testing.MockClient((_) async => http.Response('[]', 200)),
      ).check();

      expect((status as UpdateCheckFailed).reason,
          'The update file could not be read.');
    });

    test('a newer build is offered', () async {
      final status = await serviceOver(
        http_testing.MockClient((_) async => http.Response(
              '{"version":"2.41.0","build":61,'
              '"apk":"https://example.com/myemail.apk"}',
              200,
            )),
      ).check();

      expect(status, isA<UpdateAvailable>());
    });

    test('notes read as written, whatever the file is served as', () async {
      // GitHub serves latest.json as application/octet-stream, which was
      // read as Latin-1: a dash came out as "â" and control characters.
      final status = await serviceOver(
        http_testing.MockClient((_) async => http.Response.bytes(
              utf8.encode('{"version":"2.41.0","build":61,'
                  '"apk":"https://example.com/myemail.apk",'
                  '"notes":"Drafts — faster, and שלום"}'),
              200,
              headers: const {'content-type': 'application/octet-stream'},
            )),
      ).check();

      expect((status as UpdateAvailable).release.notes,
          'Drafts — faster, and שלום');
    });

    testWidgets('a server that never answers gives up', (tester) async {
      // Fifteen seconds, then a sentence, rather than a spinner for ever.
      final never = Completer<http.Response>();
      final check = serviceOver(
        http_testing.MockClient((_) => never.future),
      ).check();
      UpdateStatus? status;
      unawaited(check.then((s) => status = s));

      await tester.pump(const Duration(seconds: 14));
      expect(status, isNull);
      await tester.pump(const Duration(seconds: 2));

      expect((status! as UpdateCheckFailed).reason,
          'Could not reach the update server.');
    });
  });

  group('the download', () {
    late Directory dir;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() {
      dir = Directory.systemTemp.createTempSync('myemail-update-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => dir.path);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });

    const release = AppRelease(
      version: '2.41.0',
      build: 61,
      apkUrl: 'https://example.com/myemail.apk',
      sizeBytes: 100,
    );

    File saved() => File('${dir.path}/mailtree-update.apk');

    AndroidApkInstaller over(
      int status,
      List<int> bytes, {
      int? contentLength,
    }) =>
        AndroidApkInstaller(
          client: http_testing.MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream.value(bytes),
              status,
              contentLength: contentLength,
            ),
          ),
        );

    test('a whole file is kept, and says it is done', () async {
      final progress = <double>[];

      final path = await over(200, List.filled(100, 7), contentLength: 100)
          .download(release, onProgress: progress.add);

      expect(File(path).readAsBytesSync(), hasLength(100));
      expect(progress.last, 1);
    });

    test('a download cut short throws and leaves no file behind', () async {
      // Handed to Android, half an APK fails with an error that says
      // nothing useful.
      await expectLater(
        over(200, List.filled(40, 7), contentLength: 100).download(release),
        throwsA(isA<SocketException>()),
      );
      expect(saved().existsSync(), isFalse);
    });

    test('short of what the release said, with no length given, too',
        () async {
      await expectLater(
        over(200, List.filled(40, 7)).download(release),
        throwsA(isA<SocketException>()),
      );
      expect(saved().existsSync(), isFalse);
    });

    test('a refusal throws before anything is written', () async {
      // GitHub's error page saved as mailtree-update.apk, and the last good
      // download deleted for it.
      saved().writeAsStringSync('the last good download');

      await expectLater(
        over(500, 'Server error'.codeUnits).download(release),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          'The download answered 500.',
        )),
      );
      expect(saved().readAsStringSync(), 'the last good download');
    });

    test('a download that goes quiet part way fails, and keeps nothing',
        () async {
      // A dropped connection raises nothing by itself, and About said
      // "Downloading 40%" until the app was killed.
      final quiet = StreamController<List<int>>()..add(List.filled(40, 7));
      addTearDown(quiet.close);
      final installer = AndroidApkInstaller(
        stallLimit: const Duration(milliseconds: 50),
        client: http_testing.MockClient.streaming(
          (_, _) async =>
              http.StreamedResponse(quiet.stream, 200, contentLength: 100),
        ),
      );

      await expectLater(
        installer.download(release),
        throwsA(isA<SocketException>()),
      );
      expect(saved().existsSync(), isFalse);
    });

    test('so does a server that never starts answering', () async {
      final installer = AndroidApkInstaller(
        stallLimit: const Duration(milliseconds: 50),
        client: http_testing.MockClient.streaming(
          (_, _) => Completer<http.StreamedResponse>().future,
        ),
      );

      await expectLater(
        installer.download(release),
        throwsA(isA<SocketException>()),
      );
    });

    test('comes from the build the manifest names, not whatever is newest',
        () async {
      // The manifest names a release by its tag. A link to "latest" fetched
      // a build published after the check, which the screen did not name
      // and whose minBuild nobody had looked at.
      final manifest = AppRelease.fromJson({
        'version': '2.41.0',
        'build': 61,
        'apk': 'https://github.com/rdvir10/MyEmail/releases/download/'
            'v2.41.0/myemail-arm64.apk',
        'sizeBytes': 100,
      })!;
      final asked = <Uri>[];
      final installer = AndroidApkInstaller(
        client: http_testing.MockClient.streaming((request, _) async {
          asked.add(request.url);
          return http.StreamedResponse(
              Stream.value(List.filled(100, 7)), 200,
              contentLength: 100);
        }),
      );

      await installer.download(manifest);

      expect(asked.single.toString(),
          'https://github.com/rdvir10/MyEmail/releases/download/v2.41.0/myemail-arm64.apk');
    });
  });
}
