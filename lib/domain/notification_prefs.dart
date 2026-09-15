import 'package:flutter/foundation.dart';

/// What the background pass is allowed to do, and for which accounts.
///
/// Off by default. Notifications are the one thing a mail client does without
/// being opened, so turning them on is a decision the user makes rather than
/// one made for them on first run.
@immutable
class NotificationPrefs {
  const NotificationPrefs({
    this.enabled = false,
    this.intervalMinutes = 15,
    this.mutedAccountIds = const {},
  });

  final bool enabled;

  /// How often the background pass runs. Android's WorkManager will not
  /// schedule periodic work more often than every 15 minutes, so that is the
  /// floor; asking for less silently gets 15 anyway. The OS also treats this
  /// as a hint and will stretch it under Doze, which is why the settings
  /// screen says "about every".
  final int intervalMinutes;

  /// Accounts whose new mail is synced but not announced. A personal account
  /// and an account you only read on purpose want different treatment, and
  /// the alternative is turning the whole feature off.
  final Set<String> mutedAccountIds;

  static const minimumIntervalMinutes = 15;
  static const intervalChoices = [15, 30, 60, 180];

  Duration get interval =>
      Duration(minutes: intervalMinutes.clamp(minimumIntervalMinutes, 24 * 60));

  bool notifiesFor(String accountId) =>
      enabled && !mutedAccountIds.contains(accountId);

  NotificationPrefs copyWith({
    bool? enabled,
    int? intervalMinutes,
    Set<String>? mutedAccountIds,
  }) {
    return NotificationPrefs(
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      mutedAccountIds: mutedAccountIds ?? this.mutedAccountIds,
    );
  }

  NotificationPrefs withAccountMuted(String accountId, bool muted) {
    return copyWith(
      mutedAccountIds: {
        for (final id in mutedAccountIds)
          if (id != accountId) id,
        if (muted) accountId,
      },
    );
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'intervalMinutes': intervalMinutes,
        'muted': mutedAccountIds.toList(),
      };

  /// Tolerant on purpose: this is read in a background isolate where a throw
  /// means the pass dies silently, so every field falls back to its default
  /// rather than taking the feature down. Hence `is` tests instead of casts.
  factory NotificationPrefs.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    final interval = json['intervalMinutes'];
    final muted = json['muted'];
    return NotificationPrefs(
      enabled: enabled is bool ? enabled : false,
      intervalMinutes: interval is int ? interval : minimumIntervalMinutes,
      mutedAccountIds: {
        if (muted is List)
          for (final id in muted)
            if (id is String) id,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationPrefs &&
      other.enabled == enabled &&
      other.intervalMinutes == intervalMinutes &&
      setEquals(other.mutedAccountIds, mutedAccountIds);

  @override
  int get hashCode => Object.hash(enabled, intervalMinutes, mutedAccountIds.length);

  @override
  String toString() =>
      'NotificationPrefs(enabled: $enabled, every ${intervalMinutes}m, '
      'muted: ${mutedAccountIds.length})';
}
