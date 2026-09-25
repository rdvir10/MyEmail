import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/error_report.dart';
import '../common/problem_view.dart';

import '../../data/auth/oauth_token.dart';
import '../../domain/account.dart';
import '../../state/providers.dart';
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';

/// Rename an account, recolour it, or sign it in again.
///
/// The address stays fixed, and is shown greyed with the reason: it is what
/// every cached folder and message is filed under, so a different address is
/// a different account rather than an edit to this one.
///
/// Signing in again is not that. It is the same mailbox with a credential
/// that works, and it exists because the alternative — remove the account,
/// add it back — throws away every cached message to fix a revoked app
/// password. Proved against the server before it replaces anything, so a
/// wrong password leaves the account exactly as it was.
class EditAccountScreen extends ConsumerStatefulWidget {
  const EditAccountScreen({super.key, required this.account});

  final Account account;

  @override
  ConsumerState<EditAccountScreen> createState() => _EditAccountScreenState();
}

class _EditAccountScreenState extends ConsumerState<EditAccountScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.account.displayName);
  late final TextEditingController _sender = TextEditingController(
    text: widget.account.hasOwnSenderName ? widget.account.senderName : '',
  );
  final TextEditingController _password = TextEditingController();
  late int _color = widget.account.colorValue;
  bool _busy = false;
  bool _showPassword = false;
  ProblemReport? _problem;
  String? _signInResult;

  /// The same four the app assigns to new accounts, plus enough more to tell
  /// several mailboxes apart at a glance.
  static const _palette = [
    0xFF0F6CBD,
    0xFF107C41,
    0xFFB4009E,
    0xFFCA5010,
    0xFF8764B8,
    0xFF00838F,
    0xFFB3261E,
    0xFF5B5FC7,
  ];

  @override
  void dispose() {
    _name.dispose();
    _sender.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Prove a new credential and put it in place of the old one.
  ///
  /// Kept apart from [_save] on purpose. Saving a name is instant and local;
  /// this one goes to the server and can fail, and rolling the two into one
  /// button would mean a rename that could be refused by a mail server.
  Future<void> _signInAgain({
    String? appPassword,
    OAuthToken? token,
    String? signedInAs,
  }) async {
    setState(() {
      _busy = true;
      _problem = null;
      _signInResult = null;
    });
    try {
      await ref.read(accountsProvider.notifier).signInAgain(
            accountId: widget.account.id,
            appPassword: appPassword,
            token: token,
            signedInAs: signedInAs,
          );
      // The tree lists this account again, so its "Sign in again" goes.
      ref.invalidate(foldersProvider);
      if (!mounted) return;
      _password.clear();
      final updated = ref
          .read(accountsProvider)
          .value
          ?.where((a) => a.id == widget.account.id)
          .firstOrNull;
      setState(() {
        _signInResult = 'Signed in. Nothing cached was lost.';
        if (updated != null) _current = updated;
      });
    } catch (e) {
      // Left while the server was still being asked: there is no screen to
      // say it on, and setState on a closed one throws.
      if (!mounted) return;
      setState(() => _problem = ProblemReport(
            doing: 'Signing in again to ${widget.account.emailAddress}',
            error: e,
            account: widget.account,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithMicrosoft() async {
    final token = await MicrosoftSignInScreen.show(
      context,
      loginHint: widget.account.emailAddress,
    );
    if (token == null || !mounted) return;
    await _signInAgain(token: token);
  }

  /// For a Google account, and for a Gmail account with an app password
  /// that is moving to Google sign-in: the same call, since the engine
  /// keeps the account and changes only how it signs in.
  Future<void> _signInWithGoogle() async {
    final result = await GoogleSignInScreen.show(
      context,
      loginHint: widget.account.emailAddress,
    );
    if (result == null || !mounted) return;
    await _signInAgain(
      token: result.token,
      signedInAs: result.identity?.email,
    );
  }

  /// The account as it is now, which a sign-in on this screen can change:
  /// it came in with an app password and signs in with Google from then on.
  /// Held here rather than watched, so showing the screen asks the engine
  /// for nothing.
  Account? _current;
  Account get _account => _current ?? widget.account;

  bool get _changed =>
      _name.text.trim() != widget.account.displayName ||
      _sender.text.trim() != _storedSenderName ||
      _color != widget.account.colorValue;

  String get _storedSenderName =>
      widget.account.hasOwnSenderName ? widget.account.senderName : '';

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await ref.read(accountsProvider.notifier).edit(
            accountId: widget.account.id,
            displayName: _name.text,
            colorValue: _color,
            senderName: _sender.text,
          );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _problem = ProblemReport(
            doing: 'Saving changes to ${widget.account.emailAddress}',
            error: e,
            account: widget.account,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Edit account'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            enabled: !_busy,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name in the folder list',
              helperText: 'Left empty, the current name is kept.',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _sender,
            enabled: !_busy,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name on mail you send',
              hintText: widget.account.displayName,
              helperText: 'What people see in the From line. Left empty, the '
                  'name above is used.',
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (widget.account.provider == MailProvider.outlook) ...[
            const SizedBox(height: 6),
            Text(
              'Microsoft may replace this with the name in your work '
              'directory on mail you send. That is the server\u2019s choice, '
              'not the app\u2019s.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 28),
          Text('Colour', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Marks this account in the folder tree, the unified Inbox, its '
            'notifications and its home-screen widgets.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in _palette)
                _ColorDot(
                  value: value,
                  selected: value == _color,
                  onTap: _busy ? null : () => setState(() => _color = value),
                ),
            ],
          ),
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _FixedField(
            label: 'Address',
            value: widget.account.emailAddress,
            theme: theme,
          ),
          _FixedField(
            label: 'Signs in with',
            value: switch ((_account.provider, _account.authMethod)) {
              (_, AuthMethod.appPassword) => 'An app password',
              (MailProvider.gmail, AuthMethod.oauth) => 'Google sign-in',
              (MailProvider.outlook, AuthMethod.oauth) => 'Microsoft sign-in',
            },
            theme: theme,
          ),
          const SizedBox(height: 8),
          Text(
            'The address cannot be changed. Every cached folder and message is '
            'filed under this account, so a different address means a '
            'different account: add it, then remove this one. Signing in again '
            'with the same address is below.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_problem != null) ...[
            const SizedBox(height: 16),
            ProblemView(problem: _problem!),
          ],
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text('Sign in again', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            switch (_account.authMethod) {
              AuthMethod.appPassword =>
                'If the app password stopped working — revoked, or replaced — '
                    'put the new one here. The account keeps its cached mail, '
                    'which removing and adding it again would not.',
              AuthMethod.oauth =>
                'If this account has been signed out, sign in again here. It '
                    'keeps its cached mail, which removing and adding it again '
                    'would not.',
            },
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (_account.authMethod == AuthMethod.appPassword) ...[
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'New app password',
                suffixIcon: IconButton(
                  tooltip: _showPassword ? 'Hide' : 'Show',
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: (_busy || _password.text.trim().isEmpty)
                  ? null
                  // Google shows app passwords with spaces; they are not part
                  // of it.
                  : () => _signInAgain(
                        appPassword: _password.text.replaceAll(' ', ''),
                      ),
              child: const Text('Check and save'),
            ),
            if (_account.provider == MailProvider.gmail &&
                ref.watch(googleClientIdProvider).isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Or switch to Google sign-in', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                'No app password to make or keep, and meetings you create '
                'go on your Google calendar. The account and its cached mail '
                'stay as they are.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _signInWithGoogle,
                icon: const Icon(Icons.login),
                label: const Text('Sign in with Google'),
              ),
            ],
          ] else if (_account.provider == MailProvider.gmail)
            OutlinedButton.icon(
              onPressed: _busy ? null : _signInWithGoogle,
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Google'),
            )
          else
            OutlinedButton.icon(
              onPressed: _busy ? null : _signInWithMicrosoft,
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Microsoft'),
            ),
          if (_signInResult != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _signInResult!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: (_busy || !_changed) ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(value),
            shape: BoxShape.circle,
            // A ring rather than a tick alone: on the darker swatches a white
            // tick is the only thing visible and it is easy to miss which dot
            // it is sitting on.
            border: selected
                ? Border.all(color: theme.colorScheme.onSurface, width: 3)
                : null,
          ),
          child: selected
              ? const Icon(Icons.check, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }
}

class _FixedField extends StatelessWidget {
  const _FixedField({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Text(value, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      );
}
