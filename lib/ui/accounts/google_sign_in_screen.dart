import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/google_oauth.dart';
import '../../data/auth/loopback_redirect.dart';
import '../../data/auth/microsoft_oauth.dart'
    show SignInDeclined, SignInExpired, SignInFailed, SignInNeedsConsent;
import '../../data/auth/pkce.dart';
import '../../state/providers.dart';

/// Signing in to Google, in the phone's own browser.
///
/// Google will not sign anyone in inside an app's WebView, so unlike the
/// Microsoft screen this one shows no page of its own. It opens Google's
/// sign-in page in the browser, as a tab over the app, and waits: when the
/// person is done, the browser follows the redirect to the app's own
/// loopback address, where [LoopbackRedirect] is listening for the length
/// of the sign-in, and the app brings itself back in front of the tab.
/// (The custom URI scheme, which Android would hand the app through
/// [OAuthRedirects], is taken too, for the day Google allows it on the
/// Android client.) The code is redeemed with the PKCE verifier, which
/// never left the app.
///
/// While the app is unverified with Google, the page warns that it is. That
/// is said here before the browser opens, with what to tap, because the
/// warning is worded to send people away.
class GoogleSignInScreen extends ConsumerStatefulWidget {
  const GoogleSignInScreen({super.key, this.loginHint});

  /// An address already typed, so Google preselects that account.
  final String? loginHint;

  /// Returns what the sign-in came back with, or null if the person backed
  /// out or it failed (the screen has shown the failure).
  static Future<GoogleSignIn?> show(BuildContext context, {String? loginHint}) =>
      Navigator.of(context).push<GoogleSignIn>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => GoogleSignInScreen(loginHint: loginHint),
        ),
      );

  @override
  ConsumerState<GoogleSignInScreen> createState() => _GoogleSignInScreenState();
}

class _GoogleSignInScreenState extends ConsumerState<GoogleSignInScreen> {
  String? _error;

  /// Between the browser opening and the redirect arriving.
  bool _waiting = false;

  /// Between the redirect arriving and Google answering with the token.
  bool _redeeming = false;

  /// This attempt's request, so a redirect is matched to it and not to an
  /// earlier one, and the page can be opened again without a new request.
  PkcePair? _pkce;
  String? _state;
  Uri? _page;

  /// Listening on the loopback address for this attempt's redirect.
  LoopbackRedirect? _loopback;

  /// Guards against the redirect being handled twice. Android can deliver
  /// the same intent more than once, and redeeming a code twice fails the
  /// second time, which would replace a successful sign-in with an error.
  bool _handled = false;

  StreamSubscription<Uri>? _arrivals;

  @override
  void initState() {
    super.initState();
    // Listening before the browser opens: a redirect cannot arrive before
    // the page does, but nothing is lost by being early.
    _arrivals = ref.read(oauthRedirectsProvider).arrivals.listen(_onRedirect);
    unawaited(_start());
  }

  @override
  void dispose() {
    _arrivals?.cancel();
    _loopback?.close();
    super.dispose();
  }

  Future<void> _start() async {
    // A try again is a fresh sign-in, with a request of its own, listening
    // on a port of its own. The old listener is let go without waiting:
    // nothing depends on when it is gone.
    _handled = false;
    unawaited(_loopback?.close());
    _loopback = null;
    final oauth = ref.read(googleOAuthProvider);
    final pkce = await PkcePair.generate();
    final state = newOAuthState();
    final LoopbackRedirect loopback;
    try {
      loopback = await LoopbackRedirect.start();
    } catch (e) {
      _finishWithError(SignInFailed('The app could not listen for the '
          'sign-in to come back. ($e)'));
      return;
    }
    if (!mounted) {
      await loopback.close();
      return;
    }
    unawaited(loopback.arrival.then(_onRedirect, onError: (Object e) {
      if (mounted && !_handled) _finishWithError(e);
    }));
    setState(() {
      _error = null;
      _pkce = pkce;
      _state = state;
      _loopback = loopback;
      _page = oauth.authorizationUrl(
        pkce: pkce,
        state: state,
        loginHint: widget.loginHint,
        redirectUri: loopback.redirectUri,
      );
    });
    await _openPage();
  }

  Future<void> _openPage() async {
    final page = _page;
    if (page == null) return;
    setState(() => _waiting = true);
    final opened = await ref.read(openInBrowserProvider)(page);
    if (!mounted) return;
    if (!opened) {
      setState(() {
        _waiting = false;
        _error = 'No browser could be opened to sign in with.';
      });
    }
  }

  void _onRedirect(Uri uri) {
    final oauth = ref.read(googleOAuthProvider);
    final state = _state;
    final pkce = _pkce;
    if (state == null || pkce == null || _handled) return;

    // The loopback address of this attempt, or the custom scheme; the code
    // is redeemed against whichever the browser came back by.
    final loopbackUri = _loopback?.redirectUri;
    final String? code;
    final String? redirectUri;
    try {
      final byLoopback = loopbackUri == null
          ? null
          : oauth.codeFromRedirect(
              uri,
              expectedState: state,
              redirectUri: loopbackUri,
            );
      if (byLoopback != null) {
        code = byLoopback;
        redirectUri = loopbackUri;
      } else {
        code = oauth.codeFromRedirect(uri, expectedState: state);
        redirectUri = null;
      }
    } catch (e) {
      _finishWithError(e);
      return;
    }
    if (code == null) return;

    _handled = true;
    // The tab is still on top, showing "signed in"; the app comes back in
    // front of it while the code is being redeemed.
    unawaited(ref.read(oauthRedirectsProvider).bringAppToFront());
    unawaited(_redeem(oauth, code, pkce, redirectUri: redirectUri));
  }

  Future<void> _redeem(
    GoogleOAuth oauth,
    String code,
    PkcePair pkce, {
    String? redirectUri,
  }) async {
    if (mounted) {
      setState(() {
        _waiting = false;
        _redeeming = true;
      });
    }
    try {
      final result = await oauth.exchangeCode(
        code: code,
        pkce: pkce,
        redirectUri: redirectUri,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      _finishWithError(e);
    }
  }

  void _finishWithError(Object e) {
    if (!mounted) return;
    setState(() {
      _waiting = false;
      _redeeming = false;
      _error = switch (e) {
        SignInFailed(:final message) => message,
        SignInDeclined(:final message) => message,
        SignInExpired(:final message) => message,
        SignInNeedsConsent(:final message) => message,
        _ => 'Sign-in failed: $e',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in with Google'),
        centerTitle: false,
        bottom: _redeeming
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _start,
                    child: const Text('Try again'),
                  ),
                ] else ...[
                  Icon(
                    Icons.open_in_browser,
                    size: 40,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _redeeming
                        ? 'Finishing the sign-in…'
                        : 'Google\'s sign-in page has opened in your browser. '
                            'Choose the account and allow MyEmail, and you '
                            'will be brought back here.',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Google may say the app is not verified. That is because '
                    'MyEmail is not published in its app store; tap Advanced, '
                    'then "Go to MyEmail".',
                    style: muted,
                  ),
                  const SizedBox(height: 24),
                  if (_waiting) ...[
                    const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  OutlinedButton.icon(
                    onPressed: _redeeming ? null : _openPage,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Open the page again'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
