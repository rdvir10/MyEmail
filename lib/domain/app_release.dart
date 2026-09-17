import 'package:flutter/foundation.dart';

/// A build that is available to install, as the update manifest describes it.
///
/// The manifest is a small JSON file at a stable URL. It is the only thing the
/// phone fetches to decide whether there is anything to do, so it stays small
/// enough to be free to check on every launch:
///
/// ```json
/// {
///   "version": "1.1.0",
///   "build": 7,
///   "minBuild": 1,
///   "apk": "https://.../mailtree-arm64.apk",
///   "sizeBytes": 23308977,
///   "notes": "Conversations, drafts, and the tablet ribbon."
/// }
/// ```
@immutable
class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    required this.apkUrl,
    this.minBuild = 0,
    this.sizeBytes,
    this.notes,
  });

  /// What the user sees, e.g. "1.1.0". Never compared: see [build].
  final String version;

  /// Android's versionCode, and the only thing [isNewerThan] looks at.
  ///
  /// Comparing version strings means parsing them, and every scheme has an
  /// edge that bites: "1.10" against "1.9", a trailing "-beta", a build that
  /// forgot to bump the string. The build number is a plain integer Android
  /// already refuses to go backwards on, so it is the honest thing to compare
  /// and the string is left to be read by a person.
  final int build;

  final String apkUrl;

  /// The oldest build that may install this one directly.
  ///
  /// The compatibility gate. If a future release changes the database in a way
  /// that only migrates cleanly from a recent version, it says so here and an
  /// older install is told to reinstall rather than handed something that will
  /// fail on first launch. Zero means anything may take it.
  final int minBuild;

  /// Shown before downloading, because a phone on mobile data deserves to
  /// know what it is about to spend.
  final int? sizeBytes;

  /// What changed. Optional: a release with nothing worth saying should say
  /// nothing rather than pad.
  final String? notes;

  /// "22.2 MB", or null when the manifest did not say.
  String? get readableSize {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Whether this is worth offering to someone running [currentBuild].
  bool isNewerThan(int currentBuild) => build > currentBuild;

  /// Whether [currentBuild] is allowed to install this directly.
  bool canBeInstalledOver(int currentBuild) => currentBuild >= minBuild;

  /// Tolerant on purpose. A manifest is fetched from the network and parsed on
  /// a screen the user is looking at; a malformed one should read as "no
  /// update" rather than crash the settings screen. Returns null when the
  /// fields that matter are missing or the wrong shape.
  static AppRelease? fromJson(Map<String, dynamic> json) {
    final build = json['build'];
    final apk = json['apk'];
    final version = json['version'];
    if (build is! int || apk is! String || apk.isEmpty) return null;
    // Only https. An update fetched over http is an APK any network between
    // here and there gets to choose, and it is about to be installed.
    if (!apk.startsWith('https://')) return null;
    return AppRelease(
      version: version is String && version.isNotEmpty ? version : '$build',
      build: build,
      apkUrl: apk,
      minBuild: json['minBuild'] is int ? json['minBuild'] as int : 0,
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : null,
      notes: json['notes'] is String && (json['notes'] as String).isNotEmpty
          ? json['notes'] as String
          : null,
    );
  }

  Map<String, Object?> toJson() => {
        'version': version,
        'build': build,
        'minBuild': minBuild,
        'apk': apkUrl,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (notes != null) 'notes': notes,
      };

  @override
  bool operator ==(Object other) =>
      other is AppRelease && other.build == build && other.apkUrl == apkUrl;

  @override
  int get hashCode => Object.hash(build, apkUrl);

  @override
  String toString() => 'AppRelease($version, build $build)';
}

/// What the app currently is, read from the package at runtime rather than
/// hard-coded, so the two can never disagree.
@immutable
class InstalledVersion {
  const InstalledVersion({required this.version, required this.build});

  final String version;
  final int build;

  @override
  String toString() => '$version ($build)';
}

/// Where a check for updates got to.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// Nothing newer than what is installed.
class UpToDate extends UpdateStatus {
  const UpToDate(this.installed);
  final InstalledVersion installed;
}

/// Something newer, and this install may take it.
class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.release, this.installed);
  final AppRelease release;
  final InstalledVersion installed;
}

/// Something newer, but this install is too old to move to it directly.
///
/// Said out loud rather than hidden. Silently reporting "up to date" to
/// someone who is several versions behind is the worst of the options.
class UpdateTooOld extends UpdateStatus {
  const UpdateTooOld(this.release, this.installed);
  final AppRelease release;
  final InstalledVersion installed;
}

/// The check itself failed: no network, a bad manifest, a server that is down.
class UpdateCheckFailed extends UpdateStatus {
  const UpdateCheckFailed(this.reason, this.installed);
  final String reason;
  final InstalledVersion installed;
}
