import 'dart:async';

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
import 'data/widget/home_screen_surface.dart';
import 'data/contacts/device_contacts.dart';
import 'data/files/attachment_files.dart';
import 'data/files/file_bridge.dart';
import 'data/widget/widget_setup_channel.dart';
import 'data/widget/widget_state_store.dart';
import 'state/sync_providers.dart';
import 'state/update_providers.dart';
import 'state/providers.dart';
import 'state/attachment_providers.dart';
import 'state/contact_providers.dart';
import 'state/widget_providers.dart';
import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';
import 'data/windows/window_opener.dart';
import 'domain/window_handoff.dart';
import 'state/window_providers.dart';
import 'state/message_transfer.dart';
import 'data/files/message_files.dart';
import 'data/print/message_printer.dart';
import 'state/print_providers.dart';
import 'state/calendar_providers.dart';
import 'data/calendar/device_calendar.dart';
import 'ui/shell/window_host.dart';
import 'ui/shell/file_drop_host.dart';
import 'ui/shell/mailbox_widget_keeper.dart';
import 'ui/widgets/mailbox_widget_setup.dart';

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

  // The browser preview has no WorkManager and no notification channel, so it
  // keeps the recording fake and never schedules anything.
  final onAndroid =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  // A notification's buttons never come through here. None of them brings
  // the app forward, and Android delivers such a press to a background
  // isolate whether the app is open or not (see
  // notificationActionEntryPoint); the worker that carries it out tells
  // [AppShell], which re-reads the lists.
  final MailNotifier notifier =
      onAndroid ? AndroidMailNotifier() : FakeMailNotifier(permitted: false);

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
          // Mail read, filed or deleted here takes its notification with it.
          onMessagesHandled: (handled) => unawaited(notifier.withdraw(handled)),
        );

  final syncState = PrefsSyncStateStore();

  // A second window: this copy of the app was opened to show one thing.
  // Decided before anything that belongs to the main window — background
  // sync, notifications, widgets — because a window is not the app, and a
  // second copy scheduling the same work would double it.
  final window = await windowRequestFromRoute(
    WidgetsBinding.instance.platformDispatcher.defaultRouteName,
  );

  if (onAndroid && window == null) {
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
      // Without restarting a live worker already running: see [restart].
      await applyBackgroundSchedule(
        await syncState.readPrefs(),
        restart: false,
      );
    } catch (e, stack) {
      debugPrint('[myemail] notification setup failed at startup: $e');
      debugPrint('$stack');
    }
  }

  // Android opens the app with a configure intent when a home-screen widget
  // is dropped, and expects to be told which mailbox it ended up showing.
  // Read before runApp because it decides what the first screen is.
  final widgetToSetUp = window == null ? await widgetAwaitingSetup() : null;

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
          windowOpenerProvider.overrideWithValue(const AndroidWindowOpener()),
          messageFilesProvider.overrideWithValue(const DiskMessageFiles()),
          messagePrinterProvider.overrideWithValue(const AndroidMessagePrinter()),
          deviceCalendarProvider.overrideWithValue(const AndroidDeviceCalendar()),
          fileBridgeProvider.overrideWithValue(platformFileBridge()),
          deviceContactsProvider.overrideWithValue(platformDeviceContacts()),
          attachmentFilesProvider
              .overrideWithValue(const DiskAttachmentFiles()),
          releaseFeedProvider.overrideWithValue(HttpReleaseFeed()),
          apkInstallerProvider.overrideWithValue(AndroidApkInstaller()),
          homeScreenSurfaceProvider
              .overrideWithValue(const AndroidHomeScreenSurface()),
          widgetStateStoreProvider
              .overrideWithValue(PrefsWidgetStateStore()),
        ],
      ],
      child: MyEmailApp(widgetToSetUp: widgetToSetUp, window: window),
    ),
  );
}

class MyEmailApp extends StatefulWidget {
  const MyEmailApp({super.key, this.widgetToSetUp, this.window});

  /// The home-screen widget Android is waiting to hear about, if the app was
  /// opened by placing one.
  final String? widgetToSetUp;

  /// What this copy of the app is a window for, when it is one.
  final WindowRequest? window;

  @override
  State<MyEmailApp> createState() => _MyEmailAppState();
}

class _MyEmailAppState extends State<MyEmailApp> {
  /// So a widget placed while the app was already running can be set up
  /// without main() running again. See listenForWidgetSetup.
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    listenForWidgetSetup((appWidgetId) {
      _navigator.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => MailboxWidgetSetup(appWidgetId: appWidgetId),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final widgetToSetUp = widget.widgetToSetUp;
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'MyEmail',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // Light and dark follow the system, as planned.
      themeMode: ThemeMode.system,
      home: switch ((widget.window, widgetToSetUp)) {
        (final WindowRequest request, _) =>
          FileDropHost(child: WindowHost(request: request)),
        (null, final String appWidgetId) =>
          MailboxWidgetSetup(appWidgetId: appWidgetId),
        (null, null) =>
          const FileDropHost(child: MailboxWidgetKeeper(child: AppShell())),
      },
    );
  }
}
