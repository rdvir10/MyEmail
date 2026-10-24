import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import 'providers.dart';

/// The messages pinned to the top of their folder, by id, kept across
/// restarts. New Outlook's Pin.
///
/// On this device only: the ids are the ones this device gave the messages,
/// and Outlook on a PC keeps its own pins. A message moved elsewhere has a
/// new id there, so the pin stays behind with the old one, which matches
/// nothing; the oldest pins go once there are more than [limit], so those
/// do not pile up for ever.
class PinnedMessages extends Notifier<Set<String>> {
  static const limit = 300;

  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeIds(UiStateKeys.pinned, next));
    return store.readIds(UiStateKeys.pinned);
  }

  bool isPinned(String id) => state.contains(id);

  /// Pin every one of [ids], or unpin them all when [pin] is false.
  void setPinned(Iterable<String> ids, bool pin) {
    final changing = ids.toSet();
    if (!pin) {
      state = {for (final id in state) if (!changing.contains(id)) id};
      return;
    }
    // Newest last, so the oldest are the ones dropped past the limit.
    final next = [
      for (final id in state)
        if (!changing.contains(id)) id,
      ...changing,
    ];
    state = next.skip(next.length > limit ? next.length - limit : 0).toSet();
  }
}

final pinnedMessagesProvider =
    NotifierProvider<PinnedMessages, Set<String>>(PinnedMessages.new);
