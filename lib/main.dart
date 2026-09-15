import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/account_store.dart';
import 'data/cache/mail_database.dart';
import 'data/folder_list_store.dart';
import 'data/imap/cached_imap_engine.dart';
import 'data/mail_engine.dart';
import 'data/sample/sample_mail_engine.dart';
import 'data/notifications/android_mail_notifier.dart';
import 'data/notifications/mail_notifier.dart';
import 'data/secure_credential_store.dart';
import 'data/sync/background_worker.dart';
import 'data/sync/sync_state_store.dart';
import 'data/ui_state_store.dart';
import 'state/notification_providers.dart';
import 'state/providers.dart';
import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';

/// `flutter run --dart-define=MAILTREE_SAMPLE=true` runs the sample engine on
/// a device, for UI work without touching a real mailbox.
const _forceSample = bool.fromEnvironment('MAILTREE_SAMPLE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loaded before the first frame so the tree renders in its remembered shape
  // immediately rather than snapping into it a moment later.
  final prefs = await SharedPreferencesWithCache.create(
    cacheOptions: const SharedPreferencesWithCacheOptions(),
  );

  // The browser preview has no Keystore, no raw sockets and no SQLite, so it
  // always runs on sample data; Android talks to Gmail through the cache.
  final MailEngine engine = (kIsWeb || _forceSample)
      ? SampleMailEngine()
      : CachedImapEngine(
          accountStore: PrefsAccountStore(prefs),
          credentialStore: SecureCredentialStore(),
          cache: DriftCacheStore(MailDatabase.open()),
          folderLists: PrefsFolderListStore(prefs),
        );

  // The browser preview has no WorkManager and no notification channel, so it
  // keeps the recording fake and never schedules anything.
  final onAndroid =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final MailNotifier notifier =
      onAndroid ? AndroidMailNotifier() : FakeMailNotifier(permitted: false);
  final syncState = PrefsSyncStateStore();

  if (onAndroid) {
    // The channel has to exist before the background isolate posts to it, and
    // the schedule has to match what the settings screen says. Doing both here
    // also repairs the case where Android dropped the work while the app was
    // not running.
    await notifier.ensureReady();
    await applyBackgroundSchedule(await syncState.readPrefs());
  }

  runApp(
    ProviderScope(
      overrides: [
        uiStateStoreProvider.overrideWithValue(PrefsUiStateStore(prefs)),
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
        syncStateStoreProvider.overrideWithValue(syncState),
        if (onAndroid)
          backgroundSchedulerProvider
              .overrideWithValue(const WorkManagerScheduler()),
      ],
      child: const MailTreeApp(),
    ),
  );
}

class MailTreeApp extends StatelessWidget {
  const MailTreeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MailTree',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // Light and dark follow the system, as planned.
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
