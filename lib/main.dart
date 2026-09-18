import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/account_store.dart';
import 'data/cache/mail_database.dart';
import 'data/graph/graph_id_map.dart';
import 'data/folder_list_store.dart';
import 'data/imap/cached_imap_engine.dart';
import 'data/mail_engine.dart';
import 'data/sample/sample_mail_engine.dart';
import 'data/notifications/android_mail_notifier.dart';
import 'data/notifications/mail_notifier.dart';
import 'data/secure_credential_store.dart';
import 'data/sync/background_worker.dart';
import 'data/sync/sync_state_store.dart';
import 'data/updates/apk_installer.dart';
import 'data/updates/update_service.dart';
import 'data/ui_state_store.dart';
import 'state/sync_providers.dart';
import 'state/update_providers.dart';
import 'state/providers.dart';
import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';

/// `flutter run --dart-define=MYEMAIL_SAMPLE=true` runs the sample engine on
/// a device, for UI work without touching a real mailbox.
const _forceSample = bool.fromEnvironment('MYEMAIL_SAMPLE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loaded before the first frame so the tree renders in its remembered shape
  // immediately rather than snapping into it a moment later.
  final prefs = await SharedPreferencesWithCache.create(
    cacheOptions: const SharedPreferencesWithCacheOptions(),
  );

  // The browser preview has no Keystore, no raw sockets and no SQLite, so it
  // always runs on sample data; Android talks to Gmail through the cache.
  // One instance, shared: the engine writes accounts through it and backup
  // reads them through the provider below. Two stores over the same
  // preferences would each hold their own idea of the list.
  final database = MailDatabase.open();
  final accountStore = PrefsAccountStore(prefs);
  final credentialStore = SecureCredentialStore();

  final MailEngine engine = (kIsWeb || _forceSample)
      ? SampleMailEngine()
      : CachedImapEngine(
          accountStore: accountStore,
          credentialStore: credentialStore,
          cache: DriftCacheStore(database),
          // The same database: Graph message numbering lives beside the
          // cache it exists to key, and two connections to one file would be
          // two views of the same rows.
          graphIdMap: DriftGraphIdMap(database),
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
    //
    // Caught, not allowed to propagate: this runs before runApp, so anything
    // thrown here is an app that does not start. A mail client that will not
    // open because the notification channel failed is a far worse outcome
    // than one whose notifications are not working, and the Notifications
    // screen is where the second is noticed and retried.
    try {
      await notifier.ensureReady();
      await applyBackgroundSchedule(await syncState.readPrefs());
    } catch (e, stack) {
      debugPrint('[myemail] notification setup failed at startup: $e');
      debugPrint('$stack');
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        uiStateStoreProvider.overrideWithValue(PrefsUiStateStore(prefs)),
        accountStoreProvider.overrideWithValue(accountStore),
        credentialStoreProvider.overrideWithValue(credentialStore),
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
        syncStateStoreProvider.overrideWithValue(syncState),
        if (onAndroid)
          backgroundSchedulerProvider
              .overrideWithValue(const WorkManagerScheduler()),
        installedVersionProvider
            .overrideWithValue(const PackageInstalledVersion()),
        if (onAndroid) ...[
          releaseFeedProvider.overrideWithValue(HttpReleaseFeed()),
          apkInstallerProvider.overrideWithValue(AndroidApkInstaller()),
        ],
      ],
      child: const MyEmailApp(),
    ),
  );
}

class MyEmailApp extends StatelessWidget {
  const MyEmailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyEmail',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // Light and dark follow the system, as planned.
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
