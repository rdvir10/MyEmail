import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/accounts/add_account_screen.dart';
import 'package:myemail/ui/accounts/microsoft_sign_in_sheet.dart';

/// The two screens a person meets when adding a Microsoft account, personal
/// or work.
void main() {
  /// A Microsoft that hands out a code and then never answers, which is what
  /// the sheet looks like for the whole time it matters.
  ///
  /// The sleep never completes on purpose. An instant one turns the poll loop
  /// into a tight cycle of microtasks that starves the test binding, and the
  /// test hangs rather than failing. Parking in the wait is also the more
  /// honest fake: a real client is asleep between polls, not spinning.
  MicrosoftOAuth waitingForever() => MicrosoftOAuth(
        clientId: 'test-client-id',
        authority: 'https://login.example/consumers/oauth2/v2.0',
        sleep: (_) => Completer<void>().future,
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path.endsWith('devicecode')) {
            return http.Response(
              jsonEncode({
                'device_code': 'dev-code',
                'user_code': 'HTSK-MNQP',
                'verification_uri': 'https://microsoft.com/devicelogin',
                'expires_in': 900,
                'interval': 300,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({'error': 'authorization_pending'}),
            400,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

  Widget app({
    required Widget home,
    String clientId = 'test-client-id',
    MicrosoftOAuth? oauth,
  }) =>
      ProviderScope(
        overrides: [
          microsoftClientIdProvider.overrideWithValue(clientId),
          if (oauth != null) microsoftOAuthProvider.overrideWithValue(oauth),
        ],
        child: MaterialApp(home: home),
      );

  group('choosing a provider', () {
    testWidgets('Gmail asks for an app password', (tester) async {
      await tester.pumpWidget(app(home: const AddAccountScreen()));

      expect(find.text('App password'), findsOneWidget);
      expect(find.text('Gmail address'), findsOneWidget);
    });

    testWidgets('Microsoft asks for no password at all', (tester) async {
      // There is nothing to type: Microsoft retired password sign-in, so
      // leaving the field on screen would invite people to enter a password
      // that cannot work.
      await tester.pumpWidget(app(home: const AddAccountScreen()));

      await tester.tap(find.text('Outlook'));
      await tester.pumpAndSettle();

      expect(find.text('App password'), findsNothing);
      expect(find.text('Sign in with Microsoft'), findsOneWidget);
    });

    testWidgets('the address field names work mailboxes too', (tester) async {
      // The same path serves a personal Outlook.com mailbox and a work one on
      // Microsoft 365, and a field labelled "Outlook.com address" reads as a
      // refusal of the second.
      await tester.pumpWidget(app(home: const AddAccountScreen()));

      await tester.tap(find.text('Outlook'));
      await tester.pumpAndSettle();

      expect(find.text('Outlook or Microsoft 365 address'), findsOneWidget);
    });

    testWidgets('an unconfigured build says so instead of failing later',
        (tester) async {
      await tester.pumpWidget(
        app(home: const AddAccountScreen(), clientId: ''),
      );

      await tester.tap(find.text('Outlook'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no Microsoft app registration'),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Sign in with Microsoft'),
      );
      expect(button.onPressed, isNull,
          reason: 'pressing it could only produce an error from Microsoft');
    });

    testWidgets('a configured build lets the sign-in start', (tester) async {
      await tester.pumpWidget(app(home: const AddAccountScreen()));

      await tester.tap(find.text('Outlook'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no Microsoft app registration'), findsNothing);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Sign in with Microsoft'),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('the sign-in sheet', () {
    testWidgets('shows the code and where to enter it', (tester) async {
      await tester.pumpWidget(
        app(home: const MicrosoftSignInSheet(), oauth: waitingForever()),
      );
      await tester.pump();

      expect(find.text('HTSK-MNQP'), findsOneWidget);
      expect(find.text('https://microsoft.com/devicelogin'), findsOneWidget);
    });

    testWidgets('keeps the code on screen while it waits', (tester) async {
      // The waiting is the point. A spinner that replaced the code would mean
      // anyone who looked away had to start again.
      await tester.pumpWidget(
        app(home: const MicrosoftSignInSheet(), oauth: waitingForever()),
      );
      await tester.pump();

      expect(find.text('Waiting for you to finish'), findsOneWidget);
      expect(find.text('HTSK-MNQP'), findsOneWidget);
    });

    testWidgets('a browser that will not open leaves the code on screen',
        (tester) async {
      // The code was replaced by a message saying to enter the code, and
      // its Try again started a second code over a wait still running.
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(launcher, (_) async => false);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(launcher, null));
      await tester.pumpWidget(
        app(home: const MicrosoftSignInSheet(), oauth: waitingForever()),
      );
      await tester.pump();

      await tester.tap(find.text('Open the sign-in page'));
      await tester.pump();

      expect(find.text('HTSK-MNQP'), findsOneWidget);
      expect(find.text('Waiting for you to finish'), findsOneWidget);
      expect(find.textContaining('Could not open a browser'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a failure explains itself and offers another go',
        (tester) async {
      final refusing = MicrosoftOAuth(
        clientId: 'test-client-id',
        authority: 'https://login.example/consumers/oauth2/v2.0',
        sleep: (_) async {},
        httpClient: http_testing.MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': 'invalid_client',
              'error_description':
                  'AADSTS7000218: The request body must contain the following '
                      'parameter: client_assertion or client_secret.',
            }),
            400,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      );

      await tester.pumpWidget(
        app(home: const MicrosoftSignInSheet(), oauth: refusing),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Allow public client flows'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
