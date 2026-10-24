import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_message.dart';
import 'display_providers.dart';
import 'folder_tree.dart' show kFlaggedId, kUnifiedInboxId;
import 'message_providers.dart' show inboxIdsOf;
import 'providers.dart';

/// Your own mail from Sent, for a list's conversations to take in:
/// Outlook's Show Messages from Other Folders. Empty while conversations
/// are off, and in Sent, Drafts, Deleted and Junk themselves.
///
/// Read from what the device holds, which costs a database read: the list's
/// threads are drawn from it and nothing waits on the network. Sent is
/// synced behind that now and then (see [_freshen]), since nothing else
/// syncs it unless it is opened.
final conversationExtrasProvider =
    FutureProvider.autoDispose.family<List<MailMessage>, String>(
  (ref, listId) async {
    if (!ref.watch(displayProvider.select((d) => d.conversations))) {
      return const [];
    }
    final index = ref.watch(folderIndexProvider);
    final role = index[listId]?.role;
    if (role == FolderRole.sent ||
        role == FolderRole.drafts ||
        role == FolderRole.deleted ||
        role == FolderRole.junk) {
      return const [];
    }
    // Read again whenever the lists are asked again, so a reply sent from
    // here, or synced in, joins its thread without a restart.
    ref.watch(listRefreshProvider);
    final engine = ref.watch(mailEngineProvider);
    final folders = await ref.watch(foldersProvider.future);
    final accountIds = switch (listId) {
      kUnifiedInboxId => {
          for (final id in inboxIdsOf(folders)) ?index[id]?.accountId,
        },
      kFlaggedId => folders.keys.toSet(),
      _ => {?index[listId]?.accountId},
    };
    final found = <MailMessage>[];
    for (final accountId in accountIds) {
      final sent = (folders[accountId] ?? const [])
          .where((f) => f.role == FolderRole.sent)
          .firstOrNull;
      if (sent == null) continue;
      _freshen(ref, sent.id);
      try {
        found.addAll(await engine.cachedMessages(sent.id, limit: 200));
      } catch (e) {
        debugPrint('[myemail] could not read ${sent.id} for threads: $e');
      }
    }
    return found;
  },
);

/// When each Sent folder was last synced for the threads.
final _askedAt = <String, DateTime>{};

/// How often Sent is synced for the threads at most.
const _every = Duration(minutes: 10);

/// Sync [sentId] behind the list, at most once every [_every], and read
/// the threads' mail again once it has. Quiet about failure: the threads
/// show what the device has.
void _freshen(Ref ref, String sentId) {
  final now = DateTime.now();
  final last = _askedAt[sentId];
  if (last != null && now.difference(last) < _every) return;
  _askedAt[sentId] = now;
  final engine = ref.read(mailEngineProvider);
  unawaited(engine.loadMessages(sentId, limit: 50).then(
    (_) {
      if (ref.mounted) ref.invalidateSelf();
    },
    onError: (Object e) {
      debugPrint('[myemail] could not sync $sentId for threads: $e');
    },
  ));
}
