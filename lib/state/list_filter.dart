import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../domain/mail_message.dart';
import 'folder_tree.dart' show kFlaggedId, kUnifiedInboxId;
import 'message_keeping.dart' show notRetried;
import 'message_providers.dart' show inboxIdsOf;
import 'providers.dart';

/// The filter each list is showing, by list id: Outlook's All / Unread over
/// the list, and its Filter menu.
///
/// Not kept across restarts, and set back to All when the app is put away,
/// as a search is: coming back to an Inbox that shows only some of its
/// mail, with nothing on screen saying why, reads as mail gone missing.
class ListFilters extends Notifier<Map<String, MessageFilter>> {
  @override
  Map<String, MessageFilter> build() => const {};

  void set(String listId, MessageFilter filter) => state = {
        for (final e in state.entries)
          if (e.key != listId) e.key: e.value,
        if (filter != MessageFilter.all) listId: filter,
      };

  void clearAll() => state = const {};
}

final listFiltersProvider =
    NotifierProvider<ListFilters, Map<String, MessageFilter>>(
  ListFilters.new,
);

/// The filter on one list, All where none is set.
final listFilterProvider = Provider.family<MessageFilter, String>(
  (ref, listId) => ref.watch(listFiltersProvider)[listId] ?? MessageFilter.all,
);

/// Every account's own address, in lower case: To me, Sent only to me, and
/// whose a message is.
final ownAddressesProvider = Provider<Set<String>>((ref) => {
      for (final a in ref.watch(accountsProvider).value ?? const [])
        a.emailAddress.trim().toLowerCase(),
    });

/// Each account's place in the folder pane, for sorting by account.
final accountRankProvider = Provider<Map<String, int>>((ref) => {
      for (final (i, a)
          in (ref.watch(accountsProvider).value ?? const []).indexed)
        a.id: i,
    });

/// Each account's name as the folder pane has it, for the bars of a list
/// sorted by account.
final accountNamesProvider = Provider<Map<String, String>>((ref) => {
      for (final a in ref.watch(accountsProvider).value ?? const [])
        a.id: a.displayName,
    });

/// What the server has for a filtered list, beyond what the list holds:
/// the newest matching messages of each folder behind it, every Inbox for
/// All Inboxes.
///
/// One folder that cannot answer leaves the others' mail standing; only
/// when none can is it an error, and the list then shows the matching mail
/// it holds, as a refresh that fails does.
final filterHitsProvider = FutureProvider.autoDispose
    .family<List<MailMessage>, (String, MessageFilter)>(
  (ref, key) async {
    final (listId, filter) = key;
    if (filter == MessageFilter.all) return const [];
    final engine = ref.watch(mailEngineProvider);
    // Flagged has nothing more to find on the server than it asked for.
    if (listId == kFlaggedId) return const [];
    final ids = listId == kUnifiedInboxId
        ? inboxIdsOf(await ref.watch(foldersProvider.future))
        : [listId];
    Object? failure;
    StackTrace? trace;
    var failed = 0;
    final found = await Future.wait([
      for (final id in ids)
        engine.filterMessages(id, filter).catchError((Object e, StackTrace s) {
          failed++;
          failure ??= e;
          trace ??= s;
          debugPrint('[myemail] filter ${filter.name} on $id failed: $e');
          return const <MailMessage>[];
        }),
    ]);
    if (ids.isNotEmpty && failed == ids.length) {
      Error.throwWithStackTrace(failure!, trace!);
    }
    return [for (final list in found) ...list];
  },
  retry: notRetried,
);

/// [messages] narrowed to what [filter] keeps, with [hits] the server
/// found that [messages] does not hold. [keep] is a message to leave in
/// the list whatever it is now: the one open, so a message read under
/// Unread stays where it is until something else is opened, as Outlook
/// leaves it.
List<MailMessage> filteredMessages(
  List<MailMessage> messages,
  List<MailMessage> hits,
  MessageFilter filter,
  Set<String> ownAddresses, {
  String? keep,
}) {
  if (filter == MessageFilter.all) return messages;
  bool kept(MailMessage m) => m.id == keep || filter.matches(m, ownAddresses);
  final held = {for (final m in messages) m.id};
  return [
    for (final m in messages)
      if (kept(m)) m,
    // A hit the list holds is the list's copy, which is the newer word
    // about it: read here a moment ago, the server's copy still says not.
    for (final h in hits)
      if (!held.contains(h.id) && kept(h)) h,
  ];
}
