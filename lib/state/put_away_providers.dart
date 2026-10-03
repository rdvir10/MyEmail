import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';

/// Each time the person puts the app away; see appPutAwayEvents. Nothing
/// where there is no Android to say so.
final appPutAwayProvider = Provider<Stream<void>>((ref) => const Stream.empty());

/// What a screen does before the app, put away, closes it: true once it may
/// close, with anything worth keeping kept; false to stay open, and the
/// screens under it with it.
typedef PutAwayGuard = Future<bool> Function();

/// The guards of the screens open now, by the route each is on.
class PutAwayGuards {
  final _byRoute = <Route<dynamic>, PutAwayGuard>{};

  void set(Route<dynamic> route, PutAwayGuard guard) => _byRoute[route] = guard;

  /// Only if it is still this guard: a screen moving to another route must
  /// not take the next screen's guard with it.
  void remove(Route<dynamic> route, PutAwayGuard guard) {
    if (_byRoute[route] == guard) _byRoute.remove(route);
  }

  PutAwayGuard? operator [](Route<dynamic> route) => _byRoute[route];
}

final putAwayGuardsProvider = Provider<PutAwayGuards>((ref) => PutAwayGuards());

/// Asks the message list to go back to its top, newest first.
class ListToTop extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final listToTopProvider = NotifierProvider<ListToTop, int>(ListToTop.new);

/// The Inbox the app comes back to from [folderId]: that folder if it is an
/// Inbox, an account's or All Inboxes; otherwise its own account's. Null
/// where there is no telling, which leaves the folder as it is.
String? inboxToComeBackTo(String? folderId, Map<String, MailFolder> index) {
  final folder = index[folderId];
  if (folder == null) return null;
  if (folder.role == FolderRole.inbox ||
      folder.role == FolderRole.unifiedInbox) {
    return folder.id;
  }
  return index.values
      .firstWhereOrNull(
        (f) => f.accountId == folder.accountId && f.role == FolderRole.inbox,
      )
      ?.id;
}
