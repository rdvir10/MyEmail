import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/sync_prefs.dart';

/// The small amount of state that has to cross an isolate boundary.
///
/// The background pass does not run in the app's isolate: Android starts a
/// second Dart isolate for it, with no providers, no widget tree and none of
/// the app's in-memory state. So anything the pass needs from the UI (the
/// preferences) and anything it has to remember between runs (the watermarks)
/// has to go through the platform.
///
/// That is why this deliberately uses [SharedPreferencesAsync] rather than the
/// cached [SharedPreferencesWithCache] the rest of the app uses. A cache is
/// loaded once at construction; the UI isolate's copy would not see a write
/// made by the background isolate, and vice versa. Every read here goes to the
/// platform and therefore sees what the other isolate wrote.
abstract class SyncStateStore {
  Future<SyncPrefs> readPrefs();
  Future<void> writePrefs(SyncPrefs prefs);

  /// The highest UID this folder has already raised a notification for.
  ///
  /// Null means the folder has never been scanned, which is *not* the same as
  /// "everything in it is new": see [selectNotifiable] in new_mail_scan.dart,
  /// where a null watermark deliberately announces nothing.
  Future<int?> readWatermark(String folderId);

  Future<void> writeWatermark(String folderId, int uid);

  /// When the push or five-minute worker last finished a pass. How the app
  /// can tell that Android has stopped it.
  Future<DateTime?> readLastLivePass();
  Future<void> writeLastLivePass(DateTime at);
}

abstract final class SyncStateKeys {
  static const prefs = 'notify.prefs.v1';
  static const watermarkPrefix = 'notify.mark.';
  static const lastLivePass = 'sync.live.last';

  static String watermark(String folderId) => '$watermarkPrefix$folderId';
}

class PrefsSyncStateStore implements SyncStateStore {
  PrefsSyncStateStore([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<SyncPrefs> readPrefs() async {
    final raw = await _prefs.getString(SyncStateKeys.prefs);
    if (raw == null || raw.isEmpty) return const SyncPrefs();
    try {
      return SyncPrefs.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on FormatException {
      return const SyncPrefs();
    } on TypeError {
      return const SyncPrefs();
    }
  }

  @override
  Future<void> writePrefs(SyncPrefs prefs) =>
      _prefs.setString(SyncStateKeys.prefs, jsonEncode(prefs.toJson()));

  @override
  Future<int?> readWatermark(String folderId) =>
      _prefs.getInt(SyncStateKeys.watermark(folderId));

  @override
  Future<void> writeWatermark(String folderId, int uid) =>
      _prefs.setInt(SyncStateKeys.watermark(folderId), uid);

  @override
  Future<DateTime?> readLastLivePass() async {
    final ms = await _prefs.getInt(SyncStateKeys.lastLivePass);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<void> writeLastLivePass(DateTime at) =>
      _prefs.setInt(SyncStateKeys.lastLivePass, at.millisecondsSinceEpoch);

  // Watermarks for a removed account are deliberately not cleaned up. A folder
  // id starts with the account id, and account ids carry the millisecond they
  // were created, so a stale key can never be matched by a later account. The
  // cost is a few dead preference entries; the cost of enumerating and deleting
  // keys on every account removal is a slower, more breakable path.
}

/// For tests and for the browser preview, which has no background work at all.
class MemorySyncStateStore implements SyncStateStore {
  MemorySyncStateStore({this.prefs = const SyncPrefs()});

  /// Public so a test can set the starting point without a write.
  SyncPrefs prefs;
  final Map<String, int> _watermarks = {};

  Map<String, int> get watermarks => Map.unmodifiable(_watermarks);

  @override
  Future<SyncPrefs> readPrefs() async => prefs;

  @override
  Future<void> writePrefs(SyncPrefs next) async => prefs = next;

  @override
  Future<int?> readWatermark(String folderId) async => _watermarks[folderId];

  @override
  Future<void> writeWatermark(String folderId, int uid) async =>
      _watermarks[folderId] = uid;

  DateTime? lastLivePass;

  @override
  Future<DateTime?> readLastLivePass() async => lastLivePass;

  @override
  Future<void> writeLastLivePass(DateTime at) async => lastLivePass = at;
}
