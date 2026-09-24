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
///  * the app coming to the front, which moves the mark "new" counts from;
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

  /// You have just looked at your mail, so "new" starts counting from here.
  ///
  /// Called when the app comes to the front and again when it goes away, so
  /// the number means "arrived since you last had this in front of you"
  /// rather than "since you opened it this morning and read it all".
  ///
  /// The mark moves first and the numbers are written second, which is what
  /// makes the widget go to zero as you open the app rather than a sync later.
  ///
  /// [placed] is Android's answer to which widgets are on the home screen,
  /// still on its way while the mark is written; see [refresh] for it and
  /// for [fromCache], which lets the app going away redraw from what it
  /// already holds rather than sync every widget's folder on its way out.
  Future<void> markCaughtUp(
    DateTime now,
    MailEngine engine, {
    Future<List<String>?>? placed,
    bool fromCache = false,
  }) async {
    await store.writeOpenedAt(now);
    await refresh(engine, placed: await placed, fromCache: fromCache);
  }

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
  Future<void> refresh(
    MailEngine engine, {
    List<String>? placed,
    bool fromCache = false,
  }) async {
    try {
      if (placed != null) await store.keepOnly(placed);
      final mailboxes = await store.readMailboxes();
      if (mailboxes.isEmpty) return;

      final mark = await store.readOpenedAt();
      final accounts = await engine.loadAccounts();
      final counts = <String, MailboxCounts>{};
      final recent = <String, List<MailMessage>>{};
      // Could not be counted this time. One account needing a sign-in used
      // to stop every widget here, Gmail and All inboxes included, until it
      // was signed in again; now only its own widget keeps what it showed.
      final unknown = <String>{};
      for (final folderId in mailboxes.values.map((m) => m.folderId).toSet()) {
        try {
          final count =
              await _count(engine, accounts, folderId, mark, fromCache);
          if (count != null) {
            counts[folderId] = count.counts;
            recent[folderId] = count.recent;
          }
        } catch (e) {
          debugPrint('[myemail] could not count $folderId for a widget: $e');
          unknown.add(folderId);
        }
      }

      for (final entry in mailboxes.entries) {
        final mailbox = entry.value;
        final found = counts[mailbox.folderId];
        final kept = unknown.contains(mailbox.folderId);
        // A folder that has gone leaves the widget unassigned rather than
        // showing zeroes, which would read as an empty mailbox.
        await surface.putString(
          'widget.${entry.key}.folder',
          found == null && !kept ? null : mailbox.folderId,
        );
        await surface.putString('widget.${entry.key}.mode', mailbox.counts.name);
        await surface.putString('widget.${entry.key}.label', mailbox.label);
        // Written on every pass rather than once at setup: a widget on its
        // account's colour has to follow a recolour in Settings. Signed and
        // inside 32 bits, as WidgetColour.argb explains.
        await surface.putInt(
          'widget.${entry.key}.colour',
          mailbox.tileColour(accounts).toSigned(32),
        );
      }
      // The mark again, now that the counting is done. A background pass
      // spends seconds syncing, and if the app was opened and left in that
      // time the mark moved and the widget went to zero; writing what was
      // counted against the old mark put "3 new" back for mail already read.
      final markNow = await store.readOpenedAt();
      for (final c in counts.values) {
        await surface.putString('count.${c.folderId}.label', c.label);
        await surface.putInt('count.${c.folderId}.total', c.total);
        await surface.putInt('count.${c.folderId}.unread', c.unread);
        await surface.putInt(
          'count.${c.folderId}.new',
          markNow == mark
              ? c.fresh
              : arrivedSince(recent[c.folderId] ?? const [], markNow),
        );
      }
      await surface.redraw();
    } catch (e, stack) {
      // A widget that is briefly out of date is a far smaller thing than a
      // sync pass that fails, or an app that will not open, because a folder
      // it counts has gone.
      debugPrint('[myemail] could not update the home-screen widgets: $e');
      debugPrint('$stack');
    }
  }

  /// The counts for one mailbox, and the recent messages they were counted
  /// from, so "new" can be counted again against a mark that moved.
  Future<({MailboxCounts counts, List<MailMessage> recent})?> _count(
    MailEngine engine,
    List<Account> accounts,
    String folderId,
    DateTime? mark,
    bool fromCache,
  ) async {
    Future<List<MailFolder>> folders(String accountId) => fromCache
        ? engine.cachedFolders(accountId)
        : engine.loadFolders(accountId);
    Future<List<MailMessage>> messages(String folderId) => fromCache
        ? engine.cachedMessages(folderId, limit: window)
        : engine.loadMessages(folderId, limit: window);

    if (folderId == kUnifiedInboxId) {
      var total = 0;
      var unread = 0;
      final recent = <MailMessage>[];
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
          try {
            recent.addAll(await messages(folder.id));
          } catch (_) {
            recent.addAll(
                await engine.cachedMessages(folder.id, limit: window));
          }
        }
      }
      return (
        counts: MailboxCounts(
          folderId: folderId,
          label: 'All inboxes',
          total: total,
          unread: unread,
          fresh: arrivedSince(recent, mark),
        ),
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

    final recent = await messages(folderId);
    return (
      counts: MailboxCounts(
        folderId: folderId,
        label: '${folder.displayName} · ${account.displayName}',
        total: folder.totalCount,
        unread: folder.unreadCount,
        fresh: arrivedSince(recent, mark),
      ),
      recent: recent,
    );
  }
}
