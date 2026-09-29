import 'dart:async';
import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/signature.dart';
import '../account_store.dart';
import '../cache/mail_database.dart';
import '../folder_list_store.dart';
import '../graph/graph_id_map.dart';
import '../imap/cached_imap_engine.dart';
import '../secure_credential_store.dart';
import '../sync/background_worker.dart';
import '../ui_state_store.dart';
import 'android_mail_notifier.dart';
import 'notification_actions.dart';
import 'pending_actions.dart';

/// Answering a notification's buttons, in the isolate Android starts for
/// them.
///
/// The plugin delivers a press to its ActionBroadcastReceiver, which starts
/// one Dart isolate per process for the purpose and calls this. The receiver
/// has to be declared in the app's manifest; it was not until 2.66.0, and
/// until then no press ever arrived here at all.
///
/// This does the one thing that is quick and cannot half-happen: it writes
/// the press down. The work is then done by something with a proper
/// lifetime — the WorkManager job kicked off here, or the app the next time
/// it opens, whichever reaches the queue first.
///
/// The entry point has to be top-level and annotated, or the compiler drops
/// it from a release build and every button press does nothing at all.
@pragma('vm:entry-point')
void notificationActionEntryPoint(NotificationResponse response) {
  final actionId = response.actionId;
  final messageId = response.payload;
  if (!NotificationActions.isKnown(actionId) ||
      messageId == null ||
      messageId.isEmpty) {
    return;
  }
  queueNotificationAction(
    PendingAction(
      actionId: actionId!,
      messageId: messageId,
      typed: response.input,
    ),
  );
}

/// Write the press down, then ask WorkManager to carry it out.
///
/// Not awaited by the caller, because there is no caller that can wait. The
/// write is one small file and lands in milliseconds; the job that follows
/// is what has the time to do the rest.
///
/// Then the account's summary row, if the pressed message was the last
/// thing under it: the button took its own row down, and Android leaves the
/// summary up by itself, naming the mail just deleted.
Future<void> queueNotificationAction(PendingAction action) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    await PendingActions().add(action);
    await runPendingNotificationActions();
    // And a look a minute on, should the job for this press fail before it
    // runs: the job before it failing takes it down too. It finds nothing
    // to do if the press was carried out.
    await scheduleNotificationActionsRetry();
  } catch (e, stack) {
    debugPrint('[myemail] could not queue a notification action: $e');
    debugPrint('$stack');
  }
  await AndroidMailNotifier().dropEmptySummaries(gone: {action.messageId});
}

/// The name the running app listens under to hear that presses were
/// carried out somewhere else.
///
/// The worker that carries them out runs in its own isolate, and the app,
/// open all the while, went on showing a message deleted from the shade
/// until something else happened to refresh its lists.
const actionsDonePortName = 'myemail.notification-actions.done';

/// Tell the app, if it is running, to read its lists again.
void announceActionsDone() {
  try {
    IsolateNameServer.lookupPortByName(actionsDonePortName)?.send(null);
  } catch (e) {
    debugPrint('[myemail] could not tell the app about a press: $e');
  }
}

/// What one drain did with what it took.
class DrainResult {
  const DrainResult({this.done = 0, this.waiting = 0, this.held = 0});

  /// Carried out, or finally given up on and reported.
  final int done;

  /// Put back for another try: offline, or failed and not yet given up on.
  final int waiting;

  /// Being worked on by another drain. Someone has to look again: that
  /// drain may die before it finishes, and then only a later look finds
  /// the press.
  final int held;

  /// Whether anything is left for a later drain.
  bool get leftOver => waiting > 0 || held > 0;
}

/// How many real failures a press gets before it is given up on and
/// reported. Being offline is not counted.
const maxActionAttempts = 5;

/// How long a press may wait for a connection before it is given up on and
/// said, with what was typed. A server that has refused for a day will not
/// suddenly take it, and the person has long since moved on.
const offlineGiveUpAfter = Duration(hours: 24);

/// How long one press may keep its claim fresh. Everything a press does is
/// time-limited well within this; one still going after it is stuck, and
/// its claim is let go stale so another drain can take the press over (the
/// stuck one, should it ever come back, finds it gone: see LostClaim).
const maxHold = Duration(minutes: 10);

/// Android asked the job to stop before this press's reply was sent: put
/// back as it was, to be sent by the next drain.
class _StopRequested implements Exception {
  const _StopRequested();
}

/// Carry out everything waiting, with an engine built for the purpose.
///
/// Safe to call from anywhere: each press is claimed by exactly one caller,
/// one at a time as it is carried out, and its claim kept fresh while it is
/// (see [PendingActions]). A press that cannot be carried out now goes back
/// in the queue, and one action failing, or its report failing, does not
/// stop the rest.
///
/// [shouldStop] is asked before each press: the job, when Android stops it,
/// finishes the press in hand and leaves the rest where they are.
///
/// [open] and [report] are for tests; [report] also lets the app post
/// through a notifier that is already set up (see [reportOutcome]).
Future<DrainResult> drainPendingNotificationActions({
  PendingActions? queue,
  Future<(NotificationActions, Future<void> Function())> Function()? open,
  Future<void> Function(ActionOutcome outcome, PendingAction action)? report,
  bool Function()? shouldStop,
  Duration heartbeat = PendingActions.heartbeat,
  DateTime Function()? clock,
}) async {
  final pending = queue ?? PendingActions();
  final now = clock ?? DateTime.now;
  final files = await pending.waiting();
  if (files.isEmpty) return const DrainResult();

  NotificationActions? actions;
  Future<void> Function()? close;
  var done = 0;
  var waiting = 0;
  var held = 0;
  try {
    for (var i = 0; i < files.length; i++) {
      if (shouldStop?.call() ?? false) {
        // Unclaimed, so still in the queue for whoever looks next.
        waiting += files.length - i;
        break;
      }
      final attempt = await pending.claim(files[i]);
      var claim = attempt.claimed;
      if (claim == null) {
        if (attempt.held) held++;
        continue;
      }

      // Opened only once there is something to do, so a queue that is all
      // held elsewhere costs nothing.
      if (actions == null) {
        try {
          (actions, close) = await (open ?? _openActions)();
        } catch (e, stack) {
          debugPrint('[myemail] could not open the mail to act on: $e');
          debugPrint('$stack');
          // Nothing was tried, so a mark on it from an earlier try stays.
          await pending.putBack(claim, counted: false, keepSendMark: true);
          waiting += files.length - i;
          break;
        }
      }

      final action = claim.action;
      final heldSince = now();
      final beat = Timer.periodic(heartbeat, (beat) {
        if (now().difference(heldSince) > maxHold) {
          beat.cancel();
        } else {
          pending.touch(claim!);
        }
      });
      ActionOutcome outcome;
      try {
        outcome = await actions.perform(
          action.actionId,
          action.messageId,
          action.typed,
          sendStarted: action.sendStarted,
          beforeSend: () async {
            if (shouldStop?.call() ?? false) throw const _StopRequested();
            claim = await pending.markSending(claim!);
          },
        );
      } on LostClaim {
        // Taken over while this drain was frozen or asleep. Theirs now.
        held++;
        continue;
      } on _StopRequested {
        await pending.putBack(claim!, counted: false);
        waiting++;
        continue;
      } catch (_) {
        // A reply that threw still has its words only here, and says so as
        // a reply, not as a Delete.
        outcome =
            _isReply(action) ? ActionOutcome.notKept : ActionOutcome.failed;
      } finally {
        beat.cancel();
      }

      final offline = outcome == ActionOutcome.offline;
      final waitedTooLong = offline &&
          action.queuedAt != null &&
          now().difference(action.queuedAt!) > offlineGiveUpAfter;
      if (outcome.worthRetrying &&
          !waitedTooLong &&
          (offline || action.attempts + 1 < maxActionAttempts)) {
        await pending.putBack(claim!, counted: !offline);
        waiting++;
        continue;
      }
      if (waitedTooLong) {
        outcome = _isReply(action) ? ActionOutcome.notKept : ActionOutcome.failed;
      }

      // Reported before it leaves the queue when the report is the only
      // place what was typed survives; if the report cannot be posted, the
      // press stays, words and all, for another try.
      final typed = action.typed?.trim() ?? '';
      final wordsOnlyHere = outcome.keepsWords && typed.isNotEmpty;
      try {
        await (report ?? reportOutcome)(outcome, action);
      } catch (e) {
        debugPrint('[myemail] could not report a notification action: $e');
        if (wordsOnlyHere) {
          await pending.putBack(claim!,
              keepSendMark: outcome == ActionOutcome.maybeSent);
          waiting++;
          continue;
        }
      }
      await pending.done(claim!);
      done++;
    }
  } finally {
    await close?.call();
  }
  return DrainResult(done: done, waiting: waiting, held: held);
}

bool _isReply(PendingAction action) =>
    action.actionId == NotificationActions.replyId ||
    action.actionId == NotificationActions.replyAllId;

Future<(NotificationActions, Future<void> Function())> _openActions() async {
  final prefs = await SharedPreferencesWithCache.create(
    cacheOptions: const SharedPreferencesWithCacheOptions(),
  );
  final database = MailDatabase.open();
  final accountStore = PrefsAccountStore(prefs);
  final engine = CachedImapEngine(
    accountStore: accountStore,
    credentialStore: SecureCredentialStore(),
    cache: DriftCacheStore(database),
    folderLists: PrefsFolderListStore(prefs),
    graphIdMap: DriftGraphIdMap(database),
  );
  return (
    NotificationActions(
      engine: engine,
      accounts: accountStore.read(),
      signatures: readSignatures(PrefsUiStateStore(prefs)),
    ),
    () async {
      await engine.close();
      await database.close();
    },
  );
}

/// Say something only where there is something to say. A reply that went and
/// a message that was deleted are both confirmed by the notification going
/// away; a row saying "Sent" would be one more thing to dismiss.
///
/// [pluginReady] in the app, where the notifications plugin is already set
/// up with the handler that opens a tapped message. Setting it up again
/// replaced that handler with none, and until the app was restarted a tap
/// on new mail brought the app forward without opening the message.
Future<void> reportOutcome(
  ActionOutcome outcome,
  PendingAction action, {
  bool pluginReady = false,
}) async {
  var text = outcome.message;
  if (text == null) return;
  // Not kept anywhere else: shown, so it is not gone for good.
  final typed = action.typed?.trim() ?? '';
  if (outcome.keepsWords && typed.isNotEmpty) {
    text = '$text\n\nWhat you wrote:\n$typed';
  }
  final plugin = FlutterLocalNotificationsPlugin();
  if (!pluginReady) {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_mail'),
      ),
    );
  }
  await plugin.show(
    // Its own id, derived from the message, so two failures for two messages
    // do not overwrite one another.
    id: ('action:${action.messageId}').hashCode & 0x7fffffff,
    title: 'MyEmail',
    body: text,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'mailtree.new-mail',
        'New mail',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.email,
        // Without a style Android shows one line, and a reply typed into
        // the shade was cut off after its first few words.
        styleInformation: BigTextStyleInformation(text),
      ),
    ),
  );
}

/// The signatures the app keeps, read from where it keeps them.
Map<String, Signature> readSignatures(UiStateStore store) {
  final raw = store.readString(UiStateKeys.signatures);
  if (raw == null || raw.isEmpty) return const {};
  return Signature.mapFromJson(raw) ?? const {};
}
