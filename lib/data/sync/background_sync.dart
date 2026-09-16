import '../../domain/account.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
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

  final DateTime Function() _clock;

  /// Returns how many notifications were posted. Never throws: this runs where
  /// nobody is watching, and a thrown exception is a pass that stops silently
  /// part-way through, leaving some accounts synced and others not.
  Future<BackgroundSyncReport> run() async {
    final prefs = await state.readPrefs();
    if (!prefs.syncs) return const BackgroundSyncReport();

    final List<Account> accounts;
    try {
      accounts = await engine.loadAccounts();
    } catch (e) {
      return BackgroundSyncReport(failures: ['accounts: $e']);
    }

    var posted = 0;
    var scanned = 0;
    final failures = <String>[];

    for (final account in accounts) {
      try {
        // Every account is synced. Only some are announced: an account that
        // is muted, or notifications switched off entirely, still wants its
        // mail on the device and ready when the app is opened. That is the
        // whole reason these are two settings and not one.
        final result = await _runAccount(
          account,
          announce: prefs.notifiesFor(account.id),
        );
        posted += result.posted;
        scanned += result.scanned;
      } catch (e) {
        // One unreachable account must not stop the others: a stale app
        // password on a second mailbox would otherwise silence the first.
        failures.add('${account.emailAddress}: $e');
      }
    }

    return BackgroundSyncReport(
      posted: posted,
      foldersScanned: scanned,
      failures: failures,
    );
  }

  Future<({int posted, int scanned})> _runAccount(
    Account account, {
    required bool announce,
  }) async {
    final folders = await engine.loadFolders(account.id);
    final inboxes = [
      for (final f in folders)
        if (f.role == FolderRole.inbox) f,
    ];

    var posted = 0;
    for (final folder in inboxes) {
      posted += await _runFolder(account, folder, announce: announce);
    }
    return (posted: posted, scanned: inboxes.length);
  }

  Future<int> _runFolder(
    Account account,
    MailFolder folder, {
    required bool announce,
  }) async {
    final messages = await engine.loadMessages(folder.id, limit: scanWindow);
    final watermark = await state.readWatermark(folder.id);

    final fresh = selectNotifiable(
      messages: messages,
      watermark: watermark,
      now: _clock(),
    );

    // The mark moves whether or not anything was announced, and before the
    // notifier is touched. A notifier that throws must not leave the folder
    // ready to announce the same mail again on the next pass.
    final next = nextWatermark(messages: messages, watermark: watermark);
    if (next != null && next != watermark) {
      await state.writeWatermark(folder.id, next);
    }

    // The mark moved either way, so turning notifications on later announces
    // what arrives next rather than everything that arrived while they were
    // off. A backlog of forty is not a welcome.
    if (!announce || fresh.isEmpty) return 0;

    final batch = [
      for (final m in fresh.take(maxPerFolder)) MailNotification.forMessage(m),
    ];
    await notifier.showNewMail(
      account: account,
      folder: folder,
      notifications: batch,
    );
    return batch.length;
  }
}

/// What one pass did, for the logs and for the tests.
class BackgroundSyncReport {
  const BackgroundSyncReport({
    this.posted = 0,
    this.foldersScanned = 0,
    this.failures = const [],
  });

  final int posted;
  final int foldersScanned;
  final List<String> failures;

  bool get ok => failures.isEmpty;

  @override
  String toString() => 'BackgroundSyncReport(posted: $posted, '
      'folders: $foldersScanned, failures: ${failures.length})';
}
