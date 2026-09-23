import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/accounts/microsoft_sign_in_screen.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fakes/fake_webview.dart';

/// The in-app Microsoft sign-in, driven through its browser.
void main() {
  late FakeWebViewPlatform web;
  setUp(() => web = FakeWebViewPlatform.install());

  testWidgets('a second try after a failed one goes through', (tester) async {
    // The first code could not be redeemed (the connection dropped). After
    // Try again the second redirect was taken for a repeat of the first and
    // dropped, and the screen sat on Microsoft's page for good.
    var redeemed = 0;
    final oauth = MicrosoftOAuth(
      clientId: 'test-client',
      authority: 'https://login.example/common/oauth2/v2.0',
      httpClient: http_testing.MockClient((request) async {
        redeemed++;
        if (redeemed == 1) throw http.ClientException('connection dropped');
        return http.Response(
          jsonEncode({
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_in': 3600,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );
    OAuthToken? result;
    var finished = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [microsoftOAuthProvider.overrideWithValue(oauth)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await MicrosoftSignInScreen.show(context);
              finished = true;
            },
            child: const Text('sign in'),
          ),
        ),
      ),
    ));
    // Not pumpAndSettle: the page never reports it has finished loading
    // here, so the progress bar would run for ever.
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.tap(find.text('sign in'));
    await settle();

    Future<void> redirect() async {
      final state = web.loadedUrls.last.queryParameters['state'];
      await web.navigationHandler!(NavigationRequest(
        url: '${MicrosoftOAuth.redirectUri}?code=the-code&state=$state',
        isMainFrame: true,
      ));
      await settle();
    }

    await redirect();
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await settle();
    await redirect();

    expect(finished, isTrue);
    expect(result?.accessToken, 'access');
  });
}
