import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import 'mail_notifier.dart';
import 'notification_actions.dart';
import 'notification_action_isolate.dart';
import 'pending_actions.dart';
import 'account_badge.dart';

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
    Future<void> Function(PendingAction action)? queueAction,
    Future<Uint8List?> Function(int colorValue)? drawBadge,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _queue = queueAction ?? queueNotificationAction,
        _draw = drawBadge ?? drawAccountBadge;

  final FlutterLocalNotificationsPlugin _plugin;

  /// Writes a button press down for the worker to carry out. Replaced only
  /// by tests.
  final Future<void> Function(PendingAction action) _queue;
  bool _ready = false;
  String? _launchPayload;

  /// Badges already drawn, by colour, so a pass announcing ten messages
  /// to one account draws one.
  final _badges = <int, Future<Uint8List?>>{};

  /// Set once a badge has failed to draw, for the rest of one batch. The
  /// likeliest cause is an isolate with no screen, where every badge would
  /// fail the same way, and each failure can cost the full wait before its
  /// notification goes out.
  ///
  /// Only for the batch: [showNewMail] clears it. Held for good, one slow
  /// draw in a worker that had just started took the badges off every
  /// notification that worker posted, which in push mode is most of an hour.
  bool _badgesFailed = false;

  /// Draws a badge, and for tests, one that fails.
  final Future<Uint8List?> Function(int colorValue) _draw;

  /// The app's dart on the account's colour; see [drawAccountBadge].
  Future<AndroidBitmap<Object>?> _badgeFor(int colorValue) async {
    if (_badgesFailed) return null;
    final png = await _badges.putIfAbsent(colorValue, () => _draw(colorValue));
    if (png == null) {
      _badgesFailed = true;
      // Not kept, so the next batch tries this one again.
      _badges.remove(colorValue);
      return null;
    }
    return ByteArrayAndroidBitmap(png);
  }

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
        // Not where the buttons arrive. A button that does not bring the
        // app forward (all three, see showNewMail) is delivered by Android
        // to a background isolate through notificationActionEntryPoint, app
        // open or not. Should one ever arrive here, it goes the same way:
        // written down for the worker.
        unawaited(_queue(PendingAction(
          actionId: response.actionId!,
          messageId: response.payload ?? '',
          typed: response.input,
        )));
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
    _badgesFailed = false;

    final groupKey = '$_groupPrefix${account.id}';

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
            // The message id, which Android hands back in the list of what
            // is showing and which nothing else there carries: how a
            // message's notification is found again to be taken down.
            tag: n.payload,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.email,
            actions: actions,
            when: n.when.millisecondsSinceEpoch,
            color: Color(account.colorValue),
            largeIcon: await _badgeFor(account.colorValue),
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
          // The group's row wears the account's colour too, so a folded
          // group says whose it is at a glance.
          largeIcon: await _badgeFor(account.colorValue),
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

  static const _groupPrefix = 'mailtree.account.';

  /// What is showing, or nothing if Android will not say. Only Android 6 and
  /// later can list it.
  Future<List<ActiveNotification>> _active() async {
    try {
      return await _plugin.getActiveNotifications();
    } catch (e) {
      debugPrint('[myemail] could not list notifications: $e');
      return const [];
    }
  }

  /// A message's notification: tagged with its id, in an account's group.
  static bool _isMessage(ActiveNotification n) =>
      n.tag != null &&
      n.id != null &&
      (n.groupKey?.startsWith(_groupPrefix) ?? false);

  @override
  Future<Set<String>> shownMessageIds() async {
    await ensureReady();
    return {
      for (final n in await _active())
        if (_isMessage(n)) n.tag!,
    };
  }

  @override
  Future<void> withdraw(bool Function(String messageId) which) async {
    try {
      await ensureReady();
      final active = await _active();
      final emptied = <String>{};
      for (final n in active) {
        if (!_isMessage(n) || !which(n.tag!)) continue;
        await _plugin.cancel(id: n.id!, tag: n.tag);
        emptied.add(n.groupKey!);
      }
      // Android leaves a summary up when the last thing under it goes,
      // saying "2 new messages" over nothing.
      for (final group in emptied) {
        final left = active.any(
            (n) => _isMessage(n) && n.groupKey == group && !which(n.tag!));
        if (left) continue;
        await _plugin.cancel(
            id: _summaryId(group.substring(_groupPrefix.length)));
      }
    } catch (e) {
      debugPrint('[myemail] could not take notifications down: $e');
    }
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
