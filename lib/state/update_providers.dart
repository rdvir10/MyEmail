import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/updates/apk_installer.dart';
import '../data/updates/update_service.dart';
import '../domain/app_release.dart';

/// Fetches the update manifest. main() overrides this with the HTTP one; tests
/// and the browser preview get a fake.
final releaseFeedProvider = Provider<ReleaseFeed>((ref) => FakeReleaseFeed());

/// Reads what is installed. Overridden in main() with the real package info.
final installedVersionProvider = Provider<InstalledVersionReader>(
  (ref) => FakeInstalledVersion(
    const InstalledVersion(version: '0.0.0', build: 0),
  ),
);

/// Downloads and installs. Overridden in main() with the Android one.
final apkInstallerProvider =
    Provider<ApkInstaller>((ref) => FakeApkInstaller(permitted: false));

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(
    feed: ref.watch(releaseFeedProvider),
    installed: ref.watch(installedVersionProvider),
  ),
);

/// What the installed build is, for the About screen's first line.
final installedVersionValueProvider = FutureProvider<InstalledVersion>(
  (ref) => ref.watch(installedVersionProvider).read(),
);

/// Where the update flow has got to.
///
/// One notifier rather than a provider per step, because the steps are a
/// sequence and the screen has to show exactly one of them: idle, checking,
/// a result, downloading with progress, ready to install.
sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateChecked extends UpdateState {
  const UpdateChecked(this.status);
  final UpdateStatus status;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, this.progress);
  final AppRelease release;
  final double progress;
}

/// Downloaded and waiting for the user to confirm Android's install prompt.
class UpdateReadyToInstall extends UpdateState {
  const UpdateReadyToInstall(this.release, this.path);
  final AppRelease release;
  final String path;
}

/// The install could not even be offered, because Android has not been told
/// MyEmail may ask.
class UpdateNeedsPermission extends UpdateState {
  const UpdateNeedsPermission(this.release, this.path);
  final AppRelease release;
  final String path;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.reason);
  final String reason;
}

class UpdateFlow extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateIdle();

  Future<void> check() async {
    state = const UpdateChecking();
    state = UpdateChecked(await ref.read(updateServiceProvider).check());
  }

  /// Download, then ask Android to install.
  ///
  /// The permission is checked after the download rather than before, so a
  /// refusal does not also throw away twenty megabytes. The file stays put and
  /// the screen offers the settings shortcut plus a retry.
  Future<void> downloadAndInstall(AppRelease release) async {
    final installer = ref.read(apkInstallerProvider);
    state = UpdateDownloading(release, 0);
    try {
      final path = await installer.download(
        release,
        onProgress: (p) => state = UpdateDownloading(release, p),
      );
      if (!await installer.canInstall()) {
        state = UpdateNeedsPermission(release, path);
        return;
      }
      state = UpdateReadyToInstall(release, path);
      await installer.install(path);
    } catch (e) {
      state = UpdateFailed('$e');
    }
  }

  /// Try the install again, without downloading again. What the screen calls
  /// after the user has come back from granting the permission.
  Future<void> retryInstall(AppRelease release, String path) async {
    final installer = ref.read(apkInstallerProvider);
    if (!await installer.canInstall()) {
      state = UpdateNeedsPermission(release, path);
      return;
    }
    try {
      state = UpdateReadyToInstall(release, path);
      await installer.install(path);
    } catch (e) {
      state = UpdateFailed('$e');
    }
  }

  Future<void> openPermissionSettings() =>
      ref.read(apkInstallerProvider).openInstallPermissionSettings();

  void reset() => state = const UpdateIdle();
}

final updateFlowProvider =
    NotifierProvider<UpdateFlow, UpdateState>(UpdateFlow.new);
