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
import '../ui_state_store.dart';
import 'notification_actions.dart';

/// Answering a notification's buttons when the app is not running.
///
/// Android starts a second Dart isolate for this, exactly as it does for the
/// background sync, and it shares nothing with the app: no providers, no open
/// database, not even the plugin registrations. So everything is rebuilt here
/// from what is on disk, used once, and closed.
///
/// The entry point has to be top-level and annotated, or the compiler drops it
/// from a release build and every button press does nothing at all.
@pragma('vm:entry-point')
void notificationActionEntryPoint(NotificationResponse response) {
  handleNotificationActionInIsolate(response);
}

Future<void> handleNotificationActionInIsolate(
  NotificationResponse response,
) async {
  final actionId = response.actionId;
  final messageId = response.payload;
  if (!NotificationActions.isKnown(actionId) ||
      messageId == null ||
      messageId.isEmpty) {
    return;
  }

  DartPluginRegistrant.ensureInitialized();

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

    final outcome = await NotificationActions(
      engine: engine,
      accounts: accountStore.read(),
      signatures: readSignatures(PrefsUiStateStore(prefs)),
    ).perform(actionId!, messageId, response.input);

    await reportOutcome(outcome, messageId);
  } catch (e, stack) {
    // Nothing above this catches: a throw here is an isolate that dies
    // silently and a button that appears to do nothing.
    debugPrint('[myemail] notification action failed: $e');
    debugPrint('$stack');
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
