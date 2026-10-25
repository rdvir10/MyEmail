import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_refresher.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/auth/oauth_token_repository.dart';
import 'package:myemail/data/backup/backup_service.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/compose/graph_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/settings_backup.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/accounts_screen.dart';
import 'package:myemail/ui/settings/edit_account_screen.dart';

import 'fakes/fake_imap_transport.dart';

/// Shared mailboxes (#54): a mailbox shared with a Microsoft account, added
/// as an account of its own and reached through that account's sign-in.
void main() {
  const owner = Account(
    id: 'acct-ron',
    displayName: 'Ron',
    emailAddress: 'ron@hadco.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0,
  );
  const shared = Account(
    id: 'acct-info',
    displayName: 'Info',
    emailAddress: 'info@hadco.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0,
    sharedVia: 'acct-ron',
  );

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  group('kept', () {
    test('on the device and in a backup, with the account it is shared '
        'through', () {
      expect(accountFromJson(accountToJson(shared)).sharedVia, 'acct-ron');
      expect(accountFromJson(accountToJson(owner)).sharedVia, isNull);
      expect(accountToJson(owner).containsKey('sharedVia'), isFalse);
      expect(accountFromBackupJson(accountToBackupJson(shared))!.sharedVia,
          'acct-ron');
    });

    test('a restore points it at the account as this device knows it',
        () async {
      final file = SettingsBackup(
        accounts: const [owner, shared],
        entries: const {},
        exportedAt: DateTime.utc(2026, 10, 24),
        appVersion: '2.99.0',
      ).toJsonString();
      // Ron's account is here already, under an id of this device's own.
      final here = MemoryAccountStore(const [
        Account(
          id: 'acct-local',
          displayName: 'Ron',
          emailAddress: 'ron@hadco.example',
          provider: MailProvider.outlook,
          authMethod: AuthMethod.oauth,
          colorValue: 0,
        ),
      ]);
      final report = await BackupService(
        accountStore: here,
        uiState: MemoryUiStateStore(),
      ).import(SettingsBackup.parse(file));

      expect(report.accountsAdded.single.emailAddress, 'info@hadco.example');
      expect(here.read().last.sharedVia, 'acct-local');
    });
  });

  group('on the wire', () {
    test("every path names the shared mailbox, a batch's too", () async {
      final paths = <String>[];
      final batched = <String>[];
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 't',
        mailbox: 'info@hadco.example',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith(r'/$batch')) {
            final body = jsonDecode(request.body) as Map;
            final requests = body['requests'] as List;
            batched.addAll([for (final r in requests) '${(r as Map)['url']}']);
            return json({
              'responses': [
                for (final r in requests)
                  {'id': (r as Map)['id'], 'status': 200, 'body': {}},
              ],
            });
          }
          return json({'value': []});
        }),
      );
      await api.listFolders();
      await api.batch(
          [GraphRequest.read('m1', true), GraphRequest.read('m3', true)]);
      await api.setRead('m2', true);

      expect(paths.first, '/v1.0/users/info%40hadco.example/mailFolders');
      expect(batched, hasLength(2));
      expect(batched.first, startsWith('/users/info%40hadco.example/messages/'));
      expect(paths.last, startsWith('/v1.0/users/info%40hadco.example/messages/'));
      expect(paths.where((p) => p.contains('/me/')), isEmpty);
    });

    test('and its own, still /me', () async {
      final paths = <String>[];
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return json({'value': []});
        }),
      );
      await api.listFolders();
      expect(paths.single, '/v1.0/me/mailFolders');
    });

    test('mail sent from it goes from it', () {
      expect(
        const GraphSender(
          accessToken: _noToken,
          mailbox: 'info@hadco.example',
        ).sendMailUri.path,
        '/v1.0/users/info%40hadco.example/sendMail',
      );
      expect(const GraphSender(accessToken: _noToken).sendMailUri.path,
          '/v1.0/me/sendMail');
    });
  });

  group('the engine', () {
    late FakeImapTransport server;
    late MemoryAccountStore accounts;
    late MemoryCredentialStore secrets;
    late _Refresher refresher;
    late CachedImapEngine engine;
    late List<Account> opened;

    setUp(() async {
      server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
      accounts = MemoryAccountStore(const [owner]);
      secrets = MemoryCredentialStore();
      await secrets.writeSecret(
        owner.id,
        OAuthToken(
          accessToken: 'own',
          refreshToken: 'refresh',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ).toStoredJson(),
      );
      refresher = _Refresher();
      opened = [];
      engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: secrets,
        cache: MemoryCacheStore(),
        oauthTokens: OAuthTokenRepository(
          credentialStore: secrets,
          oauthClient: (_) => refresher,
        ),
        transportFactory: (account, credentials) {
          opened.add(account);
          // The probe asks for a token, as a real transport would.
          if (credentials case OAuthCredentials(:final accessToken)) {
            return _Asking(server, accessToken);
          }
          return server;
        },
      );
    });

    test("added with the owner's token, asked for shared mailboxes by name, "
        'and nothing stored for it', () async {
      final added = await engine.addSharedMailbox(
        viaAccountId: owner.id,
        emailAddress: ' info@hadco.example ',
        displayName: 'Info',
      );
      expect(added.sharedVia, owner.id);
      expect(added.emailAddress, 'info@hadco.example');
      expect(added.provider, MailProvider.outlook);
      expect(accounts.read().map((a) => a.id), [owner.id, added.id]);
      expect(await secrets.readSecret(added.id), isNull);
      expect(refresher.asked.single, MicrosoftOAuth.sharedMailboxScopes);
      expect(engine.serverSettings(added.id), isNull,
          reason: "its settings are its owner's to change");
    });

    test('an owner that has not allowed it reads as needing consent, and '
        'nothing is kept', () async {
      refresher.refuse = const SignInNeedsConsent('Allow it first.');
      await expectLater(
        engine.addSharedMailbox(
          viaAccountId: owner.id,
          emailAddress: 'info@hadco.example',
          displayName: 'Info',
        ),
        throwsA(isA<SignInNeedsConsent>()),
      );
      expect(accounts.read(), [owner]);
    });

    test('a mailbox that will not let it in says so', () async {
      server.failWith = const ConnectionFailed(
          'Microsoft refused the request (ErrorAccessDenied): Access is denied.');
      await expectLater(
        engine.addSharedMailbox(
          viaAccountId: owner.id,
          emailAddress: 'info@hadco.example',
          displayName: 'Info',
        ),
        throwsA(isA<AuthenticationFailed>().having(
            (e) => e.message, 'message', contains('Full Access'))),
      );
      expect(accounts.read(), [owner]);
    });

    test('removing the owner removes it too', () async {
      final added = await engine.addSharedMailbox(
        viaAccountId: owner.id,
        emailAddress: 'info@hadco.example',
        displayName: 'Info',
      );
      await engine.removeAccount(owner.id);
      expect(accounts.read().where((a) => a.id == added.id), isEmpty);
      expect(accounts.read(), isEmpty);
    });
  });

  group('on screen', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      SampleMailEngine engine,
      Widget home,
    ) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: home),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    Future<SampleMailEngine> withMicrosoft(WidgetTester tester) async {
      final engine = SampleMailEngine();
      await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Ron',
            emailAddress: 'ron@hadco.example',
            provider: MailProvider.outlook,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          ));
      return engine;
    }

    testWidgets('Settings, Accounts: Add a shared mailbox, shared with the '
        'Microsoft account', (tester) async {
      final engine = await withMicrosoft(tester);
      final c = await pump(tester, engine, const AccountsScreen());

      await tester.tap(find.byKey(const ValueKey('add-shared-mailbox')));
      await tester.pumpAndSettle();
      expect(find.text('ron@hadco.example'), findsOneWidget,
          reason: 'the only account it can be shared with');
      await tester.enterText(
          find.byKey(const ValueKey('shared-address')), 'info@hadco.example');
      await tester.enterText(find.byKey(const ValueKey('shared-name')), 'Info');
      await tester.tap(find.byKey(const ValueKey('shared-add')));
      await tester.pumpAndSettle();

      final added = c
          .read(accountsProvider)
          .value!
          .singleWhere((a) => a.emailAddress == 'info@hadco.example');
      expect(added.displayName, 'Info');
      expect(added.sharedVia,
          c.read(accountsProvider).value!.singleWhere((a) => a.emailAddress == 'ron@hadco.example').id);
      expect(find.text('Shared, through ron@hadco.example', findRichText: true),
          findsNothing);
      expect(find.textContaining('Shared, through ron@hadco.example'),
          findsOneWidget, reason: 'listed with whose it is');
    });

    testWidgets('not allowed yet offers Allow', (tester) async {
      final engine = await withMicrosoft(tester);
      engine.refuseShared = const SignInNeedsConsent('Allow it first.');
      await pump(tester, engine, const AccountsScreen());
      await tester.tap(find.byKey(const ValueKey('add-shared-mailbox')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('shared-address')), 'info@hadco.example');
      await tester.tap(find.byKey(const ValueKey('shared-add')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shared-allow')), findsOneWidget);
      expect(find.textContaining('Not allowed yet'), findsOneWidget);
    });

    testWidgets('with no Microsoft account it is not offered', (tester) async {
      await pump(tester, SampleMailEngine(), const AccountsScreen());
      expect(find.byKey(const ValueKey('add-shared-mailbox')), findsNothing);
    });

    testWidgets('its own page says whose sign-in reaches it, and offers no '
        'sign-in of its own', (tester) async {
      final engine = await withMicrosoft(tester);
      final c = await pump(tester, engine, const SizedBox());
      final ron =
          (await tester.runAsync(() => c.read(accountsProvider.future)))!.last;
      final info = await tester.runAsync(() => c
          .read(accountsProvider.notifier)
          .addSharedMailbox(
              viaAccountId: ron.id,
              emailAddress: 'info@hadco.example',
              displayName: 'Info'));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: EditAccountScreen(account: info!)),
      ));
      await tester.pumpAndSettle();

      expect(find.text('The sign-in of ron@hadco.example'), findsOneWidget);
      expect(find.text('Sign in with Microsoft'), findsNothing);
      expect(find.textContaining('no sign-in of its own'), findsOneWidget);
    });
  });
}

Future<String> _noToken({bool force = false}) async => 't';

/// Answers every refresh, recording the scopes asked for.
class _Refresher implements OAuthRefresher {
  final asked = <List<String>?>[];
  Exception? refuse;

  @override
  Future<OAuthToken> refresh(OAuthToken token, {List<String>? scopes}) async {
    asked.add(scopes);
    final refusal = refuse;
    if (refusal != null) throw refusal;
    return OAuthToken(
      accessToken: 'shared',
      refreshToken: token.refreshToken,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
  }

  @override
  void close() {}
}

/// The fake server, asking for a token before it lists the folders, as
/// Graph does.
class _Asking extends FakeImapTransport {
  _Asking(this.inner, this.token);

  final FakeImapTransport inner;
  final Future<String> Function({bool force}) token;

  @override
  Future<List<RemoteFolder>> listFolders() async {
    await token();
    return inner.listFolders();
  }

  @override
  Future<void> close() async {}
}
