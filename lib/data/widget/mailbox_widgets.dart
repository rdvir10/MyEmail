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
  Future<void> markCaughtUp(DateTime now, MailEngine engine) async {
    await store.writeOpenedAt(now);
    await refresh(engine);
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
  Future<void> refresh(MailEngine engine, {List<String>? placed}) async {
    try {
      if (placed != null) await store.keepOnly(placed);
      final mailboxes = await store.readMailboxes();
      if (mailboxes.isEmpty) return;

      final mark = await store.readOpenedAt();
      final accounts = await engine.loadAccounts();
      final counts = <String, MailboxCounts>{};
      // Could not be counted this time. One account needing a sign-in used
      // to stop every widget here, Gmail and All inboxes included, until it
      // was signed in again; now only its own widget keeps what it showed.
      final unknown = <String>{};
      for (final folderId in mailboxes.values.map((m) => m.folderId).toSet()) {
        try {
          final count = await _count(engine, accounts, folderId, mark);
          if (count != null) counts[folderId] = count;
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
      for (final c in counts.values) {
        await surface.putString('count.${c.folderId}.label', c.label);
        await surface.putInt('count.${c.folderId}.total', c.total);
        await surface.putInt('count.${c.folderId}.unread', c.unread);
        await surface.putInt('count.${c.folderId}.new', c.fresh);
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

  Future<MailboxCounts?> _count(
    MailEngine engine,
    List<Account> accounts,
    String folderId,
    DateTime? mark,
  ) async {
    if (folderId == kUnifiedInboxId) {
      var total = 0;
      var unread = 0;
      var fresh = 0;
      for (final account in accounts) {
        // An account that cannot be asked counts as it was last seen,
        // rather than taking All inboxes down with it.
        List<MailFolder> folders;
        try {
          folders = await engine.loadFolders(account.id);
        } catch (_) {
          folders = await engine.cachedFolders(account.id);
        }
        for (final folder in folders) {
          if (folder.role != FolderRole.inbox) continue;
          total += folder.totalCount;
          unread += folder.unreadCount;
          List<MailMessage> recent;
          try {
            recent = await engine.loadMessages(folder.id, limit: window);
          } catch (_) {
            recent = await engine.cachedMessages(folder.id, limit: window);
          }
          fresh += arrivedSince(recent, mark);
        }
      }
      return MailboxCounts(
        folderId: folderId,
        label: 'All inboxes',
        total: total,
        unread: unread,
        fresh: fresh,
      );
    }

    // A folder id is `<accountId>:<path>`, and a path may hold colons of its
    // own, so the first one is the split.
    final accountId = folderId.split(':').first;
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) return null;
    final folder = (await engine.loadFolders(accountId))
        .where((f) => f.id == folderId)
        .firstOrNull;
    // Deleted, renamed, or the account removed.
    if (folder == null) return null;

    return MailboxCounts(
      folderId: folderId,
      label: '${folder.displayName} · ${account.displayName}',
      total: folder.totalCount,
      unread: folder.unreadCount,
      fresh: arrivedSince(
        await engine.loadMessages(folderId, limit: window),
        mark,
      ),
    );
  }
}
