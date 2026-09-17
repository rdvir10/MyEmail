import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../domain/app_release.dart';

/// Where the update manifest lives.
///
/// GitHub's `releases/latest/download/<asset>` path always resolves to the
/// newest published release, so this URL never changes as versions come and
/// go. That is the whole reason for using Releases rather than files in the
/// repository: a 22 MB APK committed per version would live in the git
/// history forever, and every clone would pay for it.
///
/// It 404s until the first release is published, which the About screen
/// reports as "could not check" rather than pretending to be up to date.
///
/// Overridable for testing against somewhere else with
/// `--dart-define=MYEMAIL_UPDATE_URL=https://...`. Empty is still supported
/// and means the About screen says updates are not set up.
const updateManifestUrl = String.fromEnvironment(
  'MYEMAIL_UPDATE_URL',
  defaultValue:
      'https://github.com/rdvir10/MyEmail/releases/latest/download/latest.json',
);

/// Fetching the manifest, behind an interface so the whole update flow can be
/// tested without a network.
abstract class ReleaseFeed {
  /// The manifest as a decoded map, or null when there is no feed configured.
  /// Throws on a network or server failure; the caller turns that into a
  /// message rather than letting it escape.
  Future<Map<String, dynamic>?> fetch();
}

class HttpReleaseFeed implements ReleaseFeed {
  HttpReleaseFeed({this.url = updateManifestUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String url;
  final http.Client _client;

  @override
  Future<Map<String, dynamic>?> fetch() async {
    if (url.isEmpty) return null;
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException('The server answered ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The update file is not in the right shape.');
    }
    return decoded;
  }
}

/// Records what it was given. For tests and the browser preview.
class FakeReleaseFeed implements ReleaseFeed {
  FakeReleaseFeed({this.manifest, this.error});

  Map<String, dynamic>? manifest;
  Object? error;
  int fetches = 0;

  @override
  Future<Map<String, dynamic>?> fetch() async {
    fetches++;
    if (error != null) throw error!;
    return manifest;
  }
}

/// Reads what is currently installed. An interface only so a test can say it
/// is on build 4 without building an APK.
abstract class InstalledVersionReader {
  Future<InstalledVersion> read();
}

class PackageInstalledVersion implements InstalledVersionReader {
  const PackageInstalledVersion();

  @override
  Future<InstalledVersion> read() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledVersion(
      version: info.version,
      // buildNumber is a string in the package's API and empty on a platform
      // that has no such concept, so it cannot simply be parsed.
      build: int.tryParse(info.buildNumber) ?? 0,
    );
  }
}

class FakeInstalledVersion implements InstalledVersionReader {
  FakeInstalledVersion(this.version);
  final InstalledVersion version;

  @override
  Future<InstalledVersion> read() async => version;
}

/// Deciding whether there is an update, and what to say about it.
///
/// Every failure comes back as an [UpdateCheckFailed] carrying a sentence a
/// person can read, rather than as an exception. A check that throws on a
/// settings screen is a red error box where a line of text belongs.
class UpdateService {
  const UpdateService({
    required this.feed,
    required this.installed,
    this.manifestUrl = updateManifestUrl,
  });

  final ReleaseFeed feed;
  final InstalledVersionReader installed;

  /// Injected rather than read straight from the constant, so a test can
  /// exercise the unconfigured screen. The constant is compile-time, so
  /// without this the "updates are not set up" path could only be checked by
  /// building the app a second way.
  final String manifestUrl;

  bool get isConfigured => manifestUrl.isNotEmpty;

  Future<UpdateStatus> check() async {
    final current = await installed.read();
    final Map<String, dynamic>? manifest;
    try {
      manifest = await feed.fetch();
    } catch (e) {
      debugPrint('[myemail] update check failed: $e');
      return UpdateCheckFailed(_readable(e), current);
    }
    if (manifest == null) return UpToDate(current);

    final release = AppRelease.fromJson(manifest);
    if (release == null) {
      return UpdateCheckFailed(
        'The update file could not be read.',
        current,
      );
    }
    if (!release.isNewerThan(current.build)) return UpToDate(current);
    if (!release.canBeInstalledOver(current.build)) {
      return UpdateTooOld(release, current);
    }
    return UpdateAvailable(release, current);
  }

  /// Exceptions, as a sentence. The type name and stack trace belong in the
  /// log, not on screen.
  static String _readable(Object error) => switch (error) {
        FormatException() => 'The update file could not be read.',
        http.ClientException(:final message) => message,
        _ => 'Could not reach the update server.',
      };
}
