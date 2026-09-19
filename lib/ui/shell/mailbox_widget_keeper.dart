import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../state/widget_providers.dart';

/// Keeps the home-screen widgets in step with the app being used.
///
/// Two moments matter, and they are the same moment from either side: the app
/// coming to the front, and the app going away. Both mean "you have just
/// looked at your mail", which is what the widget's "new since" counts from.
///
/// Wrapped around the app rather than living in the shell, so it keeps
/// working while a message is open, a screen is pushed, or the shell is
/// rebuilt underneath it.
class MailboxWidgetKeeper extends ConsumerStatefulWidget {
  const MailboxWidgetKeeper({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MailboxWidgetKeeper> createState() =>
      _MailboxWidgetKeeperState();
}

class _MailboxWidgetKeeperState extends ConsumerState<MailboxWidgetKeeper>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Starting the app is the first of those moments, and there is no
    // lifecycle event for it.
    _caughtUp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      _caughtUp();
    }
  }

  void _caughtUp() {
    // Not awaited: nothing on screen is waiting for it, and a widget that
    // updates a moment after the app opens is no worse than one that holds
    // the first frame back.
    ref.read(mailboxWidgetsProvider).markCaughtUp(
          DateTime.now().toUtc(),
          ref.read(mailEngineProvider),
        );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
