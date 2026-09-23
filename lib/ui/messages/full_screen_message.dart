import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../domain/trusted_senders.dart';
import '../../state/attachment_providers.dart';
import '../../state/display_providers.dart';
import '../../state/message_providers.dart';
import '../../state/trusted_senders.dart';
import 'html_body_view.dart';

/// One message, and nothing else: the body edge to edge, with Android's
/// own bars out of the way.
///
/// The pop-out button already puts a message on a screen of its own, but
/// that screen still carries the app: a title bar, the header block, the
/// attachments. This is for the other thing — a long newsletter, a
/// shop's mail that was laid out for a whole page — where every strip of
/// chrome is width the message does not get.
///
/// The controls come back on a tap rather than being always there, which
/// is what every photo viewer and reader does, and what makes the mode
/// worth entering. Back, Esc or F11 leaves.
class FullScreenMessage extends ConsumerStatefulWidget {
  const FullScreenMessage({super.key, required this.message});

  final MailMessage message;

  /// Open it, and put the system bars back however it is left.
  static Future<void> open(BuildContext context, MailMessage message) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FullScreenMessage(message: message),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  ConsumerState<FullScreenMessage> createState() => _FullScreenMessageState();
}

class _FullScreenMessageState extends ConsumerState<FullScreenMessage> {
  final _html = GlobalKey<HtmlBodyViewState>();
  final _textScroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'Full screen message');

  /// The bar starts shown, so it is clear how to get out, and goes as
  /// soon as the reading starts.
  bool _controlsShown = true;
  Timer? _hideBar;

  @override
  void initState() {
    super.initState();
    _immersive(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _hideBar = Timer(const Duration(milliseconds: 1600), () {
        if (mounted && _controlsShown) setState(() => _controlsShown = false);
      });
    });
  }

  @override
  void dispose() {
    _hideBar?.cancel();
    _immersive(false);
    _textScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Hidden while reading, back afterwards. `edgeToEdge` rather than
  /// `manual`, because that is what the rest of the app runs in and
  /// anything else leaves the shell with a gap where a bar used to be.
  void _immersive(bool on) {
    SystemChrome.setEnabledSystemUIMode(
      on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _scrollBy(double dy) {
    final html = _html.currentState;
    if (html != null) {
      html.scrollBy(dy);
    } else if (_textScroll.hasClients) {
      final p = _textScroll.position;
      _textScroll.jumpTo(
        (p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent),
      );
    }
  }

  void _scrollToEnd({required bool top}) {
    final html = _html.currentState;
    if (html != null) {
      html.scrollToEnd(top: top);
    } else if (_textScroll.hasClients) {
      final p = _textScroll.position;
      _textScroll.jumpTo(top ? p.minScrollExtent : p.maxScrollExtent);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final screen = ((context.size?.height ?? 600) - 80).clamp(120.0, 4000.0);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _scrollBy(64);
      case LogicalKeyboardKey.arrowUp:
        _scrollBy(-64);
      case LogicalKeyboardKey.pageDown:
        _scrollBy(screen);
      case LogicalKeyboardKey.pageUp:
        _scrollBy(-screen);
      case LogicalKeyboardKey.space:
        _scrollBy(shift ? -screen : screen);
      case LogicalKeyboardKey.home:
        _scrollToEnd(top: true);
      case LogicalKeyboardKey.end:
        _scrollToEnd(top: false);
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.f11:
        Navigator.of(context).maybePop();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final body = ref.watch(messageBodyProvider(message.id));
    final showImages = ref.watch(displayProvider).alwaysShowImages ||
        isSenderTrusted(ref.watch(trustedSendersProvider), message.from.email);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                // A tap is how the controls come back, so it must not be
                // eaten by the body; a WebView takes its own taps, which
                // is why the bar also answers to Esc and to Back.
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  // A tap is a decision about the bar, so the timer that
                  // was going to hide it has had its say.
                  _hideBar?.cancel();
                  setState(() => _controlsShown = !_controlsShown);
                },
                child: body.when(
                  loading: () => const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  error: (e, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Could not load the message.\n$e',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  data: (b) => _body(theme, b, showImages),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 160),
                offset: _controlsShown ? Offset.zero : const Offset(0, -1),
                child: _Controls(
                  subject: message.subject,
                  onClose: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme, MailBody b, bool showImages) {
    final html = b.html;
    if (html != null && html.trim().isNotEmpty && !kIsWeb) {
      return HtmlBodyView(
        key: _html,
        html: html,
        showImages: showImages,
        inlinePictures: watchInlinePictures(ref, widget.message.id, html),
        senderEmail: widget.message.from.email,
        onTrust: (entry) =>
            ref.read(trustedSendersProvider.notifier).trust(entry),
      );
    }
    return SafeArea(
      child: SingleChildScrollView(
        controller: _textScroll,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        child: SelectableText(
          b.text,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}

/// The strip that comes and goes: what is being read, and the way out.
class _Controls extends StatelessWidget {
  const _Controls({required this.subject, required this.onClose});

  final String subject;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Leave full screen',
                icon: const Icon(Icons.fullscreen_exit),
                onPressed: onClose,
              ),
              Expanded(
                child: Text(
                  subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
