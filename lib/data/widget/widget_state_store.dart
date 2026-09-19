import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the home-screen widgets need remembered between runs.
///
/// Two things: which mailbox each placed widget shows, and when the app was
/// last opened, which is what "new since" counts from.
///
/// [SharedPreferencesAsync] rather than the cached flavour the rest of the
/// app uses, for the same reason the sync state store does it: the background
/// pass runs in its own isolate, and a cache loaded at construction would not
/// see what the other isolate wrote.
abstract class WidgetStateStore {
  /// When the app was last brought to the front. Null until it has been
  /// opened once since the widget was placed.
  Future<DateTime?> readOpenedAt();
  Future<void> writeOpenedAt(DateTime when);

  /// Android's widget id to the folder it shows.
  Future<Map<String, String>> readMailboxes();
  Future<void> writeMailbox(String appWidgetId, String folderId);
}

abstract final class WidgetStateKeys {
  static const openedAt = 'widget.openedAt.v1';
  static const mailboxes = 'widget.mailboxes.v1';
}

class PrefsWidgetStateStore implements WidgetStateStore {
  PrefsWidgetStateStore([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<DateTime?> readOpenedAt() async {
    final raw = await _prefs.getString(WidgetStateKeys.openedAt);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  @override
  Future<void> writeOpenedAt(DateTime when) =>
      _prefs.setString(WidgetStateKeys.openedAt, when.toUtc().toIso8601String());

  @override
  Future<Map<String, String>> readMailboxes() async {
    final raw = await _prefs.getString(WidgetStateKeys.mailboxes);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in decoded.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } on FormatException {
      return const {};
    } on TypeError {
      return const {};
    }
  }

  @override
  Future<void> writeMailbox(String appWidgetId, String folderId) async {
    final next = {...await readMailboxes(), appWidgetId: folderId};
    await _prefs.setString(WidgetStateKeys.mailboxes, jsonEncode(next));
  }
}

class MemoryWidgetStateStore implements WidgetStateStore {
  DateTime? openedAt;
  final Map<String, String> mailboxes = {};

  @override
  Future<DateTime?> readOpenedAt() async => openedAt;

  @override
  Future<void> writeOpenedAt(DateTime when) async => openedAt = when;

  @override
  Future<Map<String, String>> readMailboxes() async => Map.of(mailboxes);

  @override
  Future<void> writeMailbox(String appWidgetId, String folderId) async =>
      mailboxes[appWidgetId] = folderId;
}
