import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/account.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/mailbox_counts.dart';
import '../../state/folder_tree.dart' show kUnifiedInboxId;
import '../mail_engine.dart';
import 'home_screen_surface.dart';
import 'widget_state_store.dart';

/// Keeping the home-screen widgets in step with the mailboxes they show.
///
/// The awkward part of a home-screen widget is that nothing about it happens
/// where the app is. Android draws it from a handful of values in shared
/// preferences, whether or not the app is running, so everything the widget
/// will ever say has to be written down in advance — by the app when it is
/// open, and by the background sync pass when it is not.
///
/// So this is called from three places, and each one matters:
///  * the app, as a mailbox is looked at and as its counts move;
///  * the end of a sync, which is when the numbers have actually changed;
///  * setting a widget up, which is when it first has a mailbox to count.
class MailboxWidgets {
  MailboxWidgets({required this.surface, required this.store});

  final HomeScreenSurface surface;
  final WidgetStateStore store;

  /// How far back to look for messages that arrived since the mark.
  ///
  /// A window, not the whole folder: counting is a widget showing a number,
  /// not a reason to read four thousand rows out of the cache every fifteen
  /// minutes. Someone who has had two hundred messages since they last opened
  /// the app is well served by being told "200".
  static const window = 200;

  /// Remember what a widget shows, and fill it in.
  ///
  /// Used both for a newly placed widget and for one being changed from the
  /// settings screen: they are the same operation.
  Future<void> setUp({
    required String appWidgetId,
    required WidgetMailbox mailbox,
    required MailEngine engine,
  }) async {
    await store.writeMailbox(appWidgetId, mailbox);
    await refresh(engine);
  }

  /// The app has been opened. The first time with a widget placed is where
  /// "new" starts for a mailbox that has not been looked at since; after
  /// that each mailbox counts from its own last look, see [seen].
  Future<void> opened(DateTime now) async {
    if (await store.readOpenedAt() == null) await store.writeOpenedAt(now);
  }

  /// [folderId] has been on screen up to [now], so its widget's "new"
  /// starts again from here. For All inboxes, so does every Inbox's; for an
  /// Inbox, its share of All inboxes.
  ///
  /// The mark only. The app redraws once it has written it, see [refresh].
  Future<void> seen(String folderId, DateTime now) =>
      store.writeSeen(folderId, now);

  /// Recount and redraw.
  ///
  /// Does nothing at all when no widget has been placed, which is the common
  /// case and worth keeping cheap: this runs at the end of every sync pass.
  ///
  /// [placed] is the widgets Android says are on the home screen. Where it is
  /// known, anything else is forgotten — a widget dragged to the bin leaves
  /// its mailbox behind otherwise, and every sync goes on counting a folder
  /// nothing is showing. Null means "not known here", which is the case in
  /// the background isolate, and nothing is forgotten.
  ///
  /// [fromCache] counts from what is already stored, with no network at all.
  ///
  /// [synced] is given after a sync pass: the folders it synced. The pass
  /// has just listed the folders, or took them as saved, and synced those
  /// folders' mail into the cache, so the counts are taken as it left them
  /// and only a widget folder it did not sync is synced here. Counted from
  /// the network, every pass was done twice: push's minute check listed
  /// every widget account's folders, Gmail's included, which that check
  /// leaves to IDLE, and synced again the Inbox it had synced a moment
  /// before.
  Future<void> refresh(
    MailEngine engine, {
    List<String>? placed,
    bool fromCache = false,
    Set<String>? synced,
  }) async {
    try {
      if (placed != null) await store.keepOnly(placed);
      final mailboxes = await store.readMailboxes();
      if (mailboxes.isEmpty) return;

      final accounts = await engine.loadAccounts();
      final counted = <String, _Counted>{};
      // Could not be counted this time. One account needing a sign-in used
      // to stop every widget here, Gmail and All inboxes included, until it
      // was signed in again; now only its own widget keeps what it showed.
      final unknown = <String>{};
      for (final folderId in mailboxes.values.map((m) => m.folderId).toSet()) {
        try {
          final count = await _count(
            engine,
            accounts,
            folderId,
            fromCache: fromCache,
            synced: synced,
          );
          if (count != null) counted[folderId] = count;
        } catch (e) {
          debugPrint('[myemail] could not count $folderId for a widget: $e');
          unknown.add(folderId);
        }
      }

      // Everything for Android in one go, each value by its kind: the
      // widget reads a string or a number per key, and the platform
      // contract test holds these two to what it reads.
      final values = <String, Object?>{};
      void text(String key, String? value) => values[key] = value;
      void number(String key, int value) => values[key] = value;

      for (final entry in mailboxes.entries) {
        final mailbox = entry.value;
        final found = counted[mailbox.folderId];
        final kept = unknown.contains(mailbox.folderId);
        // A folder that has gone leaves the widget unassigned rather than
        // showing zeroes, which would read as an empty mailbox.
        text(
          'widget.${entry.key}.folder',
          found == null && !kept ? null : mailbox.folderId,
        );
        text('widget.${entry.key}.mode', mailbox.counts.name);
        text('widget.${entry.key}.label', mailbox.label);
        // Written on every pass rather than once at setup: a widget on its
        // account's colour has to follow a recolour in Settings. Signed and
        // inside 32 bits, as WidgetColour.argb explains.
        number(
          'widget.${entry.key}.colour',
          mailbox.tileColour(accounts).toSigned(32),
        );
      }
      // The marks as they are now the counting is done, not as they were
      // when it began. A background pass spends seconds syncing, and a
      // mailbox looked at in that time has gone to zero; counting against
      // the marks read before put "3 new" back for mail already read.
      final marks = SeenMarks(
        opened: await store.readOpenedAt(),
        folders: await store.readSeen(),
      );
      for (final c in counted.values) {
        final counts = c.counts(marks);
        text('count.${c.folderId}.label', counts.label);
        number('count.${c.folderId}.total', counts.total);
        number('count.${c.folderId}.unread', counts.unread);
        number('count.${c.folderId}.new', counts.fresh);
      }
      await surface.show(values);
    } catch (e, stack) {
      // A widget that is briefly out of date is a far smaller thing than a
      // sync pass that fails, or an app that will not open, because a folder
      // it counts has gone.
      debugPrint('[myemail] could not update the home-screen widgets: $e');
      debugPrint('$stack');
    }
  }

  /// One mailbox's numbers, and the recent messages "new" is counted from
  /// once the marks are known.
  Future<_Counted?> _count(
    MailEngine engine,
    List<Account> accounts,
    String folderId, {
    required bool fromCache,
    required Set<String>? synced,
  }) async {
    Future<List<MailFolder>> folders(String accountId) async {
      if (fromCache) return engine.cachedFolders(accountId);
      if (synced == null) return engine.loadFolders(accountId);
      // As the pass left them, unless it never got as far as saving any.
      final saved = await engine.cachedFolders(accountId);
      return saved.isNotEmpty ? saved : engine.loadFolders(accountId);
    }

    Future<List<MailMessage>> messages(String folderId) =>
        fromCache || (synced?.contains(folderId) ?? false)
            ? engine.cachedMessages(folderId, limit: window)
            : engine.loadMessages(folderId, limit: window);

    if (folderId == kUnifiedInboxId) {
      var total = 0;
      var unread = 0;
      final recent = <_Recent>[];
      for (final account in accounts) {
        // An account that cannot be asked counts as it was last seen,
        // rather than taking All inboxes down with it.
        List<MailFolder> inboxes;
        try {
          inboxes = await folders(account.id);
        } catch (_) {
          inboxes = await engine.cachedFolders(account.id);
        }
        for (final folder in inboxes) {
          if (folder.role != FolderRole.inbox) continue;
          total += folder.totalCount;
          unread += folder.unreadCount;
          List<MailMessage> mail;
          try {
            mail = await messages(folder.id);
          } catch (_) {
            mail = await engine.cachedMessages(folder.id, limit: window);
          }
          recent.add((folderId: folder.id, inbox: true, messages: mail));
        }
      }
      return _Counted(
        folderId: folderId,
        label: 'All inboxes',
        total: total,
        unread: unread,
        recent: recent,
      );
    }

    // A folder id is `<accountId>:<path>`, and a path may hold colons of its
    // own, so the first one is the split.
    final accountId = folderId.split(':').first;
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) return null;
    final folder = (await folders(accountId))
        .where((f) => f.id == folderId)
        .firstOrNull;
    // Deleted, renamed, or the account removed.
    if (folder == null) return null;

    return _Counted(
      folderId: folderId,
      label: '${folder.displayName} · ${account.displayName}',
      total: folder.totalCount,
      unread: folder.unreadCount,
      recent: [
        (
          folderId: folderId,
          inbox: folder.role == FolderRole.inbox,
          messages: await messages(folderId),
        ),
      ],
    );
  }
}

/// One folder's recent mail, and whether it is an Inbox, which decides
/// whether a look at All inboxes covers it.
typedef _Recent = ({String folderId, bool inbox, List<MailMessage> messages});

/// A mailbox counted, all but "new", which waits for the marks.
class _Counted {
  _Counted({
    required this.folderId,
    required this.label,
    required this.total,
    required this.unread,
    required this.recent,
  });

  final String folderId;
  final String label;
  final int total;
  final int unread;

  /// One entry for a folder; one per Inbox for All inboxes, each counted
  /// from its own mark.
  final List<_Recent> recent;

  MailboxCounts counts(SeenMarks marks) => MailboxCounts(
        folderId: folderId,
        label: label,
        total: total,
        unread: unread,
        fresh: recent.fold(
          0,
          (n, r) =>
              n +
              arrivedSince(
                r.messages,
                marks.markFor(r.folderId, inbox: r.inbox),
              ),
        ),
      );
}
