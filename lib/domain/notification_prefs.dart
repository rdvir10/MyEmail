import 'package:flutter/foundation.dart';

/// How MailTree looks for new mail.
///
/// The three differ in what Android will let them do, not just in speed.
enum SyncMode {
  /// A periodic job the OS schedules when it suits the OS. Nothing is held
  /// open and there is no persistent notification, but Android will not run
  /// it more often than every fifteen minutes and stretches that under Doze.
  periodic,

  /// A fixed five-minute check. Below the fifteen-minute floor, so it can
  /// only run inside a foreground service, which means a permanent
  /// notification and a real battery cost.
  frequent,

  /// The connection is held open and the server says when mail arrives, so
  /// it lands in seconds. Also a foreground service, and the connection
  /// itself keeps the radio warmer than an occasional poll.
  realtime;

  /// Whether this mode needs a foreground service, and therefore a permanent
  /// notification the user cannot dismiss. Android requires one for any work
  /// that outlives a short job.
  bool get needsForegroundService => this != SyncMode.periodic;

  String get label => switch (this) {
        SyncMode.periodic => 'Occasionally',
        SyncMode.frequent => 'Every 5 minutes',
        SyncMode.realtime => 'Push, as it arrives',
      };

  String get cost => switch (this) {
        SyncMode.periodic =>
          'Easiest on the battery. Android decides when, and overnight that '
              'can be much later than you asked for.',
        SyncMode.frequent =>
          'MailTree shows a permanent notification and uses noticeably more '
              'battery.',
        SyncMode.realtime =>
          'Mail arrives in seconds. MailTree shows a permanent notification '
              'and holds a connection open, which costs the most battery.',
      };
}

/// How often [SyncMode.frequent] checks. Named rather than inlined because
/// the whole reason that mode needs a foreground service is that this number
/// is below Android's fifteen-minute floor for scheduled work.
const frequentSyncInterval = Duration(minutes: 5);

/// How long one foreground pass runs before handing over to a fresh one.
///
/// Android will stop a long-lived worker eventually, and a worker that has
/// been stopped does not restart itself. Re-enqueuing well before that keeps
/// the handover ours rather than the system's.
const liveSyncBudget = Duration(minutes: 50);

/// An IDLE connection has to be renewed or the server drops it. RFC 2177 says
/// clients must re-issue at least every 29 minutes; 24 leaves room for a slow
/// network without a dropped connection looking like silence.
const idleRenewInterval = Duration(minutes: 24);

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
    this.mode = SyncMode.periodic,
    this.mutedAccountIds = const {},
  });

  final bool enabled;

  final SyncMode mode;

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

  /// Whether a permanent notification will be showing. The settings screen
  /// has to say so before the switch is flipped, not after.
  bool get showsOngoingNotification => enabled && mode.needsForegroundService;

  NotificationPrefs copyWith({
    bool? enabled,
    int? intervalMinutes,
    SyncMode? mode,
    Set<String>? mutedAccountIds,
  }) {
    return NotificationPrefs(
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      mode: mode ?? this.mode,
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
        'mode': mode.name,
        'muted': mutedAccountIds.toList(),
      };

  /// Tolerant on purpose: this is read in a background isolate where a throw
  /// means the pass dies silently, so every field falls back to its default
  /// rather than taking the feature down. Hence `is` tests instead of casts.
  factory NotificationPrefs.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    final interval = json['intervalMinutes'];
    final muted = json['muted'];
    final mode = json['mode'];
    return NotificationPrefs(
      enabled: enabled is bool ? enabled : false,
      intervalMinutes: interval is int ? interval : minimumIntervalMinutes,
      // An unknown mode falls back to the cheapest one. Guessing upward would
      // start a foreground service the user never asked for.
      mode: SyncMode.values.firstWhere(
        (m) => m.name == mode,
        orElse: () => SyncMode.periodic,
      ),
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
      other.mode == mode &&
      setEquals(other.mutedAccountIds, mutedAccountIds);

  @override
  int get hashCode =>
      Object.hash(enabled, intervalMinutes, mode, mutedAccountIds.length);

  @override
  String toString() => 'NotificationPrefs(enabled: $enabled, ${mode.name}, '
      'every ${intervalMinutes}m, muted: ${mutedAccountIds.length})';
}
