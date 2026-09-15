import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small, device-local UI state: which folders are expanded, favourites, the
/// user's folder ordering, the last selected folder.
///
/// This is a handful of id sets, so it lives in shared_preferences rather than
/// the Drift database that the message cache will need. Everything is read
/// synchronously after startup so the tree renders in its remembered shape on
/// the first frame rather than snapping into it a moment later.
abstract class UiStateStore {
  Set<String> readIds(String key);
  Future<void> writeIds(String key, Set<String> ids);

  Map<String, int> readOrder(String key);
  Future<void> writeOrder(String key, Map<String, int> order);

  String? readString(String key);
  Future<void> writeString(String key, String? value);
}

/// Keys, in one place so the notifiers and the tests agree.
abstract final class UiStateKeys {
  static const expanded = 'tree.expanded';
  static const favorites = 'tree.favorites';
  static const order = 'tree.order';
  static const selected = 'tree.selected';
  static const recentMoves = 'move.recents';
  static const quickSteps = 'quicksteps.v1';
  static const signatures = 'signatures.v1';
  // Notification preferences are deliberately NOT here: they are read by the
  // background isolate, which cannot see this store's cache. See SyncStateKeys.
  static const paneWidths = 'panes.v1';
}

/// Backed by shared_preferences, which works on Android and in the browser.
class PrefsUiStateStore implements UiStateStore {
  PrefsUiStateStore(this._prefs);

  final SharedPreferencesWithCache _prefs;

  static Future<PrefsUiStateStore> open() async {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    return PrefsUiStateStore(prefs);
  }

  @override
  Set<String> readIds(String key) =>
      (_prefs.getStringList(key) ?? const []).toSet();

  @override
  Future<void> writeIds(String key, Set<String> ids) =>
      _prefs.setStringList(key, ids.toList());

  @override
  Map<String, int> readOrder(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: e.value as int};
    } on FormatException {
      return const {};
    }
  }

  @override
  Future<void> writeOrder(String key, Map<String, int> order) =>
      _prefs.setString(key, jsonEncode(order));

  @override
  String? readString(String key) => _prefs.getString(key);

  @override
  Future<void> writeString(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);
}

/// For tests and the default provider value: remembers within one run only.
class MemoryUiStateStore implements UiStateStore {
  final Map<String, Set<String>> _ids = {};
  final Map<String, Map<String, int>> _orders = {};
  final Map<String, String> _strings = {};

  @override
  Set<String> readIds(String key) => Set.of(_ids[key] ?? const {});

  @override
  Future<void> writeIds(String key, Set<String> ids) async =>
      _ids[key] = Set.of(ids);

  @override
  Map<String, int> readOrder(String key) => Map.of(_orders[key] ?? const {});

  @override
  Future<void> writeOrder(String key, Map<String, int> order) async =>
      _orders[key] = Map.of(order);

  @override
  String? readString(String key) => _strings[key];

  @override
  Future<void> writeString(String key, String? value) async =>
      value == null ? _strings.remove(key) : _strings[key] = value;
}
