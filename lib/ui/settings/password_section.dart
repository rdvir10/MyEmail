import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/password_expiry.dart';
import '../../state/password_providers.dart';
import '../../state/providers.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';

/// A Microsoft account's password on its settings: when it was last
/// changed, as Microsoft says, and when it runs out by the organisation's
/// rule, typed in here. Microsoft keeps the rule where only an
/// administrator can read it.
class PasswordSection extends ConsumerStatefulWidget {
  const PasswordSection({super.key, required this.account});

  final Account account;

  @override
  ConsumerState<PasswordSection> createState() => _PasswordSectionState();
}

class _PasswordSectionState extends ConsumerState<PasswordSection> {
  late final TextEditingController _days = TextEditingController(
    text: '${ref.read(passwordDaysProvider.notifier).of(widget.account.id)}',
  );
  bool _busy = false;

  Account get account => widget.account;

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  void _setDays(String text) {
    final days = int.tryParse(text.trim());
    if (days == null || days < 0) return;
    ref.read(passwordDaysProvider.notifier).set(account.id, days);
  }

  /// A sign-in that asks for the profile beside the mail. The account keeps
  /// everything cached, as Settings, Accounts' sign-in again does.
  Future<void> _allow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final token = await MicrosoftSignInScreen.show(
        context,
        loginHint: account.emailAddress,
        scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.profileScopes],
      );
      if (token == null) return;
      await ref
          .read(accountsProvider.notifier)
          .signInAgain(accountId: account.id, token: token);
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          content: Text(e is ReadableError ? e.message : '$e'),
        ));
    } finally {
      ref.invalidate(passwordAgeProvider(account.id));
      unawaited(ref.read(passwordKeeperProvider).keepUp(force: true));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final age = ref.watch(passwordAgeProvider(account.id));
    final expiry = ref.watch(passwordExpiryProvider(account.id));
    final now = ref.watch(passwordClockProvider)();
    final days = ref.watch(passwordDaysProvider)[account.id] ??
        PasswordExpiry.defaultDays;

    final (String line, _Offer offer) = switch (age) {
      AsyncError(error: SignInNeedsConsent()) => (
          'The app has not been allowed to see when the password was last '
              'changed. Allow, then sign in. Where your organisation has to '
              'approve it, the sign-in sends them the request, and this '
              'works once they have.',
          _Offer.allow,
        ),
      AsyncError(:final error) => (
          error is ReadableError ? error.message : '$error',
          _Offer.retry,
        ),
      AsyncData(value: PasswordAge(lastChanged: null)) => (
          'Microsoft does not say when this password was last changed.',
          _Offer.none,
        ),
      AsyncData(value: PasswordAge(:final lastChanged?, neverExpires: true)) =>
        (
          'Last changed ${passwordDay(lastChanged)}. Microsoft says it '
              'never expires.',
          _Offer.none,
        ),
      AsyncData(value: PasswordAge(:final lastChanged?)) => (
          expiry == null
              ? 'Last changed ${passwordDay(lastChanged)}.'
              : 'Last changed ${passwordDay(lastChanged)}. '
                  '${expiry.daysLeft(now) < 0 ? 'Expired' : 'Expires'} '
                  '${passwordDay(expiry.expires)}, ${expiry.when(now)}.',
          _Offer.none,
        ),
      _ => ('Checking when it was last changed…', _Offer.none),
    };
    final near = expiry != null && expiry.isNear(now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Password', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          line,
          key: const ValueKey('password-line'),
          style: near
              ? theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)
              : small,
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ] else if (offer == _Offer.allow) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('password-allow'),
              onPressed: _allow,
              child: const Text('Allow'),
            ),
          ),
        ] else if (offer == _Offer.retry) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => ref.invalidate(passwordAgeProvider(account.id)),
              child: const Text('Try again'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('password-days'),
          controller: _days,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Password lasts, in days',
            helperText: "Your organisation's rule; 0 if it never expires. "
                'The folder list says so from 14 days before, and the phone '
                'reminds you 14 days and 3 days before.',
            helperMaxLines: 4,
          ),
          onChanged: _setDays,
        ),
        if (expiry != null && days > 0) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () =>
                  ref.read(openInBrowserProvider)(changePasswordPage),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Change it at Microsoft'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Where your organisation lets it be changed online. Once it is '
            'changed, Microsoft may sign the app out of this account: sign '
            'in again above.',
            style: small,
          ),
        ],
      ],
    );
  }
}

enum _Offer { none, allow, retry }
