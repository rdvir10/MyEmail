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
              'battery. Android allows this about six hours a day unless '
              'MyEmail is opened.',
        SyncMode.realtime =>
          'Mail arrives in seconds; Microsoft accounts, which cannot say '
              'when it does, are checked every minute. MyEmail shows a '
              'permanent notification and holds a connection open, which '
              'costs the most battery. Android allows this about six hours '
              'a day unless MyEmail is opened.',
      };
}

/// How long push or five-minute sync can go without a pass before it is
/// taken to have stopped. A healthy worker passes at least every IDLE
/// renewal.
const liveSyncStallAfter = Duration(minutes: 40);

/// Whether the push or five-minute worker has stopped when it should be
/// running.
///
/// Android 15 gives a data-sync foreground service six hours a day, reset
/// only by opening the app, so push left on overnight stopped with nothing
/// to say so. Null [lastPass] is a worker that has not had its first pass,
/// which is not the same thing.
bool liveSyncStalled(SyncPrefs prefs, DateTime? lastPass, DateTime now) =>
    prefs.syncs &&
    prefs.mode.needsForegroundService &&
    lastPass != null &&
    now.difference(lastPass) > liveSyncStallAfter;

/// How often [SyncMode.frequent] checks. Named rather than inlined because
/// the whole reason that mode needs a foreground service is that this number
/// is below Android's fifteen-minute floor for scheduled work.
const frequentSyncInterval = Duration(minutes: 5);

/// How often push checks the accounts that cannot be told when mail
/// arrives: Microsoft's, over Graph, whose own push goes only to a server
/// on the internet. It was the five-minute mode's five; Ron asked for every
/// minute, in the background and in the app alike. The IMAP that could
/// have told the app at once needs Hadco's administrator to allow it.
const pushPollInterval = Duration(minutes: 1);

/// How often push goes over everything, every account and its folder list,
/// between the times a server says there is mail: see [PushPassPlan].
const pushFullPassInterval = Duration(minutes: 5);

/// Which kind of pass push runs next. Checked every [pushPollInterval] for
/// the accounts that cannot be told of new mail, a pass over everything
/// took 17 to 35 seconds; the Gmail account, which says when mail arrives,
/// and the folder lists, which seldom change, were fetched every time for
/// nothing. So everything only when a server spoke, on the first pass, and
/// every [pushFullPassInterval]; otherwise only the accounts that cannot be
/// told, with their folder lists as last saved.
class PushPassPlan {
  PushPassPlan({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _lastFull;
  bool _spoke = true;

  /// The wait before the next pass ended because a server said there was
  /// something new (true), or ran out (false).
  void waited({required bool spoke}) => _spoke = spoke;

  /// Whether the next pass goes over everything. Asking counts it as run.
  bool nextIsFull() {
    final now = _clock();
    final last = _lastFull;
    final full =
        _spoke || last == null || now.difference(last) >= pushFullPassInterval;
    if (full) _lastFull = now;
    return full;
  }
}

/// An IDLE connection has to be renewed or the server drops it. RFC 2177 says
/// clients must re-issue at least every 29 minutes; 24 leaves room for a slow
/// network without a dropped connection looking like silence.
const idleRenewInterval = Duration(minutes: 24);

/// Outlook for Android's Do Not Disturb, for one account: quiet until a
/// time (an hour, until tomorrow), every evening between two hours, and on
/// the days off all day. Its mail still syncs; it is only not announced,
/// then or after.
@immutable
class QuietRule {
  const QuietRule({
    this.until,
    this.evenings = false,
    this.from = 18,
    this.to = 8,
    this.weekends = false,
    this.daysOff = const {DateTime.saturday, DateTime.sunday},
  });

  /// Quiet until then: For an hour, Until tomorrow.
  final DateTime? until;

  /// Every evening from [from] o'clock to [to] the next morning (or the
  /// same day, where [to] comes after [from]).
  final bool evenings;
  final int from;
  final int to;

  /// All day on [daysOff], as `DateTime.weekday` numbers: the days not in
  /// the work week when it was set, kept here because the background reads
  /// this and not the work week.
  final bool weekends;
  final Set<int> daysOff;

  /// Whether anything is set at all.
  bool get isEmpty => until == null && !evenings && !weekends;

  bool isQuiet(DateTime now) {
    if (until != null && now.isBefore(until!)) return true;
    if (weekends && daysOff.contains(now.weekday)) return true;
    if (evenings) {
      final h = now.hour;
      if (from > to ? (h >= from || h < to) : (h >= from && h < to)) {
        return true;
      }
    }
    return false;
  }

  QuietRule copyWith({
    Object? until = _keep,
    bool? evenings,
    int? from,
    int? to,
    bool? weekends,
    Set<int>? daysOff,
  }) =>
      QuietRule(
        until: identical(until, _keep) ? this.until : until as DateTime?,
        evenings: evenings ?? this.evenings,
        from: from ?? this.from,
        to: to ?? this.to,
        weekends: weekends ?? this.weekends,
        daysOff: daysOff ?? this.daysOff,
      );

  Map<String, Object?> toJson() => {
        if (until != null) 'until': until!.toUtc().toIso8601String(),
        'evenings': evenings,
        'from': from,
        'to': to,
        'weekends': weekends,
        'daysOff': daysOff.toList()..sort(),
      };

  /// As tolerant as [SyncPrefs.fromJson], for the same reason.
  static QuietRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final until = json['until'];
    final days = json['daysOff'];
    int hour(Object? v, int fallback) =>
        v is int && v >= 0 && v < 24 ? v : fallback;
    return QuietRule(
      until: until is String ? DateTime.tryParse(until)?.toLocal() : null,
      evenings: json['evenings'] == true,
      from: hour(json['from'], 18),
      to: hour(json['to'], 8),
      weekends: json['weekends'] == true,
      daysOff: days is List
          ? {
              for (final d in days)
                if (d is int && d >= 1 && d <= 7) d,
            }
          : const {DateTime.saturday, DateTime.sunday},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuietRule &&
      other.until == until &&
      other.evenings == evenings &&
      other.from == from &&
      other.to == to &&
      other.weekends == weekends &&
      setEquals(other.daysOff, daysOff);

  @override
  int get hashCode =>
      Object.hash(until, evenings, from, to, weekends, daysOff.length);
}

const _keep = Object();

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
    this.quiet = const {},
    this.vips = const {},
    this.vipOnlyAccountIds = const {},
    this.watchedFolderIds = const {},
  });

  /// Do Not Disturb, by account: see [QuietRule].
  final Map<String, QuietRule> quiet;

  /// The people whose mail is always worth a notification, by address in
  /// lower case: Outlook's VIPs.
  final Set<String> vips;

  /// Accounts that announce mail from [vips] and nothing else.
  final Set<String> vipOnlyAccountIds;

  /// Folders besides the Inboxes whose new mail is announced, by id; the
  /// background checks them as it does the Inboxes.
  final Set<String> watchedFolderIds;

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

  /// Whether [accountId] is in Do Not Disturb at [now].
  bool quietFor(String accountId, DateTime now) =>
      quiet[accountId]?.isQuiet(now) ?? false;

  /// Whether mail from [email] to [accountId] is one to announce, as far as
  /// VIPs go: anyone's, unless the account is for VIPs only.
  bool announcesFrom(String accountId, String email) =>
      !vipOnlyAccountIds.contains(accountId) ||
      vips.contains(email.trim().toLowerCase());

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
    Map<String, QuietRule>? quiet,
    Set<String>? vips,
    Set<String>? vipOnlyAccountIds,
    Set<String>? watchedFolderIds,
  }) {
    return SyncPrefs(
      mode: mode ?? this.mode,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      notify: notify ?? this.notify,
      mutedAccountIds: mutedAccountIds ?? this.mutedAccountIds,
      quiet: quiet ?? this.quiet,
      vips: vips ?? this.vips,
      vipOnlyAccountIds: vipOnlyAccountIds ?? this.vipOnlyAccountIds,
      watchedFolderIds: watchedFolderIds ?? this.watchedFolderIds,
    );
  }

  /// [accountId]'s Do Not Disturb as [rule], or none.
  SyncPrefs withQuiet(String accountId, QuietRule? rule) => copyWith(quiet: {
        for (final e in quiet.entries)
          if (e.key != accountId) e.key: e.value,
        if (rule != null && !rule.isEmpty) accountId: rule,
      });

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
        if (quiet.isNotEmpty)
          'quiet': {for (final e in quiet.entries) e.key: e.value.toJson()},
        if (vips.isNotEmpty) 'vips': vips.toList()..sort(),
        if (vipOnlyAccountIds.isNotEmpty) 'vipOnly': vipOnlyAccountIds.toList(),
        if (watchedFolderIds.isNotEmpty) 'watched': watchedFolderIds.toList(),
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
      quiet: {
        if (json['quiet'] case final Map quiet)
          for (final e in quiet.entries)
            if (e.key is String) '${e.key}': ?QuietRule.fromJson(e.value),
      },
      vips: _strings(json['vips']),
      vipOnlyAccountIds: _strings(json['vipOnly']),
      watchedFolderIds: _strings(json['watched']),
    );
  }

  static Set<String> _strings(Object? value) => {
        if (value is List)
          for (final s in value)
            if (s is String && s.isNotEmpty) s,
      };

  @override
  bool operator ==(Object other) =>
      other is SyncPrefs &&
      other.mode == mode &&
      other.intervalMinutes == intervalMinutes &&
      other.notify == notify &&
      setEquals(other.mutedAccountIds, mutedAccountIds) &&
      mapEquals(other.quiet, quiet) &&
      setEquals(other.vips, vips) &&
      setEquals(other.vipOnlyAccountIds, vipOnlyAccountIds) &&
      setEquals(other.watchedFolderIds, watchedFolderIds);

  @override
  int get hashCode =>
      Object.hash(mode, intervalMinutes, notify, mutedAccountIds.length);

  @override
  String toString() => 'SyncPrefs(${mode.name}, every ${intervalMinutes}m, '
      'notify: $notify, muted: ${mutedAccountIds.length})';
}
