# flutter_local_notifications 22.3.1, with two changes

Copied from pub.dev (without `example/` and `test/`) and used through
`dependency_overrides` in the app's `pubspec.yaml`.

**The first change:** `preferSmallIcon` in
`android/src/main/java/com/dexterous/flutterlocalnotifications/FlutterLocalNotificationsPlugin.java`,
called just before `builder.build()` in `createNotification`. It sets
Android's `Notification.EXTRA_PREFER_SMALL_ICON` on every notification,
read by reflection (API 37 and later; earlier versions have neither the
constant nor the behaviour). Where it sets it, it also takes the large icon
off: MyEmail's large icon is the same dart on the same colour, drawn for the
Android versions that show the launcher icon, and beside the small icon it
was the same picture twice (asked for on 2026-09-28).

**Why:** from Android 17 the shade shows the app's launcher icon on each
notification and on its group's header instead of the small icon. MyEmail's
small icon, the dart, is drawn in the notification's colour, the account's,
and that colour on the group header is how one account's mail is told from
another's (asked for on 2026-09-28).

**The second change:** `uniqueButtonIntent`, called on each notification
button's intent in `createNotification` just after its extras are put. It
gives a button that does not open the app a data URI made of the
notification's id, tag and the action's id. Android matches PendingIntents
by request code, action, data and component, but not by extras. The
plugin's request code is `id * 16`, which overflows and keeps 28 bits of
the id, and MyEmail's ids are hashes of message ids. Two notifications
could therefore share their buttons, and the newer one's
`FLAG_UPDATE_CURRENT` rewrote the older one's extras, so Delete on the
older row deleted the newer message (found on 2026-09-28, when the buttons
first worked). The receiver has no intent filter, so the data changes
nothing about delivery.

**The app's side:** the plugin's manifest does not declare
`ActionBroadcastReceiver`, which every button is a broadcast to. The app's
own manifest must (`android/app/src/main/AndroidManifest.xml`); until
2.66.0 it did not, and no button press ever arrived.
`test/notification_receiver_manifest_test.dart` checks it.

**Upgrading the plugin:** copy the new version from the pub cache over this
folder (again without `example/` and `test/`), put both methods and their calls
back, and run `flutter test test/notification_plugin_patch_test.dart`,
which fails while either is missing.
