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
/// Every account is checked, together, and the list is read again whatever
/// happened to them. It used to stop at the first account that failed, so
/// one expired sign-in meant nothing else was ever refreshed by hand. Then
/// throws [SyncIncomplete] naming each account that failed, or what the
/// list threw; each caller says so in its own way.
Future<void> syncNow(WidgetRef ref, String? listId) async {
  final failed = <(Account, Object)>[];
  await Future.wait([
    for (final account in ref.read(accountsProvider).value ?? const <Account>[])
      ref
          .read(foldersProvider.notifier)
          .refreshAccount(account.id)
          .catchError((Object e) => failed.add((account, e))),
  ]);
  if (listId != null) {
    ref.invalidate(messagesProvider(listId));
    await ref.read(messagesProvider(listId).future);
  }
  if (failed.isNotEmpty) throw SyncIncomplete(failed);
}

/// Some accounts could not be checked. The rest were.
class SyncIncomplete implements Exception, ReadableError {
  const SyncIncomplete(this.failed);

  final List<(Account, Object)> failed;

  @override
  String get message => [
        for (final (account, error) in failed)
          '${account.displayName}: '
              '${error is ReadableError ? error.message : error}',
      ].join('\n');

  @override
  String toString() => message;
}
