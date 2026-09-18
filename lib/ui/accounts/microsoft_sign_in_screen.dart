import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/auth/oauth_token.dart';
import '../../data/auth/pkce.dart';
import '../../state/providers.dart';
import 'microsoft_sign_in_sheet.dart';

/// Signing in to Microsoft on a real Microsoft page, shown inside the app.
///
/// Authorization code flow with PKCE. The page is Microsoft's own, served over
/// https; the app only watches for the browser trying to follow the redirect,
/// takes the code out of it, and redeems that code with a verifier that never
/// went near the browser.
///
/// This replaced the device code flow as the way in. Microsoft's security
/// defaults block device code sign-ins outright — and from 1 July 2026 every
/// new tenant has them on — which surfaces as AADSTS530035 and says nothing
/// about the flow being at fault. The code flow is not blocked. The device
/// flow is still reachable from here, because the two fail under different
/// conditions: this one needs the embedded browser to work, and a tenant that
/// insists on a managed browser can refuse it.
class MicrosoftSignInScreen extends ConsumerStatefulWidget {
  const MicrosoftSignInScreen({super.key, this.loginHint});

  /// The address already typed on the add-account screen, so Microsoft does
  /// not ask for it a second time.
  final String? loginHint;

  /// Returns the token, or null if the person backed out or it failed.
  static Future<OAuthToken?> show(BuildContext context, {String? loginHint}) =>
      Navigator.of(context).push<OAuthToken>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => MicrosoftSignInScreen(loginHint: loginHint),
        ),
      );

  @override
  ConsumerState<MicrosoftSignInScreen> createState() =>
      _MicrosoftSignInScreenState();
}

class _MicrosoftSignInScreenState extends ConsumerState<MicrosoftSignInScreen> {
  WebViewController? _controller;
  String? _error;
  bool _loading = true;

  /// Sign-in happens twice, and this says which round is on screen.
  ///
  /// An access token is issued for one resource, and Microsoft refuses a
  /// request that mixes `outlook.office.com` with `graph.microsoft.com`.
  /// Reading needs the first and sending needs the second, so consent has to
  /// be collected for both. The second round is usually a single tap — the
  /// browser is already signed in — and after it, one refresh token can be
  /// exchanged for either resource.
  _Round _round = _Round.mailbox;

  /// What the first round produced, held while the second runs.
  OAuthToken? _mailboxToken;

  /// Guards against the redirect being handled twice. The browser can fire a
  /// navigation request more than once for the same URL, and redeeming an
  /// authorization code twice fails the second time — which would replace a
  /// successful sign-in with an error.
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  /// Finish, keeping the right half of each round.
  ///
  /// The access token comes from the first round, because that is the one the
  /// mailbox is read with. The refresh token comes from the second, because
  /// Microsoft rotates it on every exchange and the older one is retired.
  void _finish() {
    final token = _mailboxToken;
    if (token == null || !mounted) return;
    Navigator.of(context).pop(token);
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _loading = true;
    });

    final oauth = ref.read(microsoftOAuthProvider);
    final pkce = await PkcePair.generate();
    final state = newOAuthState();
    if (!mounted) return;

    final scopes = _round == _Round.mailbox
        ? MicrosoftOAuth.scopes
        : MicrosoftOAuth.graphScopes;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // Only the main page failing matters. A blocked tracker or a
            // missing image would otherwise abort a sign-in that is fine.
            if (!error.isForMainFrame!) return;
            if (mounted && !_handled) {
              setState(() {
                _loading = false;
                _error = 'Could not reach the Microsoft sign-in page. '
                    '${error.description}';
              });
            }
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.navigate;

            final String? code;
            try {
              code = oauth.codeFromRedirect(uri, expectedState: state);
            } catch (e) {
              _finishWithError(e);
              return NavigationDecision.prevent;
            }
            if (code == null) return NavigationDecision.navigate;

            if (_handled) return NavigationDecision.prevent;
            _handled = true;
            unawaited(_redeem(oauth, code, pkce));
            return NavigationDecision.prevent;
          },
        ),
      );

    // Start from a clean session for the first round only. Otherwise adding a
    // second mailbox silently reuses the first one's cookies and signs in the
    // wrong account, with nothing on screen to say so. Clearing between the
    // two rounds would undo that round's sign-in and ask for the password
    // again, for the same account, seconds apart.
    if (_round == _Round.mailbox) {
      await WebViewCookieManager().clearCookies();
      await controller.clearCache();
    }
    await controller.loadRequest(
      oauth.authorizationUrl(
        pkce: pkce,
        state: state,
        loginHint: widget.loginHint,
        scopes: scopes,
      ),
    );
    if (!mounted) return;
    setState(() => _controller = controller);
  }

  Future<void> _redeem(
    MicrosoftOAuth oauth,
    String code,
    PkcePair pkce,
  ) async {
    if (mounted) setState(() => _loading = true);
    final OAuthToken token;
    try {
      token = await oauth.exchangeCode(code: code, pkce: pkce);
    } catch (e) {
      _finishWithError(e);
      return;
    }
    if (!mounted) return;

    switch (_round) {
      case _Round.mailbox:
        _mailboxToken = token;
        setState(() {
          _round = _Round.sending;
          _handled = false;
        });
        await _start();
      case _Round.sending:
        // Keep the newer refresh token; the access token stays the mailbox
        // one, because that is what the IMAP connection is opened with.
        _mailboxToken = _mailboxToken?.withRefreshToken(token.refreshToken);
        _finish();
    }
  }

  void _finishWithError(Object e) {
    if (!mounted) return;

    // Permission to send refused, with the mailbox already granted. Better to
    // finish with an account that can read than to throw the sign-in away:
    // the send path says what is missing if and when a message is actually
    // sent, and Settings can ask for it again.
    if (_round == _Round.sending && _mailboxToken != null) {
      _finish();
      return;
    }

    setState(() {
      _loading = false;
      _error = switch (e) {
        SignInFailed(:final message) => message,
        SignInDeclined(:final message) => message,
        SignInExpired(:final message) => message,
        SignInTimedOut(:final message) => message,
        _ => 'Sign-in failed: $e',
      };
    });
  }

  /// The other flow, for when the embedded browser is the problem.
  Future<void> _useACodeInstead() async {
    final token = await MicrosoftSignInSheet.show(context);
    if (token == null || !mounted) return;
    Navigator.of(context).pop(token);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_round) {
          _Round.mailbox => 'Sign in to Microsoft',
          // Named, because a second consent screen moments after the first
          // looks like the first one having failed.
          _Round.sending => 'One more: permission to send',
        }),
        centerTitle: false,
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _error != null
          ? _Failure(
              message: _error!,
              onRetry: _start,
              onUseACode: _useACodeInstead,
            )
          : controller == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(child: WebViewWidget(controller: controller)),
                    // Said quietly, but said. The page is Microsoft's own and
                    // served over https, and someone typing a work password
                    // into a window inside another app is entitled to know
                    // which they are looking at.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'login.microsoftonline.com',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _useACodeInstead,
                            child: const Text('Use a code instead'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// The two consent rounds a Microsoft sign-in needs. See [_Round] usage in
/// the state class for why there are two.
enum _Round { mailbox, sending }

class _Failure extends StatelessWidget {
  const _Failure({
    required this.message,
    required this.onRetry,
    required this.onUseACode,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onUseACode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                message,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: onUseACode,
                child: const Text('Use a code instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
