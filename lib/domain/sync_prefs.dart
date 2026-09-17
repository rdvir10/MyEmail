import 'package:flutter/foundation.dart';

/// How often MyEmail looks for new mail in the background.
///
/// The four differ in what Android will let them do, not just in speed.
enum SyncMode {
  /// Never, unless the app is open. Mail arrives when you go looking for it.
  off,

  /// A periodic job the OS schedules when it suits the OS. Nothing is held
  /// open, but Android will not run it more often than every fifteen minutes
  /// and stretches that under Doze.
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
  bool get needsForegroundService =>
      this == SyncMode.frequent || this == SyncMode.realtime;

  bool get isOn => this != SyncMode.off;

  String get label => switch (this) {
        SyncMode.off => 'Only when I open MyEmail',
        SyncMode.periodic => 'Occasionally',
        SyncMode.frequent => 'Every 5 minutes',
        SyncMode.realtime => 'Push, as it arrives',
      };

  String get cost => switch (this) {
        SyncMode.off =>
          'No background work at all. Nothing can reach you until you open '
              'the app.',
        SyncMode.periodic =>
          'Easiest on the battery. Android decides when, and overnight that '
              'can be much later than you asked for.',
        SyncMode.frequent =>
          'MyEmail shows a permanent notification and uses noticeably more '
              'battery.',
        SyncMode.realtime =>
          'Mail arrives in seconds. MyEmail shows a permanent notification '
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

/// Background sync and notifications, which are two separate decisions.
///
/// They were one switch, and that was wrong. Whether MyEmail keeps itself
/// current in the background is about battery and about the app being ready
/// when you open it. Whether it interrupts you is about whether you want to
/// be interrupted. Wanting one without the other is ordinary: checking every
/// five minutes so the inbox is there when you look, and never making a
/// sound, is a perfectly sensible way to run a mail client.
///
/// So [mode] says how often, [notify] says whether to announce it, and the
/// two are set on separate screens.
@immutable
class SyncPrefs {
  const SyncPrefs({
    this.mode = SyncMode.off,
    this.intervalMinutes = 15,
    this.notify = true,
    this.mutedAccountIds = const {},
  });

  /// How often the background pass runs. Off by default: background work is a
  /// battery cost, and starting it uninvited on first run is not ours to do.
  final SyncMode mode;

  /// How often [SyncMode.periodic] checks. Android's WorkManager will not
  /// schedule periodic work more often than every 15 minutes, so that is the
  /// floor; asking for less silently gets 15 anyway. The OS also treats this
  /// as a hint and will stretch it under Doze, which is why the screen says
  /// "about every".
  final int intervalMinutes;

  /// Whether new mail found by a background pass raises a notification.
  ///
  /// True by default, because someone who has just turned sync on almost
  /// always wants to hear about it, and turning it off is one tap on a screen
  /// that says what it does.
  final bool notify;

  /// Accounts whose new mail is synced but not announced. A personal account
  /// and one you only read on purpose want different treatment, and the
  /// alternative is silencing everything.
  final Set<String> mutedAccountIds;

  static const minimumIntervalMinutes = 15;
  static const intervalChoices = [15, 30, 60, 180];

  Duration get interval =>
      Duration(minutes: intervalMinutes.clamp(minimumIntervalMinutes, 24 * 60));

  /// Whether a background pass should run at all.
  bool get syncs => mode.isOn;

  /// Whether new mail in this account should be announced. Notifications
  /// cannot arrive without a pass to find them, so this is false when sync is
  /// off however the notification switch is set.
  bool notifiesFor(String accountId) =>
      syncs && notify && !mutedAccountIds.contains(accountId);

  /// Notifications are switched on but nothing will ever find any. The
  /// Notifications screen has to say so rather than show a switch that is on
  /// above a phone that will stay silent.
  bool get notifyIsIdle => notify && !syncs;

  /// Whether a permanent notification will be showing. The screen has to say
  /// so before the choice is made, not after.
  bool get showsOngoingNotification => mode.needsForegroundService;

  SyncPrefs copyWith({
    SyncMode? mode,
    int? intervalMinutes,
    bool? notify,
    Set<String>? mutedAccountIds,
  }) {
    return SyncPrefs(
      mode: mode ?? this.mode,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      notify: notify ?? this.notify,
      mutedAccountIds: mutedAccountIds ?? this.mutedAccountIds,
    );
  }

  SyncPrefs withAccountMuted(String accountId, bool muted) {
    return copyWith(
      mutedAccountIds: {
        for (final id in mutedAccountIds)
          if (id != accountId) id,
        if (muted) accountId,
      },
    );
  }

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'intervalMinutes': intervalMinutes,
        'notify': notify,
        'muted': mutedAccountIds.toList(),
      };

  /// Tolerant on purpose: this is read in a background isolate where a throw
  /// means the pass dies silently, so every field falls back to its default
  /// rather than taking the feature down. Hence `is` tests instead of casts.
  ///
  /// Also reads the older shape, where one `enabled` flag meant both "sync in
  /// the background" and "tell me about it". That maps cleanly: off means no
  /// sync, on means sync in the recorded mode and announce it.
  factory SyncPrefs.fromJson(Map<String, dynamic> json) {
    final interval = json['intervalMinutes'];
    final muted = json['muted'];
    final notify = json['notify'];
    final legacyEnabled = json['enabled'];

    var mode = SyncMode.values.firstWhere(
      (m) => m.name == json['mode'],
      // An unknown mode falls back to off rather than up: guessing upward
      // would start a foreground service nobody asked for.
      orElse: () => SyncMode.off,
    );
    if (legacyEnabled is bool) {
      if (!legacyEnabled) {
        mode = SyncMode.off;
      } else if (mode == SyncMode.off) {
        // The old shape had no "off"; enabled with no mode meant periodic.
        mode = SyncMode.periodic;
      }
    }

    return SyncPrefs(
      mode: mode,
      intervalMinutes: interval is int ? interval : minimumIntervalMinutes,
      notify: switch ((notify, legacyEnabled)) {
        (final bool value, _) => value,
        // Upgrading: whoever had the one switch on wanted to be told.
        (_, final bool enabled) => enabled,
        _ => true,
      },
      mutedAccountIds: {
        if (muted is List)
          for (final id in muted)
            if (id is String) id,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncPrefs &&
      other.mode == mode &&
      other.intervalMinutes == intervalMinutes &&
      other.notify == notify &&
      setEquals(other.mutedAccountIds, mutedAccountIds);

  @override
  int get hashCode =>
      Object.hash(mode, intervalMinutes, notify, mutedAccountIds.length);

  @override
  String toString() => 'SyncPrefs(${mode.name}, every ${intervalMinutes}m, '
      'notify: $notify, muted: ${mutedAccountIds.length})';
}
