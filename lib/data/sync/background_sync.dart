import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/account.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/calendar_prefs.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/meeting_reply_filing.dart';
import '../../domain/message_move.dart' show PartialMove;
import '../../domain/sync_prefs.dart';
import '../notifications/mail_notifier.dart';
import '../mail_engine.dart';
import '../ui_state_store.dart';
import 'new_mail_scan.dart';
import 'sync_state_store.dart';

/// One background pass: sync the inboxes, announce what is genuinely new.
///
/// Written against [MailEngine] rather than against the IMAP layer, because
/// `loadMessages` already syncs the folder and then returns what the cache
/// holds. That means the pass gets the real sync, including the UIDVALIDITY
/// and CONDSTORE handling, without a second code path that could drift from
/// the one the UI uses — and it means this whole class can be tested against
/// the sample engine and a fake transport.
///
/// Only the Inbox is watched. Mail filed into a folder by a server-side rule
/// was, by the user's own instruction, not urgent; announcing it is how a mail
/// client becomes something you turn off.
class BackgroundSync {
  BackgroundSync({
    required this.engine,
    required this.notifier,
    required this.state,
    this.scanWindow = 30,
    this.maxPerFolder = 5,
    this.maxShownPerAccount = 8,
    this.inMeeting,
    this.replyFiling,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final MailNotifier notifier;
  final SyncStateStore state;

  /// Whether you are in a meeting at a time, from what the device kept of
  /// the calendars (`inMeetingFromKept`): new mail to an account quiet in
  /// meetings is posted silently in one (calendar idea #70). Asked once a
  /// pass, and only where an account is quiet in meetings. Null: never in
  /// one.
  final Future<bool> Function(DateTime now)? inMeeting;

  /// Settings, Calendar's choice for replies to your meetings (calendar
  /// idea #52), read once a pass: see [replyFilingIn]. Null: off.
  final ReplyFiling Function()? replyFiling;

  /// How many of the newest messages one pass looks at. Larger than any
  /// plausible fifteen minutes of mail, small enough to be cheap on a phone
  /// that has just woken up.
  final int scanWindow;

  /// The most notifications one folder will post in one pass. A mailing-list
  /// digest arriving at 3am should not produce forty rows.
  final int maxPerFolder;

  /// The most rows of one account's mail left showing; past it the oldest
  /// come down as new ones go up. A row comes down by itself only as its
  /// mail is dealt with, and Android shows an app 50 notifications at most
  /// and refuses the rest without a word: new mail, and the report of a
  /// reply that could not be sent. Unread newsletters left in the shade for
  /// days got there. Eight for each of five accounts, with a summary each
  /// and push mode's own, leaves room for those reports.
  final int maxShownPerAccount;

  final DateTime Function() _clock;

  /// Returns how many notifications were posted. Never throws: this runs where
  /// nobody is watching, and a thrown exception is a pass that stops silently
  /// part-way through, leaving some accounts synced and others not.
  ///
  /// [only] narrows it to some accounts, and [listFolders] false takes each
  /// account's folders as last saved rather than asking its server, where
  /// any were saved: push's minute-by-minute pass (see `PushPassPlan`).
  Future<BackgroundSyncReport> run({
    bool Function(Account account)? only,
    bool listFolders = true,
  }) async {
    final prefs = await state.readPrefs();
    if (!prefs.syncs) return const BackgroundSyncReport();
    // Changes made while a server was out of reach, sent before the sync,
    // so that what it reads is the mail as the person left it. Never
    // throws; see KeepsChangesForLater.
    if (engine case final KeepsChangesForLater keeps) {
      await keeps.sendWaitingChanges();
    }
    // Snoozed mail whose time has come, back in its folder first, and
    // announced: see [announceWoken]. Neither throws; see
    // MailEngine.wakeSnoozed.
    final announced = await announceWoken(
      await wakeSnoozedMail(engine),
      prefs: prefs,
    );

    final List<Account> accounts;
    try {
      accounts = [
        for (final a in await engine.loadAccounts())
          if (only == null || only(a)) a,
      ];
    } catch (e) {
      return BackgroundSyncReport(
        posted: announced,
        failures: ['accounts: $e'],
      );
    }

    var posted = announced;
    var scanned = 0;
    var unreachable = 0;
    final failures = <String>[];
    final synced = <String>{};
    final meetingMail = <String>{};
    final inMeetingNow = await _meetingOn(prefs, _clock());
    final filing = _replyFiling();

    for (final account in accounts) {
      try {
        // Every account is synced. Only some are announced: an account that
        // is muted, or notifications switched off entirely, still wants its
        // mail on the device and ready when the app is opened. That is the
        // whole reason these are two settings and not one.
        final announce = prefs.notifiesFor(account.id) &&
            !prefs.quietFor(account.id, _clock());
        final result = await _runAccount(
          account,
          announce: announce,
          // Quiet in a meeting posts silently; quiet by the clock, which
          // leaves it unannounced, wins.
          silently: announce &&
              inMeetingNow &&
              prefs.quietInMeetings(account.id),
          listFolders: listFolders,
          synced: synced,
          meetingMail: meetingMail,
          prefs: prefs,
          filing: filing,
        );
        posted += result.posted;
        scanned += result.scanned;
      } catch (e) {
        // One unreachable account must not stop the others: a stale app
        // password on a second mailbox would otherwise silence the first.
        failures.add('${account.emailAddress}: $e');
        if (e is ConnectionFailed) unreachable++;
      }
    }

    return BackgroundSyncReport(
      posted: posted,
      foldersScanned: scanned,
      failures: failures,
      accounts: accounts.length,
      unreachable: unreachable,
      synced: synced,
      meetingMail: meetingMail,
    );
  }

  /// [woken], snoozed mail just brought back ([wakeSnoozedMail]),
  /// announced: being told again is what a snooze is for. Answers how many
  /// were posted. Never throws.
  ///
  /// Under each account's own settings, notifications on, not muted, not
  /// in its quiet hours, the sender one it announces, but not the rules of
  /// the scan for new mail. A message comes back keeping its date, and the
  /// scan leaves anything over two days old, or outside the newest thirty,
  /// unsaid: one snoozed from Monday to Thursday came back without a word.
  /// Wherever it came back to, not only an Inbox: the snooze asked for it.
  ///
  /// Once, said or not, as new mail is: each is written down first, for
  /// the scan to leave out ([toldBackFor]). It comes back with a number
  /// above its folder's mark, and for Later today or Tomorrow it is dated
  /// within the scan's reach, so a pass after the wake job took it for new
  /// and announced it again once it had been swiped away. The mark is not
  /// moved past it: new mail numbered below it, not yet scanned, would be
  /// passed over.
  Future<int> announceWoken(List<String> woken, {SyncPrefs? prefs}) async {
    if (woken.isEmpty) return 0;
    var posted = 0;
    try {
      final rules = prefs ?? await state.readPrefs();
      final now = _clock();
      final inMeetingNow = await _meetingOn(rules, now);
      final accounts = {
        for (final a in await engine.loadAccounts()) a.id: a,
      };
      final byFolder = <String, List<MailMessage>>{};
      for (final id in woken) {
        final message = await engine.cachedMessage(id);
        if (message == null || message.isRead) continue;
        (byFolder[message.folderId] ??= []).add(message);
      }
      final told = await _toldBack();
      await state.writeToldBack({
        ...told,
        for (final messages in byFolder.values)
          for (final m in messages) m.id: now,
      });
      for (final MapEntry(key: folderId, value: messages)
          in byFolder.entries) {
        final account = accounts[messages.first.accountId];
        if (account == null ||
            !rules.notifiesFor(account.id) ||
            rules.quietFor(account.id, now)) {
          continue;
        }
        final folder = [
          for (final f in await engine.cachedFolders(account.id))
            if (f.id == folderId) f,
        ].firstOrNull;
        final said = [
          for (final m in messages)
            if (rules.announcesFrom(account.id, m.from.email)) m,
        ];
        if (folder == null || said.isEmpty) continue;
        final silently = inMeetingNow && rules.quietInMeetings(account.id);
        final batch = [
          for (final m in said.take(maxPerFolder))
            MailNotification.forMessage(
              m,
              invitation: (await _invite(m))?.isRequest ?? false,
              silent: silently,
            ),
        ];
        await _makeRoom(account, batch);
        await notifier.showNewMail(
          account: account,
          folder: folder,
          notifications: batch,
        );
        posted += batch.length;
      }
    } catch (e) {
      debugPrint('[myemail] snoozed mail back, not announced: $e');
    }
    return posted;
  }

  Future<({int posted, int scanned})> _runAccount(
    Account account, {
    required bool announce,
    required bool listFolders,
    required Set<String> synced,
    required Set<String> meetingMail,
    bool silently = false,
    SyncPrefs prefs = const SyncPrefs(),
    ReplyFiling filing = ReplyFiling.off,
  }) async {
    final saved =
        listFolders ? const <MailFolder>[] : await engine.cachedFolders(account.id);
    final folders =
        saved.isNotEmpty ? saved : await engine.loadFolders(account.id);
    // The Inboxes, and any folder chosen to be announced as well.
    final watched = [
      for (final f in folders)
        if (f.role == FolderRole.inbox || prefs.watchedFolderIds.contains(f.id))
          f,
    ];
    // Where replies to the account's meetings are filed (#52): its Deleted
    // Items, where it has one. An account with none would delete them for
    // good, so they stay.
    final deletedItems = filing == ReplyFiling.off
        ? null
        : folders.where((f) => f.role == FolderRole.deleted).firstOrNull;

    var posted = 0;
    for (final folder in watched) {
      posted += await _runFolder(
        account,
        folder,
        announce: announce,
        silently: silently,
        meetingMail: meetingMail,
        keep: (m) => prefs.announcesFrom(account.id, m.from.email),
        filing: folder.role == FolderRole.inbox && deletedItems != null
            ? (to: deletedItems, as: filing)
            : null,
      );
      synced.add(folder.id);
    }
    return (posted: posted, scanned: watched.length);
  }

  /// [meetingMail] has [account] added where the folder has new meeting
  /// mail that may have changed its calendar: see
  /// [BackgroundSyncReport.meetingMail]. What is announced is posted
  /// without a sound where [silently]: see [QuietRule.meetings]. Replies
  /// to the account's meetings go to [filing]'s folder as Settings,
  /// Calendar says, where it is given: see [_fileReplies].
  Future<int> _runFolder(
    Account account,
    MailFolder folder, {
    required bool announce,
    required Set<String> meetingMail,
    bool silently = false,
    bool Function(MailMessage message)? keep,
    ({MailFolder to, ReplyFiling as})? filing,
  }) async {
    final messages = await engine.loadMessages(folder.id, limit: scanWindow);
    await _withdrawDealtWith(folder, messages);
    final watermark = await state.readWatermark(folder.id);

    final found = selectNotifiable(
      messages: messages,
      watermark: watermark,
      now: _clock(),
    );
    final fresh = [
      for (final m in found)
        if (keep == null || keep(m)) m,
    ];
    // Meeting mail new here, whoever it is from: a VIP or not, its meeting
    // is on the calendar all the same.
    final meetings = [
      for (final m in found)
        if (m.isMeeting) m,
    ];
    // Not snoozed mail announced as it came back (see announceWoken): one
    // dated within reach is new here too.
    if (fresh.isNotEmpty || meetings.isNotEmpty) {
      final told = await _toldBack();
      fresh.removeWhere((m) => told.containsKey(m.id));
      meetings.removeWhere((m) => told.containsKey(m.id));
    }

    // The mark moves whether or not anything was announced, and before the
    // notifier is touched. A notifier that throws must not leave the folder
    // ready to announce the same mail again on the next pass.
    final next = nextWatermark(messages: messages, watermark: watermark);
    if (next != null && next != watermark) {
      await state.writeWatermark(folder.id, next);
    }

    // The bodies of the meeting mail read here, by message id: read once,
    // whether to file it or to announce it.
    final bodies = <String, MailBody?>{};
    // After the mark: filing reads and moves, and nothing it does may leave
    // the folder ready to announce the same mail again.
    if (filing != null && meetings.isNotEmpty) {
      final filed = await _fileReplies(
        account,
        meetings,
        to: filing.to,
        filing: filing.as,
        bodies: bodies,
      );
      fresh.removeWhere((m) => filed.contains(m.id));
      meetings.removeWhere((m) => filed.contains(m.id));
    }

    // Counts and the folder's own name, nothing from any message: enough to
    // tell "nothing new" from "new but already read" from "muted" when a
    // notification that was expected does not arrive.
    debugPrint(
      '[myemail] pass ${folder.displayName} · ${account.displayName}: '
      '${messages.length} in window, ${messages.where((m) => !m.isRead).length} '
      'unread, mark $watermark→$next, ${fresh.length} to announce, '
      'announce=$announce',
    );

    // The mark moved either way, so turning notifications on later announces
    // what arrives next rather than everything that arrived while they were
    // off. A backlog of forty is not a welcome.
    if (!announce || fresh.isEmpty) {
      // Not opened to see what it is: that would be asking its server for
      // more than the pass did before. It may be an answer, and its
      // calendar is read all the same.
      if (meetings.isNotEmpty) meetingMail.add(account.id);
      return 0;
    }

    // What the meeting mail announced turned out to be, by message id: the
    // calendar part read to know an invitation tells the rest too.
    final kinds = <String, CalendarInvite?>{};
    final batch = <MailNotification>[];
    for (final m in fresh.take(maxPerFolder)) {
      final invite = await _invite(m, bodies: bodies);
      if (m.isMeeting) kinds[m.id] = invite;
      batch.add(MailNotification.forMessage(
        m,
        invitation: invite?.isRequest ?? false,
        silent: silently,
      ));
    }
    // Before anything is posted, which may throw: the calendar is read
    // whether or not the notifications go up.
    if (meetings.any((m) =>
        !kinds.containsKey(m.id) || mayChangeCalendar(kinds[m.id]))) {
      meetingMail.add(account.id);
    }
    await _makeRoom(account, batch);
    await notifier.showNewMail(
      account: account,
      folder: folder,
      notifications: batch,
    );
    return batch.length;
  }

  /// [replyFiling] asked, or off where it is not given or cannot say.
  ReplyFiling _replyFiling() {
    try {
      return replyFiling?.call() ?? ReplyFiling.off;
    } catch (e) {
      debugPrint('[myemail] could not tell how replies are filed: $e');
      return ReplyFiling.off;
    }
  }

  /// Whether you are in a meeting at [now], for the accounts quiet in one:
  /// asked of [inMeeting] only where an account in [prefs] is, so a pass
  /// for anyone else reads nothing more than it did. False where it
  /// cannot be told.
  Future<bool> _meetingOn(SyncPrefs prefs, DateTime now) async {
    final asks = inMeeting;
    if (asks == null || !prefs.quiet.values.any((r) => r.meetings)) {
      return false;
    }
    try {
      return await asks(now);
    } catch (e) {
      debugPrint('[myemail] could not tell whether a meeting is on: $e');
      return false;
    }
  }

  /// How long snoozed mail announced as it came back is kept from the scan
  /// for new mail: the two days it announces mail for ([defaultMaxAge]),
  /// and one more for a sender's clock.
  static const toldBackFor = Duration(days: 3);

  /// The snoozed mail announced as it came back within [toldBackFor], or
  /// none where that cannot be read.
  Future<Map<String, DateTime>> _toldBack() async {
    final since = _clock().subtract(toldBackFor);
    try {
      return {
        for (final MapEntry(:key, :value)
            in (await state.readToldBack()).entries)
          if (value.isAfter(since)) key: value,
      };
    } catch (e) {
      debugPrint('[myemail] could not read the snoozed mail announced: $e');
      return {};
    }
  }

  /// How long a pass waits for an invitation's body before announcing it
  /// as mail like any other.
  static const invitationReadFor = Duration(seconds: 15);

  /// [message]'s calendar part, where it is meeting mail being announced:
  /// a request is an invitation to answer, so its notification has Accept
  /// and Decline, not a cancellation or someone's answer. The header
  /// cannot say which, so the body is read, and kept, which also opens it
  /// sooner. Null for other mail, and where it cannot be told.
  Future<CalendarInvite?> _invite(
    MailMessage message, {
    Map<String, MailBody?>? bodies,
  }) async {
    if (!message.isMeeting) return null;
    if (bodies != null && bodies.containsKey(message.id)) {
      final body = bodies[message.id];
      return body == null ? null : CalendarInvite.parse(body.calendar ?? '');
    }
    try {
      final body =
          await engine.loadMessageBody(message.id).timeout(invitationReadFor);
      return CalendarInvite.parse(body.calendar ?? '');
    } catch (e) {
      debugPrint('[myemail] could not tell whether an invitation: $e');
      return null;
    }
  }

  /// The most meeting mail one folder's pass opens to see whether it is a
  /// reply to file: each is a request or two to its server, and one that
  /// does not answer holds the pass for [invitationReadFor]. Any past it
  /// stay, and are announced as they would be.
  static const repliesReadAtMost = 10;

  /// Replies to [account]'s meetings among [meetings], new in its Inbox,
  /// with nothing written in them, moved into [to], its Deleted Items, as
  /// [filing] says (calendar idea #52); answers the ids of those that went,
  /// which are not announced. The rest stay where they are, and are
  /// announced as any mail is. See [whyReplyStays] for which go. Each body
  /// read is kept in [bodies], so one announced is not read twice.
  ///
  /// Moved rather than deleted, so that a folder taken for Deleted Items
  /// could never mean a delete for good, and left unread there, as each
  /// arrived. There is no Undo, as nobody pressed anything: each is in
  /// Deleted Items, from where Move puts it back. Never throws: one that
  /// could not be read or moved stays in the Inbox.
  Future<Set<String>> _fileReplies(
    Account account,
    List<MailMessage> meetings, {
    required MailFolder to,
    required ReplyFiling filing,
    required Map<String, MailBody?> bodies,
  }) async {
    final going = <String>[];
    // Why each that stays stays, counted, for the log: nothing of the
    // messages themselves.
    final kept = <String, int>{};
    var filed = const <String>{};
    try {
      for (final m in meetings.take(repliesReadAtMost)) {
        MailBody? body;
        try {
          body =
              await engine.loadMessageBody(m.id).timeout(invitationReadFor);
        } catch (e) {
          debugPrint('[myemail] could not read meeting mail: $e');
        }
        bodies[m.id] = body;
        final why = body == null
            ? 'not read'
            : whyReplyStays(m, body,
                filing: filing, ownAddress: account.emailAddress);
        if (why == null) {
          going.add(m.id);
        } else {
          kept[why] = (kept[why] ?? 0) + 1;
        }
      }
      if (meetings.length > repliesReadAtMost) {
        kept['not read, too many'] = meetings.length - repliesReadAtMost;
      }
      if (going.isNotEmpty) {
        await engine.moveMessages(going, to.id);
        filed = going.toSet();
      }
    } on PartialMove catch (part) {
      filed = {
        for (final id in part.moved)
          if (going.contains(id)) id,
      };
    } catch (e) {
      debugPrint('[myemail] replies to meetings not filed: $e');
    }
    if (going.isNotEmpty || kept.isNotEmpty) {
      final said = [
        for (final MapEntry(:key, :value) in kept.entries) '$value $key',
      ];
      debugPrint('[myemail] replies to meetings · ${account.displayName}: '
          '${filed.length} of ${going.length} to Deleted Items; kept '
          '${said.isEmpty ? 'none' : said.join(', ')}');
    }
    return filed;
  }

  /// Take down the oldest of [account]'s rows that [batch] would put over
  /// [maxShownPerAccount], before it goes up: posted first, it could be
  /// what Android refuses. Oldest by the message's date, and one the cache
  /// no longer has before any.
  Future<void> _makeRoom(
    Account account,
    List<MailNotification> batch,
  ) async {
    try {
      final coming = {for (final n in batch) n.payload};
      // Every message id starts with its folder's, which starts with the
      // account's (MailFolder.idFor).
      final own = MailFolder.idFor(account.id, '');
      final shown = [
        for (final id in await notifier.shownMessageIds())
          if (id.startsWith(own) && !coming.contains(id)) id,
      ];
      final over = shown.length + coming.length - maxShownPerAccount;
      if (over <= 0) return;
      final dated = [
        for (final id in shown)
          (id: id, date: (await engine.cachedMessage(id))?.date),
      ];
      final never = DateTime.fromMillisecondsSinceEpoch(0);
      dated.sort((a, b) => (a.date ?? never).compareTo(b.date ?? never));
      final oldest = {for (final d in dated.take(over)) d.id};
      await notifier.withdraw(oldest.contains);
    } catch (e) {
      // Posted all the same: a row too many is better than new mail unsaid.
      debugPrint('[myemail] could not make room for new mail: $e');
    }
  }

  /// Take down the notifications of mail in [folder] that has been read, or
  /// has gone, since it was announced: dealt with on another device, say,
  /// or in the app while this worker was not the one doing it. Left up,
  /// their buttons act on mail that is no longer there.
  ///
  /// [window] is the folder as just synced. A notified message outside it
  /// is looked up in the cache, where a sync has already dropped anything
  /// deleted or moved away.
  Future<void> _withdrawDealtWith(
    MailFolder folder,
    List<MailMessage> window,
  ) async {
    try {
      final byId = {for (final m in window) m.id: m};
      final dealtWith = <String>{};
      for (final id in await notifier.shownMessageIds()) {
        if (id.lastIndexOf('#') < 0 ||
            id.substring(0, id.lastIndexOf('#')) != folder.id) {
          continue;
        }
        final message = byId[id] ?? await engine.cachedMessage(id);
        if (message == null || message.isRead) dealtWith.add(id);
      }
      if (dealtWith.isNotEmpty) await notifier.withdraw(dealtWith.contains);
    } catch (e) {
      debugPrint('[myemail] could not tidy notifications: $e');
    }
  }
}

/// Whether meeting mail whose calendar part is [invite] may have changed
/// the calendar it is about: an invitation, a change to one or a
/// cancellation. Not someone's answer, which changes only who has said yes,
/// nor a new time proposed or turned down, which changes nothing until the
/// organiser moves the meeting. A part that could not be read may be any
/// of them, and counts.
bool mayChangeCalendar(CalendarInvite? invite) =>
    invite == null ||
    !(invite.isReply || invite.isCounter || invite.isDeclineCounter);

/// What Settings, Calendar says of replies to your meetings, read from
/// where the app keeps it, for a pass in an isolate of its own. Off where
/// it cannot be read.
ReplyFiling replyFilingIn(UiStateStore uiState) {
  try {
    return (CalendarPrefs.tryParse(
              uiState.readString(UiStateKeys.calendarPrefs) ?? '',
            ) ??
            const CalendarPrefs())
        .replyFiling;
  } catch (e) {
    debugPrint('[myemail] could not read how replies are filed: $e');
    return ReplyFiling.off;
  }
}

/// [MailEngine.wakeSnoozed], answering the ids of the messages brought
/// back where the engine can say them ([SaysWhatWoke]). Never throws.
Future<List<String>> wakeSnoozedMail(MailEngine engine) async {
  if (engine case final SaysWhatWoke says) return says.wakeSnoozedMail();
  await engine.wakeSnoozed();
  return const [];
}

/// What one pass did, for the logs and for the tests.
class BackgroundSyncReport {
  const BackgroundSyncReport({
    this.posted = 0,
    this.foldersScanned = 0,
    this.failures = const [],
    this.accounts = 0,
    this.unreachable = 0,
    this.synced = const {},
    this.meetingMail = const {},
  });

  final int posted;
  final int foldersScanned;
  final List<String> failures;

  /// How many accounts the pass tried, and how many of those it could not
  /// reach at all.
  final int accounts;
  final int unreachable;

  /// The folders the pass synced, whose mail is now in the cache: see
  /// `MailboxWidgets.refresh`.
  final Set<String> synced;

  /// The accounts the pass found new meeting mail in that may have changed
  /// their calendars (see [mayChangeCalendar]): an invitation, a change or
  /// a cancellation, by what was read to announce it, and any not
  /// announced, which is not opened to see. Each is read again in the same
  /// pass, so the reminders, the widget and the morning agenda have the
  /// new times: see `keepCalendarAfterPass` (calendar idea #74).
  final Set<String> meetingMail;

  bool get ok => failures.isEmpty;

  /// Whether trying again soon could go better: every account failed, and
  /// at least one only for want of a connection.
  ///
  /// Not merely "something failed". WorkManager answers a failed pass with
  /// an exponential backoff, and one account whose sign-in had lapsed
  /// failed every pass, so "Occasionally" soon ran every five hours for
  /// the healthy accounts too. Retrying cannot fix a sign-in.
  bool get worthRetrying =>
      accounts > 0 && failures.length >= accounts && unreachable > 0;

  @override
  String toString() => 'BackgroundSyncReport(posted: $posted, '
      'folders: $foldersScanned, failures: ${failures.length})';
}
