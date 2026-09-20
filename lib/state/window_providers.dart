import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/windows/window_opener.dart';
import 'providers.dart';

/// How a second window is opened. main() overrides this on Android; tests
/// and the browser preview record instead.
final windowOpenerProvider =
    Provider<WindowOpener>((ref) => FakeWindowOpener(supported: false));

/// Whether windows are available at all, so the buttons that open one can
/// stay away on a platform with no second window to open.
final windowsAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(windowOpenerProvider).available(),
);

/// Every new message, reply and forward opens in a window of its own,
/// rather than on top of the mailbox. Off by default: it is a way of
/// working for a tablet with room, not for a phone.
class ComposeInWindow extends Notifier<bool> {
  static const _key = 'compose.in-window.v1';

  @override
  bool build() => ref.watch(uiStateStoreProvider).readString(_key) == 'yes';

  void set(bool on) {
    ref.read(uiStateStoreProvider).writeString(_key, on ? 'yes' : 'no');
    state = on;
  }
}

final composeInWindowProvider =
    NotifierProvider<ComposeInWindow, bool>(ComposeInWindow.new);
