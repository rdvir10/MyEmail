import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/error_report.dart';
import '../common/problem_view.dart';

import '../../domain/account.dart';
import '../../state/providers.dart';
import '../settings/backup_screen.dart';
import 'microsoft_sign_in_screen.dart';

/// Add a mailbox: Gmail with an app password, or a Microsoft one with
/// Microsoft sign-in.
///
/// The two differ in more than the button. Gmail takes a secret the person
/// pastes in and that never expires. Microsoft retired password sign-in, so
/// its accounts go out to Microsoft, come back with a token, and the app
/// refreshes that token from then on. The form below is therefore the same
/// shape with a different second half.
///
/// "Microsoft" covers both a personal Outlook.com mailbox and a work or
/// school one on Microsoft 365. They take the same path here — same sign-in,
/// same servers, same token handling — so the screen does not ask which. A
/// work mailbox may still be refused, but by its own organisation rather than
/// by anything this screen could have asked about: IMAP switched off, SMTP
/// submission switched off, or an administrator who has to approve the app
/// before anyone in the organisation may consent to it. All three surface as
/// errors on the way in, which is the only place they can be found out.
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

  MailProvider _provider = MailProvider.gmail;
  bool _busy = false;
  bool _showPassword = false;
  ProblemReport? _problem;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _emailText => _email.text.trim();

  String get _displayName => _name.text.trim().isEmpty
      ? _emailText.split('@').first
      : _name.text.trim();

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    switch (_provider) {
      case MailProvider.gmail:
        await _run(() => ref.read(accountsProvider.notifier).add(
              displayName: _displayName,
              emailAddress: _emailText,
              provider: MailProvider.gmail,
              // Google shows app passwords with spaces; they are not part of
              // it.
              secret: _password.text.replaceAll(' ', ''),
            ));
      case MailProvider.outlook:
        await _signInWithMicrosoft();
    }
  }

  Future<void> _signInWithMicrosoft() async {
    // The sheet owns the waiting. It comes back with a token or with nothing,
    // and "nothing" covers both cancelling and failing — the sheet has
    // already shown the reason in the failing case, so there is nothing to
    // report here.
    final token = await MicrosoftSignInScreen.show(context, loginHint: _emailText);
    if (token == null || !mounted) return;

    await _run(() => ref.read(accountsProvider.notifier).addOAuth(
          displayName: _displayName,
          emailAddress: _emailText,
          provider: MailProvider.outlook,
          token: token,
        ));
  }

  /// Run an add, turning whatever it throws into a line on the screen.
  Future<void> _run(Future<Account> Function() add) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await add();
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      setState(() => _problem = ProblemReport(
            doing: 'Adding $_emailText',
            error: e,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The one failure a Microsoft sign-in has that a person cannot diagnose
  /// from the server's wording.
  ///
  /// Signing in as one mailbox while typing another's address produces a
  /// refusal that reads like a bad password, because the XOAUTH2 handshake
  /// sends the typed address next to the token and the server rejects the
  /// pair. Nothing about the message says which half was wrong.
  static const _signInHint =
      'If you signed in successfully, check that the address above is the '
      'same mailbox you signed in as.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOutlook = _provider == MailProvider.outlook;
    final signInConfigured =
        ref.watch(microsoftClientIdProvider).isNotEmpty;
    final canSubmit = !isOutlook || signInConfigured;

    return Scaffold(
      appBar: AppBar(
        title:
            Text(widget.isFirstAccount ? 'Welcome to MyEmail' : 'Add account'),
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
                          'Add an account to get started.',
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 12),
                        // Offered here because there is nowhere else it could
                        // be. A new device has no accounts, so the shell shows
                        // this screen instead of the app, and Settings cannot
                        // be reached at all until one exists — leaving someone
                        // holding a backup with no way to use it.
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const BackupScreen(
                                        isFirstRun: true,
                                      ),
                                    ),
                                  ),
                          icon: const Icon(Icons.restore),
                          label: const Text('Restore from a backup'),
                        ),
                        const SizedBox(height: 20),
                      ],
                      _ProviderChoice(
                        value: _provider,
                        enabled: !_busy,
                        onChanged: (p) => setState(() {
                          _provider = p;
                          _problem = null;
                        }),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _email,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: isOutlook
                              ? 'Outlook or Microsoft 365 address'
                              : 'Gmail address',
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
                      if (!isOutlook) ...[
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
                              onPressed: () => setState(
                                  () => _showPassword = !_showPassword),
                            ),
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter the app password.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: 'Name in the folder list (optional)',
                          hintText: 'Personal',
                        ),
                      ),
                      if (isOutlook && !signInConfigured) ...[
                        const SizedBox(height: 16),
                        const _NotConfiguredNotice(),
                      ],
                      if (_problem != null) ...[
                        const SizedBox(height: 16),
                        ProblemView(problem: _problem!),
                        if (_provider == MailProvider.outlook)
                          Text(
                            _signInHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: (_busy || !canSubmit) ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(isOutlook
                                ? 'Sign in with Microsoft'
                                : 'Sign in'),
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

class _ProviderChoice extends StatelessWidget {
  const _ProviderChoice({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final MailProvider value;
  final bool enabled;
  final ValueChanged<MailProvider> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<MailProvider>(
        segments: const [
          ButtonSegment(
            value: MailProvider.gmail,
            label: Text('Gmail'),
            icon: Icon(Icons.mail_outline),
          ),
          ButtonSegment(
            value: MailProvider.outlook,
            label: Text('Outlook'),
            icon: Icon(Icons.alternate_email),
          ),
        ],
        selected: {value},
        onSelectionChanged:
            enabled ? (selection) => onChanged(selection.first) : null,
      );
}

/// Shown when the build has no Microsoft app registration behind it.
///
/// Without a client ID the sign-in cannot even start, and the failure would
/// otherwise arrive as an unhelpful error from Microsoft after a round trip.
/// Saying so before the button is pressed is both faster and honest.
class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'This build has no Microsoft app registration, so Microsoft sign-in '
        'is not available yet. See docs/microsoft-app-registration.md, which '
        'produces the one value this needs.',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
