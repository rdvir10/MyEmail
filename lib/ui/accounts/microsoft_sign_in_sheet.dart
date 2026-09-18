import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/auth/oauth_token.dart';
import '../../state/providers.dart';

/// The Microsoft half of adding an Outlook.com account.
///
/// Shows the short code, sends the person to microsoft.com/devicelogin, and
/// waits. Pops with an [OAuthToken] when they finish, or with null if they
/// back out or it fails.
///
/// The waiting is the whole design problem here. It can take a minute or
/// three, it happens on a different device as often as not, and there is
/// nothing to show but a spinner. So the code stays on screen the entire
/// time, large enough to read across a desk, with the link right under it.
class MicrosoftSignInSheet extends ConsumerStatefulWidget {
  const MicrosoftSignInSheet({super.key});

  /// Returns the token, or null if the person backed out or it failed.
  static Future<OAuthToken?> show(BuildContext context) =>
      showModalBottomSheet<OAuthToken>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const MicrosoftSignInSheet(),
      );

  @override
  ConsumerState<MicrosoftSignInSheet> createState() =>
      _MicrosoftSignInSheetState();
}

class _MicrosoftSignInSheetState extends ConsumerState<MicrosoftSignInSheet> {
  /// Resolved on dispose, which is what stops the poll when the sheet closes.
  /// Without it the loop would keep asking Microsoft for a token on behalf of
  /// a screen nobody is looking at, until the code expired a quarter of an
  /// hour later.
  final _stopped = Completer<void>();

  DeviceCodePrompt? _prompt;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    if (!_stopped.isCompleted) _stopped.complete();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _prompt = null;
    });
    final oauth = ref.read(microsoftOAuthProvider);
    try {
      final prompt = await oauth.requestDeviceCode();
      if (!mounted) return;
      setState(() => _prompt = prompt);

      final token = await oauth.awaitToken(prompt, stopSignal: _stopped.future);
      if (!mounted) return;
      Navigator.of(context).pop(token);
    } on SignInCancelled {
      // The sheet is already closing; there is nobody to tell.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _messageFor(e));
    }
  }

  static String _messageFor(Object e) => switch (e) {
        SignInFailed(:final message) => message,
        SignInExpired(:final message) => message,
        SignInDeclined(:final message) => message,
        SignInTimedOut(:final message) => message,
        _ => 'Sign-in failed: $e',
      };

  Future<void> _copyCode() async {
    final code = _prompt?.userCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  Future<void> _openPage() async {
    final uri = _prompt?.verificationUri;
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      // No browser took it. The URL is on screen anyway, so say so rather
      // than leaving a button that appears to do nothing.
      setState(() => _error =
          'Could not open a browser. Go to $uri and enter the code.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prompt = _prompt;
    final error = _error;

    // Scrollable because the sheet is tall for what it is and a phone held in
    // landscape has very little height to give it.
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sign in to Microsoft', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          if (error != null)
            _Failure(message: error, onRetry: _start)
          else if (prompt == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            ..._waiting(theme, prompt),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  List<Widget> _waiting(ThemeData theme, DeviceCodePrompt prompt) => [
        Text(
          'Open the page below on any device, then enter this code.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              SelectableText(
                prompt.userCode,
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _copyCode,
                icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
                label: Text(_copied ? 'Copied' : 'Copy code'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _openPage,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open the sign-in page'),
        ),
        const SizedBox(height: 8),
        SelectableText(
          prompt.verificationUri.toString(),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('Waiting for you to finish', style: theme.textTheme.bodyMedium),
          ],
        ),
      ];
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          message,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}
