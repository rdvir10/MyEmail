import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/window_handoff.dart';
import '../../state/providers.dart';
import '../compose/compose_screen.dart';
import 'app_shell.dart';

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
  }

  Future<void> _show() async {
    if (!mounted) return;
    final Widget screen;
    switch (widget.request) {
      case ComposeWindow(:final draft, :final disposable):
        screen = ComposeScreen(draft: draft, disposable: disposable);
      case MessageWindow(:final message):
        // The message's own folder is the list its actions go through:
        // marking read, flagging, deleting all look the message up there.
        ref.read(selectedFolderIdProvider.notifier).select(message.folderId);
        screen = MessageScreen(message: message);
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    // Whatever closed the screen closed the window's reason to exist.
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
