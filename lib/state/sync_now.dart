import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/account.dart';
import '../domain/error_report.dart';
import 'message_providers.dart';
import 'providers.dart';

/// Check now, rather than waiting for the next background pass.
///
/// Refreshes the folder counts as well as the list: someone asking for this
/// wants the whole view to be current, and a list that updated while the
/// tree's unread counts did not looks broken.
///
/// One function because it is reached two ways — the Sync button on the
/// ribbon, and pulling the message list down — and two copies of "what
/// syncing means" would drift apart the first time one of them changed.
/// Every account is checked, together, and then the list is checked with
/// its server whatever happened to them, and waited for. It used to stop at
/// the first account that failed, so one expired sign-in meant nothing else
/// was ever refreshed by hand. Then throws [SyncIncomplete] naming each
/// account that failed, and what the list threw; each caller says so in
/// its own way.
Future<void> syncNow(WidgetRef ref, String? listId) async {
  final accounts = ref.read(accountsProvider).value ?? const <Account>[];
  final failed = <(Account, Object)>[];
  await Future.wait([
    for (final account in accounts)
      ref
          .read(foldersProvider.notifier)
          .refreshAccount(account.id)
          .catchError((Object e) => failed.add((account, e))),
  ]);
  Object? listFailed;
  if (listId != null) {
    try {
      await ref.read(messagesProvider(listId).notifier).checkNow();
    } catch (e) {
      // Said once: an account whose folders could not be listed is why
      // its folder could not be checked either.
      final accountId = ref.read(folderIndexProvider)[listId]?.accountId;
      if (!failed.any((f) => f.$1.id == accountId)) {
        final account = accounts.where((a) => a.id == accountId).firstOrNull;
        if (account != null) {
          failed.add((account, e));
        } else {
          listFailed = e;
        }
      }
    }
  }
  if (failed.isNotEmpty || listFailed != null) {
    throw SyncIncomplete(failed, list: listFailed);
  }
}

/// Some accounts could not be checked. The rest were.
class SyncIncomplete implements Exception, ReadableError {
  const SyncIncomplete(this.failed, {this.list});

  final List<(Account, Object)> failed;

  /// What the list threw where it is no one account's: All inboxes.
  final Object? list;

  @override
  String get message => [
        for (final (account, error) in failed)
          '${account.displayName}: ${_said(error)}',
        if (list case final error?) _said(error),
      ].join('\n');

  static String _said(Object error) =>
      error is ReadableError ? error.message : '$error';

  @override
  String toString() => message;
}
