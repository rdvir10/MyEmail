import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart';
import '../../domain/account.dart';
import '../../state/providers.dart';

/// Add a Gmail account with an app password.
///
/// Round one is Gmail only, so there is no provider choice; the field is a
/// label. The password is never echoed, never logged, and goes straight to
/// the credential store once the server has accepted it.
class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key, this.isFirstAccount = false});

  /// Changes the copy slightly: on first run there is no tree to go back to.
  final bool isFirstAccount;

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final email = _email.text.trim();
    final name = _name.text.trim().isEmpty
        ? email.split('@').first
        : _name.text.trim();
    try {
      await ref.read(accountsProvider.notifier).add(
            displayName: name,
            emailAddress: email,
            provider: MailProvider.gmail,
            // Google shows app passwords with spaces; they are not part of it.
            secret: _password.text.replaceAll(' ', ''),
          );
      if (mounted) Navigator.of(context).maybePop();
    } on AuthenticationFailed catch (e) {
      setState(() => _error = e.message);
    } on ConnectionFailed catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not add the account: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isFirstAccount ? 'Welcome to MyEmail' : 'Add account'),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.isFirstAccount) ...[
                        Text(
                          'Add your Gmail account to get started.',
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 20),
                      ],
                      const _ProviderLabel(),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _email,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Gmail address',
                        ),
                        validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) return 'Enter the address.';
                          if (!s.contains('@') || s.endsWith('@')) {
                            return 'That does not look like an address.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_showPassword,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'App password',
                          helperText:
                              'The 16-character password from Google, not '
                              'your normal one. See docs/gmail-app-password.md.',
                          helperMaxLines: 2,
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
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter the app password.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: 'Name in the folder list (optional)',
                          hintText: 'Personal',
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderLabel extends StatelessWidget {
  const _ProviderLabel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.mail_outline, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text('Gmail', style: theme.textTheme.titleMedium),
        const SizedBox(width: 8),
        Text(
          'Outlook.com comes later',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
