import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;

/// How many messages keep their body, files and pictures once nothing on
/// the screen shows them: the one just read and the two before it, so going
/// back up the list to one of them shows it at once, pictures and all.
///
/// Every message read used to keep them until Android stopped the app, the
/// pictures as data: text of up to 15 MB a message, and memory grew with
/// each message read. The bodies are in the cache on disk anyway.
const messagesKept = 3;

/// The messages let go of last, each holding on to what it brought with it
/// until [messagesKept] newer ones have been let go of too.
///
/// By message rather than by what was loaded for it: a message's body, its
/// files and its pictures go together, and one with pictures counts once.
class RecentMessages {
  /// What holds each message's loads, the one let go of longest ago first.
  final _held = <String, Set<KeepAliveLink>>{};

  void letGo(String messageId, KeepAliveLink link) {
    final links = _held.remove(messageId) ?? <KeepAliveLink>{};
    _held[messageId] = links..add(link);
    while (_held.length > messagesKept) {
      final oldest = _held.keys.first;
      for (final held in _held.remove(oldest)!) {
        held.close();
      }
    }
  }

  /// On the screen again, or gone: not this list's to let go of.
  void taken(String messageId, KeepAliveLink link) {
    final links = _held[messageId];
    if (links == null) return;
    links.remove(link);
    if (links.isEmpty) _held.remove(messageId);
  }
}

final recentMessagesProvider =
    Provider<RecentMessages>((ref) => RecentMessages());

/// The retry for what a message brings with it: none.
///
/// Riverpod otherwise asks ten times more over half a minute, the pane
/// showing a spinner throughout and the failure only at the end, for a
/// message deleted in Outlook a moment ago or a phone with no signal, and
/// each time another request to the server, or to the token endpoint for a
/// sign-in that has expired. The pane says what failed at once and offers
/// Try again.
Duration? notRetried(int retryCount, Object error) => null;

/// [loading], one of the things [messageId] brings with it: its body, its
/// files or the pictures in it. Held while the message is on the screen and
/// while it is among the [messagesKept] let go of last ([RecentMessages]).
///
/// A failure is let go of with the last screen showing it, so that opening
/// the message again asks again. Held in the provider, it stayed until
/// Android stopped the app: a message opened on the train with no signal
/// still said "Could not load the message" an hour later, back online, and
/// nothing short of a restart asked again.
Future<T> keptOnceLoaded<T>(
  Ref ref,
  String messageId,
  Future<T> loading,
) async {
  final recent = ref.watch(recentMessagesProvider);
  final link = ref.keepAlive();
  var failed = false;
  ref.onCancel(() {
    if (!failed) recent.letGo(messageId, link);
  });
  ref.onResume(() => recent.taken(messageId, link));
  ref.onDispose(() => recent.taken(messageId, link));
  try {
    return await loading;
  } catch (_) {
    failed = true;
    // Only while this is still the provider's own build: a link closed
    // after its provider has gone lets go of whatever has its place now.
    if (ref.mounted) {
      recent.taken(messageId, link);
      link.close();
    }
    rethrow;
  }
}
