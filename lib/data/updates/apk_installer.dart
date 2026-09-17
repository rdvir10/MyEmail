import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../domain/app_release.dart';

/// Downloading a release and handing it to Android's installer.
///
/// Written against a small platform channel of our own rather than an install
/// plugin. Two reasons: the whole native side is about forty lines of Kotlin,
/// and this project has already lost a day to a plugin that stopped building
/// against a new Android Gradle Plugin. A dependency whose entire job is one
/// intent is not worth that risk again.
///
/// Android will still show its own confirmation before installing. Silent
/// installs need device-owner privileges, which is management software, not a
/// mail client.
abstract class ApkInstaller {
  /// Download [release], reporting progress from 0 to 1, and return where it
  /// landed. A path rather than a File, so nothing above this interface has to
  /// import dart:io and the browser preview still compiles.
  Future<String> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  });

  /// Hand the file at [path] to Android's package installer.
  Future<void> install(String path);

  /// Whether Android will let this app ask to install one. False until the
  /// user grants "Install unknown apps" for MyEmail.
  Future<bool> canInstall();

  /// Open the system screen where that permission is granted.
  Future<void> openInstallPermissionSettings();
}

class AndroidApkInstaller implements ApkInstaller {
  AndroidApkInstaller({http.Client? client})
      : _client = client ?? http.Client();

  static const _channel = MethodChannel('mailtree/installer');

  final http.Client _client;

  @override
  Future<String> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(release.apkUrl));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'The download answered ${response.statusCode}.',
      );
    }

    final directory = await getApplicationSupportDirectory();
    // One fixed name, overwritten each time. Keeping a file per version fills
    // the phone with twenty-megabyte files nobody will ever open again.
    final file = File('${directory.path}/mailtree-update.apk');
    if (await file.exists()) await file.delete();

    final total = response.contentLength ?? release.sizeBytes;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          onProgress?.call((received / total).clamp(0, 1));
        }
      }
    } finally {
      await sink.close();
    }

    // A truncated download installs as a corrupt package, and Android's error
    // for that says nothing useful. Better to fail here with a sentence.
    if (total != null && total > 0 && received < total) {
      await file.delete();
      throw const SocketException('The download ended early.');
    }
    onProgress?.call(1);
    return file.path;
  }

  @override
  Future<void> install(String path) async {
    await _channel.invokeMethod<void>('install', {'path': path});
  }

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[myemail] canInstall failed: $e');
      return false;
    }
  }

  @override
  Future<void> openInstallPermissionSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');
}

/// Records instead of installing. Used by the tests and by the browser
/// preview, which has no installer at all.
class FakeApkInstaller implements ApkInstaller {
  FakeApkInstaller({this.permitted = true});

  bool permitted;
  final List<AppRelease> downloaded = [];
  final List<String> installed = [];
  int permissionScreensOpened = 0;
  Object? downloadError;

  @override
  Future<String> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    if (downloadError != null) throw downloadError!;
    downloaded.add(release);
    onProgress?.call(0.5);
    onProgress?.call(1);
    return '/fake/mailtree-update.apk';
  }

  @override
  Future<void> install(String path) async => installed.add(path);

  @override
  Future<bool> canInstall() async => permitted;

  @override
  Future<void> openInstallPermissionSettings() async =>
      permissionScreensOpened++;
}
