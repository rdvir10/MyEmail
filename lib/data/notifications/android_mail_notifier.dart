import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import 'mail_notifier.dart';
import 'notification_actions.dart';
import 'notification_action_isolate.dart';
import 'pending_actions.dart';

/// The real notifier, on top of flutter_local_notifications.
///
/// Deliberately thin. Everything about *what* to announce lives in
/// background_sync.dart and new_mail_scan.dart, where it can be tested; this
/// file is the part that can only be checked on a device.
///
/// It is constructed in two different isolates — the app's, and the one
/// Android starts for the background pass — so [ensureReady] has to be safe to
/// call from either, and neither may assume the other has run.
class AndroidMailNotifier implements MailNotifier {
  AndroidMailNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    this.onAction,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Carries out a button press while the app is running.
  ///
  /// Android delivers to the app's own isolate when there is one, and to a
  /// fresh isolate when there is not. The app passes this so the press goes
  /// through the engine that is already open rather than a second one over
  /// the same database; without it the isolate route is used for both, which
  /// works but does the same job twice over.
  final Future<void> Function(NotificationResponse response)? onAction;
  bool _ready = false;
  String? _launchPayload;

  /// One channel, so the user gets one row in Android's notification settings
  /// rather than one per account. Muting a single account is done in the app,
  /// where it can be explained.
  // Still 'mailtree' after the rename: a channel id is how Android remembers
  // the per-channel settings someone has chosen, and a new id silently
  // discards them. The channel's NAME is what the user reads.
  static const channelId = 'mailtree.new-mail';
  static const channelName = 'New mail';

  /// The notification an account's messages are grouped under. Android needs a
  /// summary row as well as the children, or on some versions the group simply
  /// does not collapse.
  static int _summaryId(String accountId) =>
      ('summary:$accountId').hashCode & 0x7fffffff;

  @override
  Future<void> ensureReady() async {
    if (_ready) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        // The launcher icon rather than a dedicated silhouette. Android tints
        // and masks it, so a proper monochrome notification icon is a milestone
        // 8 job alongside the rest of the icon work.
        android: AndroidInitializationSettings('@drawable/ic_stat_mail'),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (!NotificationActions.isKnown(response.actionId)) {
          _launchPayload = response.payload;
          return;
        }
        final handler = onAction;
        unawaited(handler == null
            // No app-side handler: write the press down and let the worker
            // carry it out, the same way a press with no app at all is
            // handled.
            ? queueNotificationAction(PendingAction(
                actionId: response.actionId!,
                messageId: response.payload ?? '',
                typed: response.input,
              ))
            : handler(response));
      },
      onDidReceiveBackgroundNotificationResponse: notificationActionEntryPoint,
    );

    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: 'A message arrived in an inbox you are watching.',
        importance: Importance.high,
      ),
    );

    // A tap that started the app from cold does not go through the callback
    // above: the app was not running to receive it. It arrives here instead.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      _launchPayload = launch?.notificationResponse?.payload;
    }

    _ready = true;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<bool> requestPermission() async {
    await ensureReady();
    return await _android?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<bool> isPermitted() async {
    await ensureReady();
    return await _android?.areNotificationsEnabled() ?? false;
  }

  @override
  Future<void> showNewMail({
    required Account account,
    required MailFolder folder,
    required List<MailNotification> notifications,
  }) async {
    if (notifications.isEmpty) return;
    await ensureReady();

    final groupKey = 'mailtree.account.${account.id}';

    // Three, because Android shows three and hides the rest behind nothing.
    //
    // Reply and Reply all open a box in the shade rather than the app:
    // `showsUserInterface` is false and the text comes back through
    // RemoteInput, so the whole thing happens without the app coming to the
    // front. Delete is the same, without the box.
    //
    // All three dismiss the notification as they are pressed. That is the
    // confirmation; the alternative is a row that sits there saying
    // "Sending..." while the network decides, which is worse to look at and
    // no more honest. Anything that goes wrong afterwards says so in a
    // notification of its own.
    const replyBox = AndroidNotificationActionInput(label: 'Reply');
    const actions = <AndroidNotificationAction>[
      AndroidNotificationAction(
        NotificationActions.replyId,
        'Reply',
        inputs: [replyBox],
        showsUserInterface: false,
        cancelNotification: true,
        semanticAction: SemanticAction.reply,
      ),
      AndroidNotificationAction(
        NotificationActions.replyAllId,
        'Reply all',
        inputs: [AndroidNotificationActionInput(label: 'Reply all')],
        showsUserInterface: false,
        cancelNotification: true,
        semanticAction: SemanticAction.reply,
      ),
      AndroidNotificationAction(
        NotificationActions.deleteId,
        'Delete',
        showsUserInterface: false,
        cancelNotification: true,
        semanticAction: SemanticAction.delete,
      ),
    ];

    for (final n in notifications) {
      await _plugin.show(
        id: n.id,
        title: n.title,
        body: n.body,
        payload: n.payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            groupKey: groupKey,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.email,
            actions: actions,
            when: n.when.millisecondsSinceEpoch,
            color: Color(account.colorValue),
            // The subject and preview are two lines and will be cut off
            // otherwise; expanding the notification should show the whole
            // thing, which is often the entire message.
            styleInformation: BigTextStyleInformation(
              n.body,
              contentTitle: n.title,
              summaryText: account.emailAddress,
            ),
          ),
        ),
      );
    }

    // The summary carries no payload: tapping it opens the app, and which
    // message to show would be a guess.
    await _plugin.show(
      id: _summaryId(account.id),
      title: account.emailAddress,
      body: _summaryLine(notifications.length, folder.displayName),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          groupKey: groupKey,
          setAsGroupSummary: true,
          // Only the children make a sound. Without this the summary alerts
          // too and one delivery buzzes twice.
          groupAlertBehavior: GroupAlertBehavior.children,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.email,
          color: Color(account.colorValue),
          styleInformation: InboxStyleInformation(
            [for (final n in notifications) '${n.title}  ${_firstLine(n.body)}'],
            contentTitle: account.emailAddress,
          ),
        ),
      ),
    );
  }

  static String _summaryLine(int count, String folderName) =>
      count == 1 ? '1 new message in $folderName' : '$count new messages in $folderName';

  static String _firstLine(String body) => body.split('\n').first;

  @override
  Future<void> cancelAll() async {
    await ensureReady();
    await _plugin.cancelAll();
  }

  @override
  Future<String?> takeLaunchPayload() async {
    await ensureReady();
    // Read and cleared, so a rebuild cannot reopen a message already
    // dismissed. Not guarded beyond that: a tap while the app is running
    // arrives through the callback and sets it afresh, and the first
    // version of this returned null forever after the first read, which
    // meant every notification tap after the first did nothing.
    final payload = _launchPayload;
    _launchPayload = null;
    return payload;
  }
}
