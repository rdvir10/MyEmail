import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// Throws what the engine throws; each caller says so in its own way.
Future<void> syncNow(WidgetRef ref, String? listId) async {
  for (final account in ref.read(accountsProvider).value ?? const []) {
    await ref.read(foldersProvider.notifier).refreshAccount(account.id);
  }
  if (listId != null) {
    ref.invalidate(messagesProvider(listId));
    await ref.read(messagesProvider(listId).future);
  }
}
