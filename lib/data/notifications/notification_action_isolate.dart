import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

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

/// Carry out everything waiting, with an engine built for the purpose.
///
/// Returns how many were done. Safe to call from anywhere: the queue is
/// taken rather than read, so two callers cannot both act on one press.
Future<int> drainPendingNotificationActions() async {
  final waiting = await PendingActions().take();
  if (waiting.isEmpty) return 0;

  MailDatabase? database;
  CachedImapEngine? engine;
  try {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    database = MailDatabase.open();
    final accountStore = PrefsAccountStore(prefs);
    engine = CachedImapEngine(
      accountStore: accountStore,
      credentialStore: SecureCredentialStore(),
      cache: DriftCacheStore(database),
      folderLists: PrefsFolderListStore(prefs),
      graphIdMap: DriftGraphIdMap(database),
    );
    final actions = NotificationActions(
      engine: engine,
      accounts: accountStore.read(),
      signatures: readSignatures(PrefsUiStateStore(prefs)),
    );
    for (final action in waiting) {
      final outcome = await actions.perform(
        action.actionId,
        action.messageId,
        action.typed,
      );
      await reportOutcome(outcome, action.messageId);
    }
    return waiting.length;
  } catch (e, stack) {
    debugPrint('[myemail] notification action failed: $e');
    debugPrint('$stack');
    return 0;
  } finally {
    await engine?.close();
    await database?.close();
  }
}

/// Say something only where there is something to say. A reply that went and
/// a message that was deleted are both confirmed by the notification going
/// away; a row saying "Sent" would be one more thing to dismiss.
Future<void> reportOutcome(ActionOutcome outcome, String messageId) async {
  final text = outcome.message;
  if (text == null) return;
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_mail'),
    ),
  );
  await plugin.show(
    // Its own id, derived from the message, so two failures for two messages
    // do not overwrite one another.
    id: ('action:$messageId').hashCode & 0x7fffffff,
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
  try {
    final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    return {
      for (final j in list)
        if (Signature.fromJson(j) case final s) s.accountId: s,
    };
  } on FormatException {
    return const {};
  }
}
