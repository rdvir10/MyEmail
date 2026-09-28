import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

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
///  * Run until Android says stop, and not past the foreground service
///    going. It used to hand over to a fresh worker every fifty minutes,
///    and Android refuses a foreground service started from the background,
///    so every worker after the first ran with none: frozen between Android's
///    rationed job slots on a Pixel, checking every ten seconds on a Samsung.
///  * A failed check must not end the loop. A mailbox that is briefly
///    unreachable is the normal case on a phone, not a reason to go quiet
///    until the app is opened again.
///  * A failed check must not spin either. Backing off keeps a server that is
///    refusing us from becoming a flat battery.
class LiveSyncLoop {
  LiveSyncLoop({
    required this.onePass,
    required this.waitForNext,
    this.budget,
    this.stillForeground,
    this.retryDelay = const Duration(seconds: 30),
    this.minimumGap = const Duration(seconds: 10),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    this.stopSignal,
  })  : _sleep = sleep ?? _realSleep,
        _clock = clock ?? DateTime.now;

  /// One sync-and-notify pass.
  final Future<BackgroundSyncReport> Function() onePass;

  /// Waits until it is worth checking again: a timer, or the server speaking.
  final Future<void> Function() waitForNext;

  /// How long the loop may run. Only tests set one: the worker runs until
  /// Android stops it.
  final Duration? budget;

  /// Whether the worker still has its foreground service, asked after every
  /// pass. False ends the loop, because without the service there is no
  /// staying alive between passes; see [LiveSyncOutcome.lostForeground].
  final Future<bool> Function()? stillForeground;

  /// How long to wait after a pass that failed outright, or a wait that did.
  final Duration retryDelay;

  /// The least time from the start of one pass to the start of the next,
  /// however quickly the wait between them came back. A wait that returns at
  /// once — a server refusing every connection, a watch that cannot start —
  /// would otherwise turn the loop into passes back to back for the whole
  /// budget. Mail arriving in a burst waits this long at most.
  final Duration minimumGap;

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
    final budget = this.budget;
    var passes = 0;
    var failures = 0;
    var lostForeground = false;

    while (!_stopped &&
        (budget == null || _clock().difference(startedAt) < budget)) {
      var failed = false;
      final passStarted = _clock();
      debugPrint('[myemail] live: pass ${passes + 1} starting');
      try {
        final report = await onePass();
        passes++;
        if (!report.ok) failures++;
        debugPrint(
          '[myemail] live: pass $passes done in '
          '${_clock().difference(passStarted).inSeconds}s, ok=${report.ok}',
        );
      } catch (e) {
        // Already logged by the pass. Here it only decides how long to wait.
        failures++;
        failed = true;
        debugPrint(
          '[myemail] live: pass ${passes + 1} threw after '
          '${_clock().difference(passStarted).inSeconds}s: $e',
        );
      }

      if (_stopped) break;
      // After the pass, not before: a worker that was refused its service
      // still has the job Android started it in, and its network, and one
      // check out of that is worth having.
      if (stillForeground != null && !await stillForeground!()) {
        debugPrint('[myemail] live: no foreground service, so stopping');
        lostForeground = true;
        break;
      }
      // Deliberately after the stop check: a worker being torn down should
      // not sit in a sleep Android is waiting on.
      final waitStarted = _clock();
      debugPrint('[myemail] live: waiting (${failed ? 'retry' : 'next'})');
      if (failed) {
        await _sleep(retryDelay);
      } else {
        try {
          await waitForNext();
        } catch (e) {
          // The wait is part of the loop, and the loop must outlive anything
          // one account can do. This used to escape run(), which ended the
          // worker and every account's notifications with it.
          debugPrint('[myemail] live: wait threw: $e');
          if (_stopped) break;
          await _sleep(retryDelay);
        }
      }
      debugPrint(
        '[myemail] live: wait ended after '
        '${_clock().difference(waitStarted).inSeconds}s',
      );

      if (_stopped) break;
      final sincePass = _clock().difference(passStarted);
      if (sincePass < minimumGap) await _sleep(minimumGap - sincePass);
    }

    return LiveSyncOutcome(
      passes: passes,
      failures: failures,
      stoppedEarly: _stopped,
      lostForeground: lostForeground,
    );
  }
}

/// What one foreground worker's lifetime amounted to.
class LiveSyncOutcome {
  const LiveSyncOutcome({
    required this.passes,
    required this.failures,
    required this.stoppedEarly,
    this.lostForeground = false,
  });

  final int passes;
  final int failures;

  /// True when Android asked us to stop.
  final bool stoppedEarly;

  /// True when the worker found itself without its foreground service:
  /// Android refused it, which it does to one started from the background
  /// unless the app is exempt from battery optimisation.
  final bool lostForeground;

  @override
  String toString() => 'LiveSyncOutcome(passes: $passes, '
      'failures: $failures, stoppedEarly: $stoppedEarly, '
      'lostForeground: $lostForeground)';
}
