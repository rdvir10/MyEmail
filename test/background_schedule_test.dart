import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sync/background_worker.dart';
import 'package:myemail/domain/sync_prefs.dart';
import 'package:workmanager/workmanager.dart';

/// What Android is asked to keep running, for each way sync can be set.
///
/// Every settings test uses the recording scheduler, so this never ran in a
/// test. Cancelling the wrong job, or leaving the other one enqueued, is two
/// things checking mail at once: every new message announced twice.
void main() {
  // Workmanager sets up its own channel as it starts, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingWorkManager android;

  setUp(() {
    android = _RecordingWorkManager();
    WorkmanagerPlatform.instance = android;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  // The names WorkManager knows the jobs by. Changing one leaves the old job
  // enqueued beside the new, so they are pinned here as well.
  const periodic = 'mailtree.new-mail.periodic';
  const live = 'mailtree.live.foreground';

  test('off cancels both and starts nothing', () async {
    await applyBackgroundSchedule(const SyncPrefs(mode: SyncMode.off));

    expect(android.cancelled, unorderedEquals([periodic, live]));
    expect(android.registered, isEmpty);
  });

  test('occasional cancels the live worker and schedules the periodic job',
      () async {
    await applyBackgroundSchedule(
      const SyncPrefs(mode: SyncMode.periodic, intervalMinutes: 30),
    );

    expect(android.cancelled, [live]);
    final job = android.registered.single;
    expect(job.uniqueName, periodic);
    expect(job.periodic, isTrue);
    expect(job.frequency, const Duration(minutes: 30));
    // Update, or a new interval chosen in Settings leaves the old one going.
    expect(job.policy, ExistingPeriodicWorkPolicy.update);
  });

  test('push cancels the periodic job and starts the live worker', () async {
    await applyBackgroundSchedule(const SyncPrefs(mode: SyncMode.realtime));

    expect(android.cancelled, [periodic]);
    final job = android.registered.single;
    expect(job.uniqueName, live);
    expect(job.periodic, isFalse);
    // Replace, or the worker from the mode before goes on beside this one.
    expect(job.policy, ExistingWorkPolicy.replace);
    expect(job.input, {'mode': 'realtime'});
    expect(job.service?.foregroundServiceType, ForegroundServiceType.dataSync);
    expect(job.service?.notificationText, 'Watching for new mail');
  });

  test('every five minutes is the live worker too, saying so', () async {
    await applyBackgroundSchedule(const SyncPrefs(mode: SyncMode.frequent));

    expect(android.cancelled, [periodic]);
    final job = android.registered.single;
    expect(job.uniqueName, live);
    expect(job.input, {'mode': 'frequent'});
    expect(job.service?.notificationText, 'Checking for mail every 5 minutes');
  });

  test('a run of changes never leaves both kinds enqueued', () async {
    // What Android would be holding after each change, applying the calls
    // as WorkManager does: a cancel drops the name, a register adds it.
    final enqueued = <String>{};
    for (final mode in [
      SyncMode.off,
      SyncMode.periodic,
      SyncMode.realtime,
      SyncMode.frequent,
      SyncMode.periodic,
      SyncMode.off,
    ]) {
      android.cancelled.clear();
      android.registered.clear();
      await applyBackgroundSchedule(SyncPrefs(mode: mode));
      enqueued
        ..removeAll(android.cancelled)
        ..addAll(android.registered.map((j) => j.uniqueName));

      expect(enqueued, switch (mode) {
        SyncMode.off => isEmpty,
        SyncMode.periodic => {periodic},
        SyncMode.frequent || SyncMode.realtime => {live},
      }, reason: '$mode');
    }
  });
}

typedef _Job = ({
  String uniqueName,
  bool periodic,
  Object? policy,
  Duration? frequency,
  Map<String, dynamic>? input,
  ForegroundServiceConfig? service,
});

/// WorkManager as Android would be asked: every cancel and every job.
class _RecordingWorkManager extends WorkmanagerPlatform {
  final cancelled = <String>[];
  final registered = <_Job>[];

  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    // ignore: deprecated_member_use
    bool isInDebugMode = false,
  }) async {}

  @override
  Future<void> cancelByUniqueName(String uniqueName) async =>
      cancelled.add(uniqueName);

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async =>
      registered.add((
        uniqueName: uniqueName,
        periodic: false,
        policy: existingWorkPolicy,
        frequency: null,
        input: inputData,
        service: foregroundServiceConfig,
      ));

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async =>
      registered.add((
        uniqueName: uniqueName,
        periodic: true,
        policy: existingWorkPolicy,
        frequency: frequency,
        input: inputData,
        service: foregroundServiceConfig,
      ));
}
