import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/google_oauth.dart';
import 'package:myemail/data/auth/oauth_redirects.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/accounts/add_account_screen.dart';
import 'package:myemail/ui/accounts/google_sign_in_screen.dart';
import 'package:myemail/ui/settings/edit_account_screen.dart';

/// Signing in to Google from the app: the browser opens, the redirect comes
/// back, and the account is added or signed in again as whoever Google says.
void main() {
  const clientId = '1234-abcd.apps.googleusercontent.com';
  const scheme = 'com.googleusercontent.apps.1234-abcd';

  String idToken(Map<String, Object?> claims) =>
      'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

  late List<Uri> opened;
  late OAuthRedirects redirects;
  late String signedInEmail;

  setUp(() {
    opened = [];
    signedInEmail = 'personal@example.com';
    // A channel of its own per test, so handlers do not pile up on the real
    // one across tests.
    redirects = OAuthRedirects(
      channel: const MethodChannel('mailtree/oauth-under-test'),
    );
  });

  /// A Google that redeems any code for a token naming [signedInEmail].
  GoogleOAuth google() => GoogleOAuth(
        clientId: clientId,
        httpClient: http_testing.MockClient((request) async {
          final form = Uri.splitQueryString(request.body);
          if (form['grant_type'] != 'authorization_code') {
            return http.Response('{"error":"invalid_grant"}', 400);
          }
          return http.Response(
            jsonEncode({
              'access_token': 'ya29.${form['code']}',
              'refresh_token': '1//r',
              'expires_in': 3600,
              'id_token': idToken({'sub': '1', 'email': signedInEmail}),
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

  Widget app(Widget home, {String configuredClientId = clientId}) =>
      ProviderScope(
        overrides: [
          googleClientIdProvider.overrideWithValue(configuredClientId),
          googleOAuthProvider.overrideWithValue(google()),
          oauthRedirectsProvider.overrideWithValue(redirects),
          openInBrowserProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
        child: MaterialApp(home: home),
      );

  /// A few frames, rather than settling: the screen shows a spinner for as
  /// long as it waits for the browser, and a spinner never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// What the browser does when the person is done: Android hands the app
  /// the redirect, with the state the request carried.
  void comeBack(WidgetTester tester, {String? state, String? error}) {
    final requested = opened.last.queryParameters['state']!;
    redirects.deliver(Uri.parse(
      error == null
          ? '$scheme:/oauth2redirect?code=c-1&state=${state ?? requested}'
          : '$scheme:/oauth2redirect?error=$error&state=${state ?? requested}',
    ));
  }

  group('the sign-in screen', () {
    /// A host with a button that opens the screen and keeps its answer.
    GoogleSignIn? result;
    var shown = false;
    Widget host() => Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                shown = true;
                result = await GoogleSignInScreen.show(context);
              },
              child: const Text('go'),
            ),
          ),
        );

    setUp(() {
      result = null;
      shown = false;
    });

    testWidgets('opens the page in the browser, and waits', (tester) async {
      await tester.pumpWidget(app(host()));
      await tester.tap(find.text('go'));
      await settle(tester);

      expect(shown, isTrue);
      expect(opened, hasLength(1));
      expect(opened.single.host, 'accounts.google.com');
      expect(opened.single.queryParameters['client_id'], clientId);
      expect(find.textContaining('opened in your browser'), findsOneWidget);
      expect(find.textContaining('not verified'), findsOneWidget,
          reason: 'the warning is explained before it is met');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the redirect finishes it, with the token and the account',
        (tester) async {
      await tester.pumpWidget(app(host()));
      await tester.tap(find.text('go'));
      await settle(tester);

      comeBack(tester);
      await settle(tester);

      expect(find.byType(GoogleSignInScreen), findsNothing);
      expect(result?.token.accessToken, 'ya29.c-1');
      expect(result?.identity?.email, 'personal@example.com');
    });

    testWidgets('a redirect from some other request is refused',
        (tester) async {
      await tester.pumpWidget(app(host()));
      await tester.tap(find.text('go'));
      await settle(tester);

      comeBack(tester, state: 'not-ours');
      await settle(tester);

      expect(find.byType(GoogleSignInScreen), findsOneWidget);
      expect(find.textContaining('did not match'), findsOneWidget);
      expect(result, isNull);
    });

    testWidgets('a refusal is shown, and Try again opens the page again',
        (tester) async {
      await tester.pumpWidget(app(host()));
      await tester.tap(find.text('go'));
      await settle(tester);

      comeBack(tester, error: 'access_denied');
      await settle(tester);
      expect(find.textContaining('did not grant access'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(opened, hasLength(2));
      expect(
        opened[1].queryParameters['state'],
        isNot(opened[0].queryParameters['state']),
        reason: 'a new request, so the old redirect cannot finish it',
      );
    });

    testWidgets('the page can be opened again without a new request',
        (tester) async {
      await tester.pumpWidget(app(host()));
      await tester.tap(find.text('go'));
      await settle(tester);

      await tester.tap(find.text('Open the page again'));
      await settle(tester);

      expect(opened, hasLength(2));
      expect(opened[1], opened[0]);
    });
  });

  group('adding a Gmail account', () {
    testWidgets('offers Google sign-in first, and the app password after',
        (tester) async {
      await tester.pumpWidget(app(const AddAccountScreen()));
      await settle(tester);

      final google = tester.getRect(find.text('Sign in with Google'));
      final password = tester.getRect(find.text('App password'));
      expect(google.top, lessThan(password.top));
      expect(find.text('Sign in'), findsOneWidget,
          reason: 'the app-password way is still there');
    });

    testWidgets('with no Google registration, only the app password',
        (tester) async {
      await tester.pumpWidget(
        app(const AddAccountScreen(), configuredClientId: ''),
      );
      await settle(tester);

      expect(find.text('Sign in with Google'), findsNothing);
      expect(find.text('App password'), findsOneWidget);
    });

    testWidgets('the sign-in says which account, so nothing need be typed',
        (tester) async {
      signedInEmail = 'new.person@gmail.com';
      final scope = ProviderScope(
        overrides: [
          googleClientIdProvider.overrideWithValue(clientId),
          googleOAuthProvider.overrideWithValue(google()),
          oauthRedirectsProvider.overrideWithValue(redirects),
          openInBrowserProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
        child: const MaterialApp(home: AddAccountScreen()),
      );
      await tester.pumpWidget(scope);
      await settle(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AddAccountScreen)),
      );

      await tester.tap(find.text('Sign in with Google'));
      await settle(tester);
      comeBack(tester);
      await settle(tester);

      final accounts = container.read(accountsProvider).value!;
      final added =
          accounts.where((a) => a.emailAddress == 'new.person@gmail.com');
      expect(added, hasLength(1));
      expect(added.single.provider, MailProvider.gmail);
      expect(added.single.authMethod, AuthMethod.oauth);
      expect(added.single.displayName, 'new.person',
          reason: 'named after the address when no name was given');
    });

    testWidgets('an address typed has to be the one that signed in',
        (tester) async {
      signedInEmail = 'other@gmail.com';
      await tester.pumpWidget(app(const AddAccountScreen()));
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Gmail address'),
        'typed@gmail.com',
      );

      await tester.tap(find.text('Sign in with Google'));
      await settle(tester);
      comeBack(tester);
      await settle(tester);

      expect(find.textContaining('other@gmail.com'), findsOneWidget);
      expect(find.byType(AddAccountScreen), findsOneWidget);
    });
  });

  group('an account that has an app password', () {
    const account = Account(
      id: 'acct-personal',
      displayName: 'Personal',
      emailAddress: 'personal@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    );

    testWidgets('can switch to Google sign-in, keeping the account',
        (tester) async {
      await tester.pumpWidget(app(const EditAccountScreen(account: account)));
      await settle(tester);
      expect(find.text('An app password'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Sign in with Google'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Sign in with Google'));
      await settle(tester);
      comeBack(tester);
      await settle(tester);

      expect(find.text('Google sign-in'), findsOneWidget);
      expect(find.text('An app password'), findsNothing);
      expect(find.textContaining('Signed in.'), findsOneWidget);
    });

    testWidgets('but not as somebody else', (tester) async {
      signedInEmail = 'somebody.else@gmail.com';
      await tester.pumpWidget(app(const EditAccountScreen(account: account)));
      await settle(tester);

      await tester.scrollUntilVisible(find.text('Sign in with Google'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Sign in with Google'));
      await settle(tester);
      comeBack(tester);
      await settle(tester);

      expect(find.textContaining('somebody.else@gmail.com'), findsOneWidget);
      // The record, not the screen: the field saying so has scrolled away.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EditAccountScreen)),
      );
      final now = container
          .read(accountsProvider)
          .value!
          .firstWhere((a) => a.id == account.id);
      expect(now.authMethod, AuthMethod.appPassword, reason: 'nothing changed');
    });
  });
}
