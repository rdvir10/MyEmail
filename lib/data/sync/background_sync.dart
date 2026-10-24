import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/account.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/sync_prefs.dart';
import '../notifications/mail_notifier.dart';
import '../mail_engine.dart';
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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final MailNotifier notifier;
  final SyncStateStore state;

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
    // Snoozed mail whose time has come, back in its folder first. Never
    // throws; see MailEngine.wakeSnoozed.
    await engine.wakeSnoozed();

    final List<Account> accounts;
    try {
      accounts = [
        for (final a in await engine.loadAccounts())
          if (only == null || only(a)) a,
      ];
    } catch (e) {
      return BackgroundSyncReport(failures: ['accounts: $e']);
    }

    var posted = 0;
    var scanned = 0;
    var unreachable = 0;
    final failures = <String>[];
    final synced = <String>{};

    for (final account in accounts) {
      try {
        // Every account is synced. Only some are announced: an account that
        // is muted, or notifications switched off entirely, still wants its
        // mail on the device and ready when the app is opened. That is the
        // whole reason these are two settings and not one.
        final result = await _runAccount(
          account,
          announce: prefs.notifiesFor(account.id) &&
              !prefs.quietFor(account.id, _clock()),
          listFolders: listFolders,
          synced: synced,
          prefs: prefs,
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
    );
  }

  Future<({int posted, int scanned})> _runAccount(
    Account account, {
    required bool announce,
    required bool listFolders,
    required Set<String> synced,
    SyncPrefs prefs = const SyncPrefs(),
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

    var posted = 0;
    for (final folder in watched) {
      posted += await _runFolder(
        account,
        folder,
        announce: announce,
        keep: (m) => prefs.announcesFrom(account.id, m.from.email),
      );
      synced.add(folder.id);
    }
    return (posted: posted, scanned: watched.length);
  }

  Future<int> _runFolder(
    Account account,
    MailFolder folder, {
    required bool announce,
    bool Function(MailMessage message)? keep,
  }) async {
    final messages = await engine.loadMessages(folder.id, limit: scanWindow);
    await _withdrawDealtWith(folder, messages);
    final watermark = await state.readWatermark(folder.id);

    final fresh = [
      for (final m in selectNotifiable(
        messages: messages,
        watermark: watermark,
        now: _clock(),
      ))
        if (keep == null || keep(m)) m,
    ];

    // The mark moves whether or not anything was announced, and before the
    // notifier is touched. A notifier that throws must not leave the folder
    // ready to announce the same mail again on the next pass.
    final next = nextWatermark(messages: messages, watermark: watermark);
    if (next != null && next != watermark) {
      await state.writeWatermark(folder.id, next);
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
    if (!announce || fresh.isEmpty) return 0;

    final batch = [
      for (final m in fresh.take(maxPerFolder)) MailNotification.forMessage(m),
    ];
    await _makeRoom(account, batch);
    await notifier.showNewMail(
      account: account,
      folder: folder,
      notifications: batch,
    );
    return batch.length;
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

/// What one pass did, for the logs and for the tests.
class BackgroundSyncReport {
  const BackgroundSyncReport({
    this.posted = 0,
    this.foldersScanned = 0,
    this.failures = const [],
    this.accounts = 0,
    this.unreachable = 0,
    this.synced = const {},
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
