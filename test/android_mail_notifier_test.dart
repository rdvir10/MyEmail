import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/android_mail_notifier.dart';
import 'package:myemail/data/notifications/notification_actions.dart';

/// Taps and button presses through the real notifier, with only Android's
/// plugin faked.
///
/// The bug that made every tap after the first do nothing was in this
/// class's own read-and-clear, and the test that named it went through the
/// fake notifier instead, which has a read-and-clear of its own.
void main() {
  late _Plugin plugin;
  late List<NotificationResponse> actions;
  late AndroidMailNotifier notifier;

  setUp(() {
    plugin = _Plugin();
    actions = [];
    notifier = AndroidMailNotifier(
      plugin: plugin,
      onAction: (response) async => actions.add(response),
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

  test('a button is carried out, and opens nothing', () async {
    await notifier.ensureReady();

    plugin.tapped!(const NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: NotificationActions.deleteId,
      payload: 'a:INBOX#1',
    ));
    await pumpEventQueue();

    expect(actions.single.actionId, NotificationActions.deleteId);
    expect(actions.single.payload, 'a:INBOX#1');
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
