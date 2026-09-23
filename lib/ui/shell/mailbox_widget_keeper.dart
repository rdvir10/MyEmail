import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../data/widget/widget_setup_channel.dart';
import '../../data/widget/widget_taps.dart';
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

    // Opened by tapping a widget: go where it was pointing.
    folderAppOpenedOn().then((folderId) {
      if (folderId != null && mounted) _openFolder(folderId);
    });
    _taps = listenForWidgetTaps(_openFolder);
  }

  StreamSubscription<Uri?>? _taps;

  @override
  void dispose() {
    _taps?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Show what the tapped widget was counting.
  ///
  /// Set even when the folder is not in the tree yet: folders load a moment
  /// after the first frame, and the selection is honoured as soon as the one
  /// it names turns up.
  void _openFolder(String folderId) {
    if (!mounted) return;
    ref.read(selectedFolderIdProvider.notifier).select(folderId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      _caughtUp();
    }
  }

  Future<void> _caughtUp() async {
    // Not awaited by the caller: nothing on screen is waiting for it, and a
    // widget that updates a moment after the app opens is no worse than one
    // that holds the first frame back.
    final widgets = ref.read(mailboxWidgetsProvider);
    final engine = ref.read(mailEngineProvider);
    await widgets.markCaughtUp(DateTime.now().toUtc(), engine);
    // Only the app can ask Android what is still on the home screen, so this
    // is where a widget that was dragged to the bin stops being counted.
    final placed = await placedWidgetIds();
    if (placed != null) await widgets.refresh(engine, placed: placed);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
