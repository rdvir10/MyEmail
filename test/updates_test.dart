import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myemail/data/updates/apk_installer.dart';
import 'package:myemail/data/updates/update_service.dart';
import 'package:myemail/domain/app_release.dart';
import 'package:myemail/state/update_providers.dart';
import 'package:myemail/ui/settings/about_screen.dart';

const _installed = InstalledVersion(version: '1.0.0', build: 4);

Map<String, dynamic> _manifest({
  int build = 5,
  String version = '1.1.0',
  String apk = 'https://example.com/mailtree.apk',
  int? minBuild,
  int? sizeBytes,
  String? notes,
}) =>
    {
      'version': version,
      'build': build,
      'apk': apk,
      'minBuild': ?minBuild,
      'sizeBytes': ?sizeBytes,
      'notes': ?notes,
    };

void main() {
  group('AppRelease', () {
    test('compares on the build number, not the version string', () {
      // Every version-string scheme has an edge that bites: "1.10" against
      // "1.9", a trailing "-beta", a build that forgot to bump the string.
      final release = AppRelease.fromJson(_manifest(build: 5, version: '0.9'))!;
      expect(release.isNewerThan(4), isTrue);
      expect(release.isNewerThan(5), isFalse);
      expect(release.isNewerThan(6), isFalse);
    });

    test('refuses a manifest without the fields that matter', () {
      expect(AppRelease.fromJson({}), isNull);
      expect(AppRelease.fromJson({'build': 5}), isNull);
      expect(AppRelease.fromJson({'apk': 'https://x/a.apk'}), isNull);
      expect(AppRelease.fromJson({'build': '5', 'apk': 'https://x/a.apk'}),
          isNull,
          reason: 'a build number that is a string is a broken manifest');
    });

    test('refuses an APK offered over plain http', () {
      // It is about to be installed. An APK fetched over http is whatever the
      // network between here and there decided to hand back.
      expect(
        AppRelease.fromJson(_manifest(apk: 'http://example.com/mailtree.apk')),
        isNull,
      );
      expect(AppRelease.fromJson(_manifest(apk: '')), isNull);
    });

    test('the compatibility gate keeps a payload off an install that cannot '
        'take it', () {
      final release = AppRelease.fromJson(_manifest(build: 9, minBuild: 7))!;
      expect(release.canBeInstalledOver(8), isTrue);
      expect(release.canBeInstalledOver(6), isFalse);
      expect(release.canBeInstalledOver(7), isTrue, reason: 'the floor counts');
    });

    test('no minBuild means anything may take it', () {
      expect(AppRelease.fromJson(_manifest())!.canBeInstalledOver(1), isTrue);
    });

    test('the size reads as something a person can judge', () {
      expect(
        AppRelease.fromJson(_manifest(sizeBytes: 23308977))!.readableSize,
        '22.2 MB',
      );
      expect(AppRelease.fromJson(_manifest())!.readableSize, isNull);
    });

    test('an empty version falls back to the build rather than showing blank',
        () {
      expect(AppRelease.fromJson(_manifest(version: ''))!.version, '5');
    });

    test('round-trips through JSON', () {
      final release =
          AppRelease.fromJson(_manifest(minBuild: 2, sizeBytes: 100, notes: 'x'))!;
      expect(AppRelease.fromJson(release.toJson()), release);
    });
  });

  group('UpdateService', () {
    UpdateService service(FakeReleaseFeed feed) => UpdateService(
          feed: feed,
          installed: FakeInstalledVersion(_installed),
        );

    test('a newer build is offered', () async {
      final status = await service(
        FakeReleaseFeed(manifest: _manifest(build: 5)),
      ).check();
      expect(status, isA<UpdateAvailable>());
    });

    test('the same build is up to date', () async {
      final status = await service(
        FakeReleaseFeed(manifest: _manifest(build: 4)),
      ).check();
      expect(status, isA<UpToDate>());
    });

    test('an older build on the server is up to date, not a downgrade',
        () async {
      final status = await service(
        FakeReleaseFeed(manifest: _manifest(build: 2)),
      ).check();
      expect(status, isA<UpToDate>());
    });

    test('too far behind is said out loud, not reported as up to date',
        () async {
      // The worst option is telling someone several versions behind that they
      // are current.
      final status = await service(
        FakeReleaseFeed(manifest: _manifest(build: 9, minBuild: 7)),
      ).check();
      expect(status, isA<UpdateTooOld>());
    });

    test('no feed configured reads as up to date, not as an error', () async {
      final status = await service(FakeReleaseFeed()).check();
      expect(status, isA<UpToDate>());
    });

    test('a broken manifest is a readable sentence, not an exception',
        () async {
      final status = await service(
        FakeReleaseFeed(manifest: {'nonsense': true}),
      ).check();
      expect(status, isA<UpdateCheckFailed>());
      expect((status as UpdateCheckFailed).reason, isNot(contains('Exception')));
    });

    test('a network failure never escapes as an exception', () async {
      // A check that throws on a settings screen is a red error box where a
      // line of text belongs.
      final status = await service(
        FakeReleaseFeed(error: Exception('no route to host')),
      ).check();
      expect(status, isA<UpdateCheckFailed>());
      expect(
        (status as UpdateCheckFailed).reason,
        'Could not reach the update server.',
      );
      expect(status.installed.build, 4,
          reason: 'it still knows what is installed');
    });
  });

  group('the update flow', () {
    late FakeReleaseFeed feed;
    late FakeApkInstaller installer;

    setUp(() {
      feed = FakeReleaseFeed(manifest: _manifest(build: 5));
      installer = FakeApkInstaller();
    });

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          releaseFeedProvider.overrideWithValue(feed),
          apkInstallerProvider.overrideWithValue(installer),
          installedVersionProvider
              .overrideWithValue(FakeInstalledVersion(_installed)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('check then download then install', () async {
      final c = container();
      await c.read(updateFlowProvider.notifier).check();

      final checked = c.read(updateFlowProvider) as UpdateChecked;
      final release = (checked.status as UpdateAvailable).release;
      await c.read(updateFlowProvider.notifier).downloadAndInstall(release);

      expect(installer.downloaded.single.build, 5);
      expect(installer.installed.single, '/fake/mailtree-update.apk');
      expect(c.read(updateFlowProvider), isA<UpdateReadyToInstall>());
    });

    test('permission is asked for after the download, not before', () async {
      // A refusal must not also throw away twenty megabytes.
      installer.permitted = false;
      final c = container();
      final release = AppRelease.fromJson(_manifest(build: 5))!;

      await c.read(updateFlowProvider.notifier).downloadAndInstall(release);

      expect(installer.downloaded, hasLength(1), reason: 'it downloaded first');
      expect(installer.installed, isEmpty);
      expect(c.read(updateFlowProvider), isA<UpdateNeedsPermission>());
    });

    test('retrying after granting permission does not download again',
        () async {
      installer.permitted = false;
      final c = container();
      final release = AppRelease.fromJson(_manifest(build: 5))!;
      await c.read(updateFlowProvider.notifier).downloadAndInstall(release);

      installer.permitted = true;
      final waiting = c.read(updateFlowProvider) as UpdateNeedsPermission;
      await c
          .read(updateFlowProvider.notifier)
          .retryInstall(release, waiting.path);

      expect(installer.downloaded, hasLength(1), reason: 'still just the one');
      expect(installer.installed, hasLength(1));
    });

    test('a failed download is a message, not a crash', () async {
      installer.downloadError = Exception('the download ended early');
      final c = container();
      final release = AppRelease.fromJson(_manifest(build: 5))!;

      await c.read(updateFlowProvider.notifier).downloadAndInstall(release);

      expect(c.read(updateFlowProvider), isA<UpdateFailed>());
    });
  });

  group('About screen', () {
    late FakeReleaseFeed feed;
    late FakeApkInstaller installer;

    setUp(() {
      feed = FakeReleaseFeed();
      installer = FakeApkInstaller();
    });

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(
        overrides: [
          releaseFeedProvider.overrideWithValue(feed),
          apkInstallerProvider.overrideWithValue(installer),
          installedVersionProvider
              .overrideWithValue(FakeInstalledVersion(_installed)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AboutScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('shows the version and build, so a silent failure can be '
        'diagnosed from the phone', (tester) async {
      await pump(tester);
      expect(find.text('Version 1.0.0, build 4'), findsOneWidget);
    });

    testWidgets('offers a check, because this build has an update URL',
        (tester) async {
      await pump(tester);
      expect(find.text('Check for updates'), findsOneWidget);
    });

    testWidgets('says plainly when updates are not set up', (tester) async {
      // A build made without an update URL. The screen must say so rather
      // than show a button that can only fail.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(
        overrides: [
          installedVersionProvider
              .overrideWithValue(FakeInstalledVersion(_installed)),
          updateServiceProvider.overrideWithValue(
            UpdateService(
              feed: FakeReleaseFeed(),
              installed: FakeInstalledVersion(_installed),
              manifestUrl: '',
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AboutScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('not set up'), findsOneWidget);
      expect(find.text('Check for updates'), findsNothing);
    });
  });
}
