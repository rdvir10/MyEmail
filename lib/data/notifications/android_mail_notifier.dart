import 'package:flutter/services.dart' show PlatformException;
import 'package:timezone/timezone.dart' as tz;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import '../../domain/meeting_alerts.dart';
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
    Future<Uint8List?> Function(int colorValue)? drawCalendar,
    Future<Directory?> Function()? postingMarks,
    Future<Directory?> Function()? badgeFiles,
    DateTime Function()? clock,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _queue = queueAction ?? queueNotificationAction,
        _draw = drawBadge ?? drawAccountBadge,
        // A test's one drawer draws both, unless it gives the calendar's.
        _drawCalendar = drawCalendar ?? drawBadge ?? drawCalendarBadge,
        _marks = postingMarks ?? _defaultMarks,
        _badgeFiles = badgeFiles ?? _defaultBadgeFiles,
        _clock = clock ?? DateTime.now;

  /// The time, for [_scheduleAt]: a test's own.
  final DateTime Function() _clock;

  /// Where [showNewMail] notes that it is posting under an account's group,
  /// so [dropEmptySummaries] in another isolate leaves that group alone:
  /// cancelling a summary cancels every row under it, the new one included.
  /// A file, because the isolates share nothing else. Null where there is
  /// nowhere to put one (a test), and then nothing is noted.
  final Future<Directory?> Function() _marks;

  static Future<Directory?> _defaultMarks() async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}notify-posting',
      );
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// How long after a post began its group is left alone. Android takes a
  /// moment to show what it was given, and a cancel in that moment still
  /// takes the new row with the summary.
  static const postingQuiet = Duration(seconds: 3);

  Future<File?> _markFor(String group) async {
    final dir = await _marks();
    return dir == null
        ? null
        : File('${dir.path}${Platform.pathSeparator}$group');
  }

  Future<void> _notePosting(String group) async {
    try {
      await (await _markFor(group))?.writeAsString('', flush: true);
    } catch (_) {
      // Unnoted, the race is only as it was before.
    }
  }

  Future<bool> _postingNow(String group) async {
    try {
      final mark = await _markFor(group);
      if (mark == null || !await mark.exists()) return false;
      return DateTime.now().difference(await mark.lastModified()) <
          postingQuiet;
    } catch (_) {
      return false;
    }
  }

  final FlutterLocalNotificationsPlugin _plugin;

  /// Writes a button press down for the worker to carry out. Replaced only
  /// by tests.
  final Future<void> Function(PendingAction action) _queue;
  bool _ready = false;
  String? _launchPayload;

  /// Badges already found or drawn, by colour and by what is on them (the
  /// dart, or the calendar), so a pass announcing ten messages to one
  /// account looks for one.
  final _badges = <(int, bool), Future<AndroidBitmap<Object>?>>{};

  /// Where a badge is kept once it is drawn, a PNG by its colour and kind.
  /// The background isolates have no screen to draw on, and until this was
  /// kept their notifications went up without one (on the tablet,
  /// 2026-11-16, no mail notification had its badge): whichever isolate can
  /// draw does so once, and the rest find the file. A notification set for
  /// later then carries the file's name, not a picture's bytes, in what
  /// Android keeps of it. Null where there is nowhere to keep one (a test),
  /// and then the picture goes as bytes, as before.
  final Future<Directory?> Function() _badgeFiles;

  static Future<Directory?> _defaultBadgeFiles() async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}notify-badges',
      );
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// The file of a badge. The number in its name changes when the drawing
  /// does, so a new build is not left with an old build's pictures.
  Future<File?> _badgeFile(int colorValue, bool calendar) async {
    final dir = await _badgeFiles();
    if (dir == null) return null;
    final colour = colorValue.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return File('${dir.path}${Platform.pathSeparator}'
        'v1-${calendar ? 'calendar' : 'dart'}-$colour.png');
  }

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

  /// Draws a calendar's badge; see [drawCalendarBadge].
  final Future<Uint8List?> Function(int colorValue) _drawCalendar;

  /// The app's dart on the account's colour, or with [calendar] a calendar
  /// on it; see [drawAccountBadge] and [drawCalendarBadge]. From its file
  /// where it has been drawn before, by this isolate or another.
  Future<AndroidBitmap<Object>?> _badgeFor(
    int colorValue, {
    bool calendar = false,
  }) async {
    final key = (colorValue, calendar);
    final badge = await _badges.putIfAbsent(
        key, () => _findOrDraw(colorValue, calendar));
    // Not kept, so the next batch tries this one again.
    if (badge == null) _badges.remove(key);
    return badge;
  }

  Future<AndroidBitmap<Object>?> _findOrDraw(
    int colorValue,
    bool calendar,
  ) async {
    File? file;
    try {
      file = await _badgeFile(colorValue, calendar);
      if (file != null && await file.exists() && await file.length() > 0) {
        return FilePathAndroidBitmap(file.path);
      }
    } catch (_) {
      // Not to be read: drawn, then.
    }
    if (_badgesFailed) return null;
    final png = await (calendar ? _drawCalendar : _draw)(colorValue);
    if (png == null) {
      _badgesFailed = true;
      return null;
    }
    if (file != null) {
      try {
        // Beside it and then renamed, so no isolate reads half a picture;
        // under a name of its own, since two isolates may draw at once.
        final part = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part');
        await part.writeAsBytes(png, flush: true);
        await part.rename(file.path);
        return FilePathAndroidBitmap(file.path);
      } catch (_) {
        // Not kept: as bytes this once.
      }
    }
    return ByteArrayAndroidBitmap(png);
  }

  /// Draws and keeps the badges of [colours], both kinds, where they are
  /// not kept already. The app calls this with every account's colour while
  /// it has a screen, so that the background, which has none, finds them.
  @override
  Future<void> prepareBadges(Iterable<int> colours) async {
    // A batch of its own, as [showNewMail] is: one that failed before is
    // tried again, and one failure now spares the rest the wait.
    _badgesFailed = false;
    for (final colour in colours.toSet()) {
      await _badgeFor(colour);
      await _badgeFor(colour, calendar: true);
    }
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
        // A meeting reminder's Join brings the app forward to open the
        // meeting's link; Snooze is done here and now.
        if (response.actionId == NotificationActions.joinId) {
          _launchPayload = MeetingRef.joining(response.payload);
          return;
        }
        if (response.actionId == NotificationActions.snoozeId) {
          unawaited(snoozeMeetingReminder(
            response.id,
            response.payload,
            notifier: this,
          ));
          return;
        }
        // An invitation's Accept or Decline brings the app forward to open
        // the invitation and ask how the answer goes.
        if (_opensInvitation(response.actionId)) {
          _launchPayload = NotificationActions.answering(
            response.actionId,
            response.payload,
          );
          unawaited(_takeDownOpened(response.id, response.payload));
          return;
        }
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
      final response = launch?.notificationResponse;
      _launchPayload = response?.actionId == NotificationActions.joinId
          ? MeetingRef.joining(response?.payload)
          : NotificationActions.answering(
              response?.actionId,
              response?.payload,
            );
      if (_opensInvitation(response?.actionId)) {
        unawaited(_takeDownOpened(response?.id, response?.payload));
      }
    }

    _ready = true;
  }

  static bool _opensInvitation(String? actionId) =>
      actionId == NotificationActions.acceptId ||
      actionId == NotificationActions.declineId;

  /// A message's row taken down as one of its buttons opens the app. The
  /// plugin takes it down for such a button by its id alone, and a
  /// message's row also has the message id for a tag, so it stayed.
  /// Without [ensureReady], which may be what is running.
  Future<void> _takeDownOpened(int? id, String? messageId) async {
    if (id == null || messageId == null || messageId.isEmpty) return;
    try {
      await _plugin.cancel(id: id, tag: messageId);
      await dropEmptySummaries(gone: {messageId});
    } catch (e) {
      debugPrint('[myemail] could not take an opened notification down: $e');
    }
  }

  /// Follow Up's reminders, a channel of their own: Android's settings can
  /// then treat them apart from new mail.
  static const reminderChannelId = 'mailtree.reminders';

  @override
  Future<bool> scheduleReminder({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String payload,
  }) async {
    await ensureReady();
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        reminderChannelId,
        'Reminders',
        description: 'A message you flagged with a reminder is due.',
        importance: Importance.high,
      ),
    );
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        reminderChannelId,
        'Reminders',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
      ),
    );
    await _scheduleAt(
      id,
      at,
      details,
      title: title,
      body: body,
      payload: payload,
    );
    return true;
  }

  /// A notification set with Android for [at], on time where it is let be.
  /// One whose time has come, or comes in the next second, goes off now.
  Future<void> _scheduleAt(
    int id,
    DateTime at,
    NotificationDetails details, {
    required String title,
    required String body,
    required String payload,
  }) async {
    // The plugin throws at a time that has passed. A reminder set for a
    // moment on, a meeting made inside its own reminder time, could have
    // passed by now: its calendars were read first, which takes seconds.
    final now = _clock();
    final due = at.isBefore(now.add(const Duration(seconds: 1)))
        ? now.add(const Duration(seconds: 2))
        : at;
    // An instant, so UTC will do: nothing repeats by the clock.
    final when = tz.TZDateTime.from(due.toUtc(), tz.UTC);
    Future<void> schedule(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id: id,
          scheduledDate: when,
          notificationDetails: details,
          androidScheduleMode: mode,
          title: title,
          body: body,
          payload: payload,
        );
    try {
      // On time: USE_EXACT_ALARM allows it from Android 13. Where it is not
      // allowed, within Android's window rather than not at all.
      await schedule(AndroidScheduleMode.exactAllowWhileIdle);
    } on PlatformException catch (e) {
      debugPrint('[myemail] exact reminder refused, set inexact: $e');
      await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  /// The calendar's notifications, and mail about a meeting, wear a
  /// calendar, not the envelope other mail has:
  /// res/drawable/ic_stat_event.xml, kept in a release build by
  /// res/raw/keep.xml, as the envelope is.
  static const calendarIcon = '@drawable/ic_stat_event';

  /// The app's own colour, the launcher icon's orange: for a calendar
  /// notification that is no one account's.
  static const appColour = 0xFFFF7A18;

  /// Meeting reminders and the morning's agenda, each a channel of its
  /// own, so Android's settings can quieten one and keep the other.
  static const meetingChannelId = 'mailtree.meetings';
  static const agendaChannelId = 'mailtree.agenda';

  @override
  Future<bool> scheduleMeetingReminder(MeetingReminder reminder) async {
    await ensureReady();
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        meetingChannelId,
        'Meeting reminders',
        description: 'A meeting on one of your calendars is about to begin.',
        importance: Importance.high,
      ),
    );
    final meeting = reminder.meeting;
    final lasts = meeting.end.difference(reminder.at).inMilliseconds;
    final colour = meeting.colour;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        meetingChannelId,
        'Meeting reminders',
        icon: calendarIcon,
        // Whose calendar it is on, as mail says whose mailbox: the small
        // icon's colour, and a calendar on that colour at the side. A
        // Samsung draws the app's own icon on every row, whatever is set
        // here, and the picture at the side is then the one thing on the
        // row that says calendar, and whose (Ron's tablet, 2026-11-16).
        color: colour == null ? null : Color(colour),
        largeIcon:
            colour == null ? null : await _badgeFor(colour, calendar: true),
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.event,
        // The time left to its start in the corner, counting down.
        when: meeting.start.millisecondsSinceEpoch,
        usesChronometer: true,
        chronometerCountDown: true,
        // Gone by itself once the meeting is over.
        timeoutAfter: lasts > 0 ? lasts : null,
        styleInformation: BigTextStyleInformation(meeting.body),
        actions: [
          if (reminder.canJoin)
            const AndroidNotificationAction(
              NotificationActions.joinId,
              'Join',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          // Outlook's three, as chips under the row; a number typed in
          // does as well.
          if (reminder.canTellLate)
            const AndroidNotificationAction(
              NotificationActions.lateId,
              'Running late',
              inputs: [
                AndroidNotificationActionInput(
                  label: 'Minutes late',
                  choices: ['5 min late', '10 min late', '15 min late'],
                ),
              ],
              showsUserInterface: false,
              cancelNotification: true,
            ),
          const AndroidNotificationAction(
            NotificationActions.snoozeId,
            'Snooze',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
    );
    await _scheduleAt(
      reminder.id,
      reminder.at,
      details,
      title: meeting.title,
      body: meeting.body,
      payload: meeting.payload,
    );
    return true;
  }

  /// On the meeting reminders' channel, so Android's settings treat it as
  /// they treat those, and on time as they are: no new channel and no new
  /// permission.
  @override
  Future<bool> scheduleDayReminder(DayReminder reminder) async {
    await ensureReady();
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        meetingChannelId,
        'Meeting reminders',
        description: 'A meeting on one of your calendars is about to begin.',
        importance: Importance.high,
      ),
    );
    final lasts = reminder.until.difference(reminder.at).inMilliseconds;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        meetingChannelId,
        'Meeting reminders',
        icon: calendarIcon,
        // A day's events may be on several accounts' calendars: the
        // calendar at the side is on the app's own colour.
        color: const Color(appColour),
        largeIcon: await _badgeFor(appColour, calendar: true),
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.event,
        // Its "Today" or "Tomorrow" is wrong once its own day is over.
        timeoutAfter: lasts > 0 ? lasts : null,
        styleInformation: BigTextStyleInformation(reminder.body),
      ),
    );
    await _scheduleAt(
      reminder.id,
      reminder.at,
      details,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payload,
    );
    return true;
  }

  @override
  Future<bool> scheduleAgenda({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required List<String> lines,
    required String payload,
  }) async {
    await ensureReady();
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        agendaChannelId,
        'Morning agenda',
        description: "The day's meetings, on a working morning.",
        importance: Importance.defaultImportance,
      ),
    );
    final midnight = DateTime(at.year, at.month, at.day + 1);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        agendaChannelId,
        'Morning agenda',
        icon: calendarIcon,
        // Every account's meetings: the app's own colour, as an all-day
        // reminder has it.
        color: const Color(appColour),
        largeIcon: await _badgeFor(appColour, calendar: true),
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.event,
        // The day's, so gone at its end rather than left under the next.
        timeoutAfter: midnight.difference(at).inMilliseconds,
        styleInformation: InboxStyleInformation(
          lines,
          contentTitle: title,
          summaryText: body,
        ),
      ),
    );
    await _scheduleAt(
      id,
      at,
      details,
      title: title,
      body: body,
      payload: payload,
    );
    return true;
  }

  @override
  Future<void> cancelReminder(int id) async {
    await ensureReady();
    await _plugin.cancel(id: id);
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
    // Before the first row goes up: see [_marks].
    await _notePosting(groupKey);

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
    // An invitation's Accept and Decline open it in the app, which asks
    // how the answer goes as its card does: sent now, with a message, or
    // not sent at all. Reply stays, for a word to the organiser.
    const invitationActions = <AndroidNotificationAction>[
      AndroidNotificationAction(
        NotificationActions.acceptId,
        'Accept',
        showsUserInterface: true,
        cancelNotification: true,
      ),
      AndroidNotificationAction(
        NotificationActions.declineId,
        'Decline',
        showsUserInterface: true,
        cancelNotification: true,
      ),
      AndroidNotificationAction(
        NotificationActions.replyId,
        'Reply',
        inputs: [replyBox],
        showsUserInterface: false,
        cancelNotification: true,
        semanticAction: SemanticAction.reply,
      ),
    ];
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
            // In a meeting, for an account quiet in meetings: this one row
            // goes up without a sound, a vibration or a pop-up, on the same
            // channel (Android's setSilent, which makes it a child that
            // leaves the alerting to its summary, and the summary never
            // alerts: see groupAlertBehavior below).
            silent: n.silent,
            // Meeting mail wears the calendar, as the reminders do; the
            // rest the envelope set in ensureReady.
            icon: n.meeting ? calendarIcon : null,
            actions: n.invitation ? invitationActions : actions,
            when: n.when.millisecondsSinceEpoch,
            color: Color(account.colorValue),
            // Meeting mail has a calendar on the account's colour, as a
            // reminder has; the rest the app's dart.
            largeIcon:
                await _badgeFor(account.colorValue, calendar: n.meeting),
            // The subject and preview are two lines and will be cut off
            // otherwise; expanding the notification should show the whole
            // thing, which is often the entire message.
            styleInformation: BigTextStyleInformation(
              n.body,
              contentTitle: n.title,
              // The account by the name it has in the app, on the line
              // under the sender: an address was cut short there.
              summaryText: account.displayName,
            ),
          ),
        ),
      );
    }

    // The summary carries no payload: tapping it opens the app, and which
    // message to show would be a guess.
    await _plugin.show(
      id: _summaryId(account.id),
      title: account.displayName,
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
          // Android draws the group's header itself, with the app's own icon
          // and name and nothing of the summary but this: the one place the
          // header names the account, as Outlook's names its mailbox.
          subText: account.displayName,
          styleInformation: InboxStyleInformation(
            [for (final n in notifications) '${n.title}  ${_firstLine(n.body)}'],
            contentTitle: account.displayName,
          ),
        ),
      ),
    );
  }

  static String _summaryLine(int count, String folderName) =>
      count == 1 ? '1 new message in $folderName' : '$count new messages in $folderName';

  static String _firstLine(String body) => body.split('\n').first;

  /// New mail's rows and their summaries, and only those. The plugin's own
  /// cancelAll also took back every reminder still to go off, and Follow
  /// Up's are set only as they are asked for, so they never came back; and
  /// it took down a reply that could not be sent, with what was typed.
  @override
  Future<void> cancelAll() => withdraw((_) => true);

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
      final gone = <String>{};
      for (final n in await _active()) {
        if (!_isMessage(n) || !which(n.tag!)) continue;
        await _plugin.cancel(id: n.id!, tag: n.tag);
        gone.add(n.tag!);
      }
      // Android leaves a summary up when the last thing under it goes,
      // saying "2 new messages" over nothing. Worked out from what is
      // showing rather than from what this call took down, so a summary a
      // notification's own button left behind goes too.
      await dropEmptySummaries(gone: gone);
    } catch (e) {
      debugPrint('[myemail] could not take notifications down: $e');
    }
  }

  /// Without [ensureReady]: listing and cancelling need no set-up, and this
  /// runs in the isolate Android starts for a button, where setting the
  /// plugin up again is not wanted.
  @override
  Future<void> dropEmptySummaries({Set<String> gone = const {}}) async {
    try {
      final active = await _active();
      final occupied = {
        for (final n in active)
          if (_isMessage(n) && !gone.contains(n.tag)) n.groupKey,
      };
      for (final n in active) {
        final group = n.groupKey;
        if (n.tag != null || n.id == null || group == null) continue;
        if (!group.startsWith(_groupPrefix) || occupied.contains(group)) {
          continue;
        }
        if (n.id != _summaryId(group.substring(_groupPrefix.length))) continue;
        // Looked at as late as it can be: new mail going up under it now
        // would go down with it.
        if (await _postingNow(group)) continue;
        await _plugin.cancel(id: n.id!);
      }
    } catch (e) {
      debugPrint('[myemail] could not take an empty summary down: $e');
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
