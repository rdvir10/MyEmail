import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/sender_blocks.dart';
import 'providers.dart';

/// The blocked senders and the ones never blocked, kept across restarts and
/// in the backup. The engine reads the same store as mail arrives, the
/// background worker included; see `CachedImapEngine.senderBlocks`.
class SenderBlocksNotifier extends Notifier<SenderBlocks> {
  @override
  SenderBlocks build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) =>
        store.writeString(UiStateKeys.senderBlocks, next.toJsonString()));
    return SenderBlocks.fromJsonString(
      store.readString(UiStateKeys.senderBlocks),
    );
  }

  void block(String entry) => state = state.block(entry);

  void neverBlock(String entry) => state = state.neverBlock(entry);

  void forget(String entry) => state = state.forget(entry);

  /// Back to [before], for an Undo.
  void restore(SenderBlocks before) => state = before;
}

final senderBlocksProvider =
    NotifierProvider<SenderBlocksNotifier, SenderBlocks>(
  SenderBlocksNotifier.new,
);
