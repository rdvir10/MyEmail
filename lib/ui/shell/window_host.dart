import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/window_handoff.dart';
import '../../state/providers.dart';
import '../../state/put_away_providers.dart';
import '../../state/read_marker.dart';
import '../../state/window_providers.dart';
import '../compose/compose_screen.dart';
import 'app_shell.dart';
import 'put_away.dart';

/// The whole of a second window: one message being written, or one being
/// read, and nothing behind it.
///
/// The screen is pushed on top of an empty base rather than being the base
/// itself, because a screen that pops itself — a message sent, a message
/// deleted, the back button — needs somewhere to pop to; and when it gets
/// there, the window has nothing left to show and closes. Popping the only
/// route of a navigator leaves a black screen and an activity still open.
class WindowHost extends ConsumerStatefulWidget {
  const WindowHost({super.key, required this.request});

  final WindowRequest request;

  @override
  ConsumerState<WindowHost> createState() => _WindowHostState();
}

class _WindowHostState extends ConsumerState<WindowHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
    // Put away, the window closes as the main one comes back to the mail:
    // a message being written goes to Drafts, one being read just closes,
    // and the window goes with it.
    _putAways = ref.read(appPutAwayProvider).listen((_) {
      if (!mounted) return;
      closeForPutAway(Navigator.of(context), ref.read(putAwayGuardsProvider));
    });
  }

  StreamSubscription<void>? _putAways;

  @override
  void dispose() {
    _putAways?.cancel();
    super.dispose();
  }

  Future<void> _show() async {
    if (!mounted) return;
    // Whatever is written in this copy of the app goes at once: see
    // InAWindow. Said before anything can be written.
    ref.read(inAWindowProvider.notifier).mark();
    final Widget screen;
    switch (widget.request) {
      case ComposeWindow(
          :final draft,
          :final disposable,
          :final offerSmallerPictures,
        ):
        screen = ComposeScreen(
          draft: draft,
          disposable: disposable,
          inWindow: true,
          offerSmallerPictures: offerSmallerPictures,
        );
      case MessageWindow(:final message):
        // The message's own folder is the list its actions go through:
        // marking read, flagging, deleting all look the message up there.
        // Shown, not chosen: the app's own choice of folder stays its own.
        ref.read(selectedFolderIdProvider.notifier).showOnly(message.folderId);
        screen = MessageScreen(message: message);
    }
    // Taken before the screen is shown: what closes it can be this copy of
    // the app being taken down, and a ref read after that throws.
    final marker = ref.read(readMarkerProvider);
    final work = ref.read(workInFlightProvider);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    // Whatever closed the screen closed the window's reason to exist. But
    // ending the window ends this copy of the app, and with it anything it
    // has asked of a server and not heard back about: a delete, a move, a
    // mark, gone neither sent nor kept for later. So it waits for those
    // first, as a message being written in a window waits for its Send.
    //
    // A message is left now, not when its pane is taken down after the
    // screen's slide out, so that "When I move on" sends its mark while
    // there is a window to wait for it. The pane telling it again then
    // changes nothing.
    if (widget.request case MessageWindow(:final message)) {
      marker.left(message.id);
    }
    // Something refused stays said on the window, on the app's bar, until
    // the bar closes: the window has nothing else on it by then, and
    // closing at once looked like success with the message still where it
    // was. What went closes the window at once, as before. The spinner
    // shows while there is work on its way, an Undo pressed on that bar
    // included, and Back waits for it.
    final finished = await work.settled(
      finishWithin,
      working: (working) {
        if (mounted && _finishing != working) {
          setState(() => _finishing = working);
        }
      },
    );
    // Out of time with the server still silent: said, so that the window
    // closing is not taken for the change having been made.
    if (!finished && mounted) {
      setState(() => _unanswered = true);
      await work.settled(unansweredFor);
    }
    await SystemNavigator.pop();
  }

  /// The longest a window waits for its work before it ends all the same:
  /// a server that never answers must not keep it open for good.
  static const finishWithin = Duration(seconds: 30);

  /// How long a window says the server did not answer before it ends,
  /// unless it answers meanwhile.
  static const unansweredFor = Duration(seconds: 5);

  /// Waiting for [WorkInFlight] once the screen has gone: said on the
  /// window, which has nothing else on it by then, and nothing to press.
  bool _finishing = false;

  /// [finishWithin] passed with the work still on its way.
  bool _unanswered = false;

  @override
  Widget build(BuildContext context) => PopScope(
        // Back would end the window, and the work with it.
        canPop: !_finishing || _unanswered,
        child: Scaffold(
          body: _unanswered
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'The server has not answered, so the change may not '
                      'have been made.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : !_finishing
                  ? null
                  : const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Telling the server…'),
                        ],
                      ),
                    ),
        ),
      );
}
