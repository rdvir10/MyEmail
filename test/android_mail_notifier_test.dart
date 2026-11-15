import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/android_mail_notifier.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/notifications/pending_actions.dart';

/// Taps and button presses through the real notifier, with only Android's
/// plugin faked.
///
/// The bug that made every tap after the first do nothing was in this
/// class's own read-and-clear, and the test that named it went through the
/// fake notifier instead, which has a read-and-clear of its own.
void main() {
  late _Plugin plugin;
  late List<PendingAction> actions;
  late AndroidMailNotifier notifier;

  setUp(() {
    plugin = _Plugin();
    actions = [];
    notifier = AndroidMailNotifier(
      plugin: plugin,
      queueAction: (action) async => actions.add(action),
    );
  });

  NotificationResponse tap(String payload) => NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: payload,
      );

  test('every tap opens its message, not only the first', () async {
    await notifier.ensureReady();

    plugin.tapped!(tap('a:INBOX#1'));
    expect(await notifier.takeLaunchPayload(), 'a:INBOX#1');
    expect(await notifier.takeLaunchPayload(), isNull,
        reason: 'read once, so a rebuild does not open it again');

    plugin.tapped!(tap('a:Travel#7'));
    expect(await notifier.takeLaunchPayload(), 'a:Travel#7');
  });

  test('a button that ever arrives here is queued, and opens nothing',
      () async {
    // Android sends the buttons to a background isolate, app open or not,
    // so this path is not normally taken. If it is, the press goes to the
    // worker like any other rather than being lost.
    await notifier.ensureReady();

    plugin.tapped!(const NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: NotificationActions.deleteId,
      payload: 'a:INBOX#1',
    ));
    await pumpEventQueue();

    expect(actions.single.actionId, NotificationActions.deleteId);
    expect(actions.single.messageId, 'a:INBOX#1');
    expect(await notifier.takeLaunchPayload(), isNull,
        reason: 'Delete must not open the message it deleted');
  });

  test('a tap is not taken for a button', () async {
    await notifier.ensureReady();

    plugin.tapped!(tap('a:INBOX#1'));
    await pumpEventQueue();

    expect(actions, isEmpty);
  });

  test('a tap that started the app is opened once', () async {
    plugin.launch = NotificationAppLaunchDetails(
      true,
      notificationResponse: tap('a:INBOX#3'),
    );

    expect(await notifier.takeLaunchPayload(), 'a:INBOX#3');
    expect(await notifier.takeLaunchPayload(), isNull);
  });

  // Android brings the app back with the intent it was first started with,
  // after stopping it in the background or from Recents, and the plugin
  // answers the launch details above from that intent. A press that had
  // started the app was taken again: its message opened again, Join opened
  // the meeting's link again, Accept asked again how to answer. The
  // Android half, which no Dart test runs, read where it is written.
  test('a press that started the app is not taken again when Android '
      'brings the app back', () {
    String read(String path) => File(path).readAsStringSync();
    final plugin = read('third_party/flutter_local_notifications/android/src/'
        'main/java/com/dexterous/flutterlocalnotifications/'
        'FlutterLocalNotificationsPlugin.java');
    // What the plugin calls a press that opens the app, and the intent it
    // reads the launch details from.
    final actions = [
      for (final name in [
        'SELECT_NOTIFICATION',
        'SELECT_FOREGROUND_NOTIFICATION_ACTION',
      ])
        RegExp('String $name =\\s*"(\\w+)";').firstMatch(plugin)!.group(1)!,
    ];
    expect(plugin, contains('Intent launchIntent = mainActivity.getIntent();'));

    final activity =
        read('android/app/src/main/kotlin/com/rdvir/mailtree/MainActivity.kt');
    final onCreate = RegExp(r'override fun onCreate\([\s\S]*?\n    }')
        .firstMatch(activity)!
        .group(0)!;
    final plain = RegExp(
      r'if \(restarted &&\s*\(action == SELECT_NOTIFICATION \|\| '
      r'action == SELECT_FOREGROUND_NOTIFICATION\)\s*\) \{\s*'
      r'intent = Intent\(intent\)\.setAction\(Intent\.ACTION_MAIN\)',
    ).firstMatch(onCreate);
    expect(plain, isNotNull,
        reason: 'on a restart, a press is made a plain start');
    expect(onCreate, contains('val action = intent.action'));
    expect(plain!.start, lessThan(onCreate.indexOf('super.onCreate')),
        reason: 'the plugin reads the intent once Flutter has started');
    expect(onCreate.indexOf('restarted ='), lessThan(plain.start));
    expect(activity,
        contains('const val SELECT_NOTIFICATION = "${actions[0]}"'));
    expect(activity,
        contains('const val SELECT_FOREGROUND_NOTIFICATION = "${actions[1]}"'));
  });
}

/// Android's side, reduced to what the notifier asks of it at startup.
class _Plugin implements FlutterLocalNotificationsPlugin {
  DidReceiveNotificationResponseCallback? tapped;
  NotificationAppLaunchDetails? launch;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    tapped = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async =>
      launch;

  @override
  T? resolvePlatformSpecificImplementation<
      T extends FlutterLocalNotificationsPlatform>() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
