import 'dart:async';

import '../../domain/sync_prefs.dart';
import 'background_sync.dart';

/// The loop a foreground sync runs: check, wait, check, wait.
///
/// Split out from the worker because everything interesting about it is
/// timing, and timing is exactly what cannot be tested on a phone. What the
/// loop waits on is injected, so the same rules cover both foreground modes:
/// [SyncMode.frequent] waits on a timer, [SyncMode.realtime] waits on the
/// server.
///
/// Four rules, each of which is a way this goes wrong:
///
///  * Check immediately, before waiting at all. Turning the setting on and
///    then seeing nothing for five minutes reads as a broken switch.
///  * Stop when the budget is spent rather than running forever. Android will
///    eventually stop a long-lived worker, and a stopped worker does not
///    restart itself; handing over on our own schedule keeps that ours.
///  * A failed check must not end the loop. A mailbox that is briefly
///    unreachable is the normal case on a phone, not a reason to go quiet
///    until the app is opened again.
///  * A failed check must not spin either. Backing off keeps a server that is
///    refusing us from becoming a flat battery.
class LiveSyncLoop {
  LiveSyncLoop({
    required this.onePass,
    required this.waitForNext,
    this.budget = liveSyncBudget,
    this.retryDelay = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    this.stopSignal,
  })  : _sleep = sleep ?? _realSleep,
        _clock = clock ?? DateTime.now;

  /// One sync-and-notify pass.
  final Future<BackgroundSyncReport> Function() onePass;

  /// Waits until it is worth checking again: a timer, or the server speaking.
  final Future<void> Function() waitForNext;

  /// How long this worker may live before handing over to a fresh one.
  final Duration budget;

  /// How long to wait after a pass that failed outright.
  final Duration retryDelay;

  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;

  /// Completes when Android has asked the worker to stop. The loop finishes
  /// the pass it is on and then returns, rather than being cut off mid-write.
  final Future<void>? stopSignal;

  var _stopped = false;

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  Future<LiveSyncOutcome> run() async {
    stopSignal?.then((_) => _stopped = true);

    final startedAt = _clock();
    var passes = 0;
    var failures = 0;

    while (!_stopped && _clock().difference(startedAt) < budget) {
      var failed = false;
      try {
        final report = await onePass();
        passes++;
        if (!report.ok) failures++;
      } catch (_) {
        // Already logged by the pass. Here it only decides how long to wait.
        failures++;
        failed = true;
      }

      if (_stopped) break;
      // Deliberately after the stop check: a worker being torn down should
      // not sit in a sleep Android is waiting on.
      await (failed ? _sleep(retryDelay) : waitForNext());
    }

    return LiveSyncOutcome(
      passes: passes,
      failures: failures,
      stoppedEarly: _stopped,
    );
  }
}

/// What one foreground worker's lifetime amounted to.
class LiveSyncOutcome {
  const LiveSyncOutcome({
    required this.passes,
    required this.failures,
    required this.stoppedEarly,
  });

  final int passes;
  final int failures;

  /// True when Android asked us to stop rather than the budget running out.
  /// The caller uses this to decide whether re-enqueuing is wanted or would
  /// be fighting the system.
  final bool stoppedEarly;

  @override
  String toString() => 'LiveSyncOutcome(passes: $passes, '
      'failures: $failures, stoppedEarly: $stoppedEarly)';
}
