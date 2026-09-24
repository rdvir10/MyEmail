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
import 'notification_actions.dart';
import 'pending_actions.dart';

/// Answering a notification's buttons when the app is not running.
///
/// Android starts a second Dart isolate for this and gives it very little
/// time. The plugin's callback returns `void`, so nothing waits for what is
/// started inside it, and carrying out a delete means a round trip to the
/// mail server — which the isolate does not reliably survive. That is why
/// pressing Delete appeared to do nothing at all: the notification went
/// away, because Android dismisses it, and the message stayed put.
///
/// So this does the one thing that is quick and cannot half-happen: it
/// writes the press down. The work is then done by something with a proper
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
/// write is a single preferences entry and lands in milliseconds; the job
/// that follows is what has the time to do the rest.
Future<void> queueNotificationAction(PendingAction action) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    await PendingActions().add(action);
    await runPendingNotificationActions();
  } catch (e, stack) {
    debugPrint('[myemail] could not queue a notification action: $e');
    debugPrint('$stack');
  }
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
  const DrainResult({this.done = 0, this.waiting = 0});

  /// Carried out, or finally given up on and reported.
  final int done;

  /// Put back for another try: offline, or failed and not yet given up on.
  final int waiting;
}

/// How many real failures a press gets before it is given up on and
/// reported. Being offline is not counted.
const maxActionAttempts = 5;

/// Carry out everything waiting, with an engine built for the purpose.
///
/// Safe to call from anywhere: each press is claimed by exactly one caller.
/// A press that cannot be carried out now goes back in the queue, and one
/// action failing, or its report failing, does not stop the rest. The queue
/// used to be emptied before anything was tried, so opening the app offline
/// threw away a reply typed into a notification.
///
/// [open] and [report] are for tests; [report] also lets the app post
/// through a notifier that is already set up (see [reportOutcome]).
Future<DrainResult> drainPendingNotificationActions({
  PendingActions? queue,
  Future<(NotificationActions, Future<void> Function())> Function()? open,
  Future<void> Function(ActionOutcome outcome, PendingAction action)? report,
}) async {
  final pending = queue ?? PendingActions();
  final claimed = await pending.take();
  if (claimed.isEmpty) return const DrainResult();

  final NotificationActions actions;
  final Future<void> Function() close;
  try {
    (actions, close) = await (open ?? _openActions)();
  } catch (e, stack) {
    debugPrint('[myemail] could not open the mail to act on: $e');
    debugPrint('$stack');
    for (final claim in claimed) {
      await pending.putBack(claim, counted: false);
    }
    return DrainResult(waiting: claimed.length);
  }

  var done = 0;
  var waiting = 0;
  try {
    for (final claim in claimed) {
      final action = claim.action;
      ActionOutcome outcome;
      try {
        outcome = await actions.perform(
          action.actionId,
          action.messageId,
          action.typed,
        );
      } catch (_) {
        outcome = ActionOutcome.failed;
      }
      final offline = outcome == ActionOutcome.offline;
      if (outcome.worthRetrying &&
          (offline || action.attempts + 1 < maxActionAttempts)) {
        await pending.putBack(claim, counted: !offline);
        waiting++;
        continue;
      }
      await pending.done(claim);
      done++;
      try {
        await (report ?? reportOutcome)(outcome, action);
      } catch (e) {
        debugPrint('[myemail] could not report a notification action: $e');
      }
    }
  } finally {
    await close();
  }
  return DrainResult(done: done, waiting: waiting);
}

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
  // Given up on: what was typed is shown, rather than gone for good.
  final typed = action.typed?.trim() ?? '';
  if (outcome == ActionOutcome.notKept && typed.isNotEmpty) {
    text = '$text What you wrote: "$typed"';
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
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'mailtree.new-mail',
        'New mail',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.email,
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
