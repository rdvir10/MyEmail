import 'dart:async';

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

/// Whether this copy of the app is a window of its own: WindowHost says so
/// as it opens its screen. The copy ends with the window, so a message
/// written anywhere in it, a reply on a message's window too, is sent at
/// once rather than held for Undo Send: held in this copy's memory, it
/// ended with the window when Back closed it within the seconds, never
/// sent. False in the main window.
class InAWindow extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

final inAWindowProvider = NotifierProvider<InAWindow, bool>(InAWindow.new);

/// What this copy of the app has asked of a server and not yet heard back
/// about: a delete, a move, a mark. MessageActions notes each one here, and
/// each bar it raises to say one was not done.
///
/// For a window of its own, which is a whole copy of the app that ends
/// with the window: it waits for these before it ends (see WindowHost), or
/// they end with it, neither sent nor kept for later. A message deleted in
/// a window stayed in the Inbox that way, with nothing said. The main
/// window never waits on this, and the notes cost it nothing.
class WorkInFlight {
  final _work = <Future<void>>{};

  /// Bars saying something asked was not done, until each closes.
  final _sayings = <Future<void>>{};

  /// Whether anything is still on its way, or still being said.
  bool get busy => _work.isNotEmpty || _sayings.isNotEmpty;

  /// [work] noted until it is done, however it ends. What it comes to is
  /// for its caller: nothing here reads it, and an error is not thrown
  /// again from here.
  void add(Future<Object?> work) => _note(_work, work);

  /// [shown], a bar saying something asked was not done, noted until it
  /// closes: a window of its own stays up while it is read, rather than
  /// closing as though all had gone. It is not work, so [settled] does not
  /// count one still showing as unfinished. A bar that never closes holds
  /// a window no longer than [settled] lets anything; in the main window
  /// nothing waits on it, and the next bar MessageActions raises closes it.
  void addSaying(Future<Object?> shown) => _note(_sayings, shown);

  static void _note(Set<Future<void>> into, Future<Object?> it) {
    late final Future<void> noted;
    noted = it
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => into.remove(noted));
    into.add(noted);
  }

  /// Done once everything on its way has finished and everything being
  /// said has closed, what is added meanwhile included, or once [limit]
  /// has passed, so neither a server that never answers nor a bar that
  /// never closes can keep a window open for good. True when all the work
  /// finished, whatever is still being said.
  ///
  /// [working] is told, as each wait begins, whether there is work on its
  /// way (true) or only something being said (false). Work can come again
  /// after it was done: an Undo pressed on a refusal's bar.
  Future<bool> settled(
    Duration limit, {
    void Function(bool working)? working,
  }) async {
    if (!busy) return true;
    final over = Completer<void>();
    final timer = Timer(limit, over.complete);
    try {
      while (busy && !over.isCompleted) {
        // The work first: what is said about it comes once it is done.
        working?.call(_work.isNotEmpty);
        final waiting = _work.isNotEmpty ? [..._work] : [..._sayings];
        await Future.any([Future.wait(waiting), over.future]);
      }
      return _work.isEmpty;
    } finally {
      timer.cancel();
    }
  }
}

final workInFlightProvider = Provider<WorkInFlight>((ref) => WorkInFlight());
