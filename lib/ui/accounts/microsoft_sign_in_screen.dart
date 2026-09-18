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
///
/// One consent screen, not two. There were briefly two, because reading went
/// over IMAP and sending over Graph, and an access token is issued for one
/// resource at a time. Everything is Graph now, so there is one resource and
/// one screen.
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

  Future<void> _start() async {
    setState(() {
      _error = null;
      _loading = true;
    });

    final oauth = ref.read(microsoftOAuthProvider);
    final pkce = await PkcePair.generate();
    final state = newOAuthState();
    if (!mounted) return;

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

    // Start from a clean session. Otherwise adding a second mailbox silently
    // reuses the first one's cookies and signs in the wrong account, with
    // nothing on screen to say so.
    await WebViewCookieManager().clearCookies();
    await controller.clearCache();
    await controller.loadRequest(
      oauth.authorizationUrl(
        pkce: pkce,
        state: state,
        loginHint: widget.loginHint,
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
    try {
      final token = await oauth.exchangeCode(code: code, pkce: pkce);
      if (!mounted) return;
      Navigator.of(context).pop(token);
    } catch (e) {
      _finishWithError(e);
    }
  }

  void _finishWithError(Object e) {
    if (!mounted) return;
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
        title: const Text('Sign in to Microsoft'),
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
