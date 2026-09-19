import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/mailbox_counts.dart';

/// What one placed widget is showing.
class WidgetMailbox {
  const WidgetMailbox({
    required this.folderId,
    this.counts = WidgetCount.all,
    this.label,
  });

  final String folderId;

  /// What to call it on the home screen. Null means the folder and the
  /// account it belongs to, which is right until two widgets sit side by
  /// side and "Inbox · Ron Dvir" is the same on both.
  final String? label;

  /// Whether the lower number is everything in the folder or only what is
  /// unread. Chosen per widget, so an Inbox can show what is unread while a
  /// Sent folder shows the lot.
  final WidgetCount counts;

  /// [clearLabel] because passing null to [label] cannot mean "back to the
  /// default name" and "leave it alone" at the same time.
  WidgetMailbox copyWith({
    String? folderId,
    WidgetCount? counts,
    String? label,
    bool clearLabel = false,
  }) =>
      WidgetMailbox(
        folderId: folderId ?? this.folderId,
        counts: counts ?? this.counts,
        label: clearLabel ? null : (label ?? this.label),
      );

  Map<String, Object?> toJson() => {
        'folder': folderId,
        'counts': counts.name,
        if (label != null) 'label': label,
      };

  /// Tolerant of the older shape, where the value was the folder id on its
  /// own. A widget placed before this existed keeps working and keeps
  /// counting everything, which is what it was already doing.
  static WidgetMailbox? fromJson(Object? value) {
    if (value is String) return WidgetMailbox(folderId: value);
    if (value is! Map) return null;
    final folder = value['folder'];
    if (folder is! String || folder.isEmpty) return null;
    final label = value['label'];
    return WidgetMailbox(
      folderId: folder,
      counts: WidgetCount.values.firstWhere(
        (c) => c.name == value['counts'],
        orElse: () => WidgetCount.all,
      ),
      label: label is String && label.trim().isNotEmpty ? label : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WidgetMailbox &&
      other.folderId == folderId &&
      other.counts == counts &&
      other.label == label;

  @override
  int get hashCode => Object.hash(folderId, counts, label);

  @override
  String toString() =>
      'WidgetMailbox($folderId, ${counts.name}${label == null ? '' : ', "$label"'})';
}

/// What the home-screen widgets need remembered between runs.
///
/// Two things: what each placed widget shows, and when the app was last in
/// front, which is what "new since" counts from.
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

  /// Android's widget id to what that widget shows.
  Future<Map<String, WidgetMailbox>> readMailboxes();
  Future<void> writeMailbox(String appWidgetId, WidgetMailbox mailbox);

  /// Forget the widgets that are no longer on the home screen.
  Future<void> keepOnly(Iterable<String> appWidgetIds);
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
  Future<Map<String, WidgetMailbox>> readMailboxes() async {
    final raw = await _prefs.getString(WidgetStateKeys.mailboxes);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, WidgetMailbox>{};
      for (final e in decoded.entries) {
        final mailbox = WidgetMailbox.fromJson(e.value);
        if (mailbox != null) out[e.key] = mailbox;
      }
      return out;
    } on FormatException {
      return const {};
    } on TypeError {
      return const {};
    }
  }

  @override
  Future<void> writeMailbox(String appWidgetId, WidgetMailbox mailbox) async {
    await _write({...await readMailboxes(), appWidgetId: mailbox});
  }

  @override
  Future<void> keepOnly(Iterable<String> appWidgetIds) async {
    final live = appWidgetIds.toSet();
    final current = await readMailboxes();
    final next = {
      for (final e in current.entries)
        if (live.contains(e.key)) e.key: e.value,
    };
    if (next.length == current.length) return;
    await _write(next);
  }

  Future<void> _write(Map<String, WidgetMailbox> mailboxes) => _prefs.setString(
        WidgetStateKeys.mailboxes,
        jsonEncode({
          for (final e in mailboxes.entries) e.key: e.value.toJson(),
        }),
      );
}

class MemoryWidgetStateStore implements WidgetStateStore {
  DateTime? openedAt;
  final Map<String, WidgetMailbox> mailboxes = {};

  @override
  Future<DateTime?> readOpenedAt() async => openedAt;

  @override
  Future<void> writeOpenedAt(DateTime when) async => openedAt = when;

  @override
  Future<Map<String, WidgetMailbox>> readMailboxes() async => Map.of(mailboxes);

  @override
  Future<void> writeMailbox(String appWidgetId, WidgetMailbox mailbox) async =>
      mailboxes[appWidgetId] = mailbox;

  @override
  Future<void> keepOnly(Iterable<String> appWidgetIds) async {
    final live = appWidgetIds.toSet();
    mailboxes.removeWhere((id, _) => !live.contains(id));
  }
}
