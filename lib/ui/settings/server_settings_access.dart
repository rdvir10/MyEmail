import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../state/providers.dart';
import '../../state/server_settings_providers.dart';
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';

/// Whether an account's settings on its server could ever be changed here:
/// one signed in with Microsoft or Google. A Gmail account on an app
/// password can be, once signed in with Google instead.
bool canReachServerSettings(Account account) =>
    account.authMethod == AuthMethod.oauth ||
    account.provider == MailProvider.gmail;

/// A sign-in again for [account] that asks for its settings beside the
/// mail: Microsoft is asked by name, Google's sign-in asks for everything.
/// The account keeps everything cached. True when it went through.
Future<bool> signInForServerSettings(
  BuildContext context,
  WidgetRef ref,
  Account account,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    switch (account.provider) {
      case MailProvider.outlook:
        final token = await MicrosoftSignInScreen.show(
          context,
          loginHint: account.emailAddress,
          scopes: [
            ...MicrosoftOAuth.scopes,
            ...MicrosoftOAuth.mailboxSettingsScopes,
          ],
        );
        if (token == null) return false;
        await ref
            .read(accountsProvider.notifier)
            .signInAgain(accountId: account.id, token: token);
      case MailProvider.gmail:
        final result = await GoogleSignInScreen.show(
          context,
          loginHint: account.emailAddress,
        );
        if (result == null) return false;
        await ref.read(accountsProvider.notifier).signInAgain(
              accountId: account.id,
              token: result.token,
              signedInAs: result.identity?.email,
            );
    }
    return true;
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: kBottomMessage,
        content: Text(e is ReadableError ? e.message : '$e'),
      ));
    return false;
  } finally {
    ref
      ..invalidate(autoReplyProvider(account.id))
      ..invalidate(mailRulesProvider(account.id));
  }
}

/// What a failed read of the settings says, and whether a sign-in fixes it.
({String line, bool offerSignIn}) serverSettingsProblem(
  Account account,
  Object error,
) =>
    switch (error) {
      NoServerSettings() => (
          line: 'Uses an app password, which reaches mail only. Sign in with '
              'Google to change this.',
          offerSignIn: true,
        ),
      SignInNeedsConsent(:final needsAdministrator) => (
          line: needsAdministrator
              ? 'Not allowed yet. Allow, then sign in. Where your '
                  'organisation has to approve it, the sign-in sends them '
                  'the request, and this works once they have.'
              : 'Not allowed yet. Allow, then sign in to allow it.',
          offerSignIn: true,
        ),
      ReadableError(:final message) => (line: message, offerSignIn: false),
      _ => (line: '$error', offerSignIn: false),
    };

/// Where a screen of an account's server settings could not read them:
/// the reason, and Allow where a sign-in fixes it, or Try again.
class ServerSettingsProblem extends ConsumerStatefulWidget {
  const ServerSettingsProblem({
    super.key,
    required this.account,
    required this.error,
    required this.onRetry,
  });

  final Account account;
  final Object error;
  final VoidCallback onRetry;

  @override
  ConsumerState<ServerSettingsProblem> createState() =>
      _ServerSettingsProblemState();
}

class _ServerSettingsProblemState extends ConsumerState<ServerSettingsProblem> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = serverSettingsProblem(widget.account, widget.error);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              problem.offerSignIn
                  ? Icons.lock_outline
                  : Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(problem.line, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (_busy)
              const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (problem.offerSignIn)
              FilledButton(
                key: const ValueKey('server-settings-allow'),
                onPressed: () async {
                  setState(() => _busy = true);
                  await signInForServerSettings(context, ref, widget.account);
                  if (mounted) setState(() => _busy = false);
                },
                child: const Text('Allow'),
              )
            else
              OutlinedButton(
                onPressed: widget.onRetry,
                child: const Text('Try again'),
              ),
          ],
        ),
      ),
    );
  }
}
