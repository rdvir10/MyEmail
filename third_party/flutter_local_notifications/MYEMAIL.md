# flutter_local_notifications 22.3.1, with one change

Copied from pub.dev (without `example/` and `test/`) and used through
`dependency_overrides` in the app's `pubspec.yaml`.

**The change:** `preferSmallIcon` in
`android/src/main/java/com/dexterous/flutterlocalnotifications/FlutterLocalNotificationsPlugin.java`,
called just before `builder.build()` in `createNotification`. It sets
Android's `Notification.EXTRA_PREFER_SMALL_ICON` on every notification,
read by reflection (API 37 and later; earlier versions have neither the
constant nor the behaviour).

**Why:** from Android 17 the shade shows the app's launcher icon on each
notification and on its group's header instead of the small icon. MyEmail's
small icon, the dart, is drawn in the notification's colour, the account's,
and that colour on the group header is how one account's mail is told from
another's (asked for on 2026-09-28).

**Upgrading the plugin:** copy the new version from the pub cache over this
folder (again without `example/` and `test/`), put the method and its call
back, and run `flutter test test/notification_plugin_patch_test.dart`,
which fails while the patch is missing.
