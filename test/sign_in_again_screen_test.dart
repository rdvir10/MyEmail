import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/common/problem_view.dart';
import 'package:myemail/ui/settings/edit_account_screen.dart';

import 'fakes/fake_imap_transport.dart';

/// "Sign in again", from the button down. The engine's half had tests; the
/// screen's, and what it tells the rest of the app, had none.
void main() {
  late FakeImapTransport server;
  late MemoryCredentialStore credentials;
  late CachedImapEngine engine;

  setUp(() {
    server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
    credentials = MemoryCredentialStore();
    engine = CachedImapEngine(
      accountStore: MemoryAccountStore(),
      credentialStore: credentials,
      cache: MemoryCacheStore(),
      transportFactory: (_, _) => server,
    );
  });

  Future<Account> add() => engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'oldoldoldoldold1',
      );

  group('the edit screen', () {
    Future<void> open(WidgetTester tester, Account account) async {
      // Tall enough that the sign-in section is built without scrolling.
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          mailEngineProvider.overrideWithValue(engine),
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        ],
        child: MaterialApp(home: EditAccountScreen(account: account)),
      ));
      await tester.pumpAndSettle();
    }

    Finder password() => find.ancestor(
          of: find.text('New app password'),
          matching: find.byType(TextField),
        );

    Future<void> checkAndSave(WidgetTester tester, String typed) async {
      await tester.enterText(password(), typed);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Check and save'));
      await tester.pumpAndSettle();
    }

    testWidgets('a new app password is checked and kept without its spaces',
        (tester) async {
      // Google shows it in groups of four; the spaces are not part of it.
      final account = (await tester.runAsync(add))!;
      await open(tester, account);

      await checkAndSave(tester, 'abcd efgh ijkl mnop');

      final stored =
          await tester.runAsync(() => credentials.readSecret(account.id));
      expect(stored, 'abcdefghijklmnop');
      expect(find.text('Signed in. Nothing cached was lost.'), findsOneWidget);
      expect(tester.widget<TextField>(password()).controller!.text, isEmpty,
          reason: 'a password left on screen is one more place it can be read');
    });

    testWidgets('a refused one says why and keeps the one that was there',
        (tester) async {
      final account = (await tester.runAsync(add))!;
      await open(tester, account);
      server.failWith = const AuthenticationFailed('Gmail refused it.');

      await checkAndSave(tester, 'wrongwrongwrong1');

      expect(find.byType(ProblemView), findsOneWidget);
      expect(find.text('Signed in. Nothing cached was lost.'), findsNothing);
      final stored =
          await tester.runAsync(() => credentials.readSecret(account.id));
      expect(stored, 'oldoldoldoldold1');
    });

    testWidgets("signing in again clears the account's trouble in the tree",
        (tester) async {
      // Or the tree went on saying "Sign in again" under an account that
      // just had, until the app was restarted.
      final account = (await tester.runAsync(add))!;
      server.failWith = const AuthenticationFailed('Gmail refused it.');
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ]);
      addTearDown(c.dispose);
      c.listen(foldersProvider, (_, _) {});
      await tester.runAsync(() => c.read(foldersProvider.future));
      expect(c.read(folderLoadErrorsProvider), contains(account.id));
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: EditAccountScreen(account: account)),
      ));
      await tester.pumpAndSettle();
      server.failWith = null;

      await checkAndSave(tester, 'abcd efgh ijkl mnop');
      await tester.runAsync(() => c.read(foldersProvider.future));
      await tester.pumpAndSettle();

      expect(find.text('Signed in. Nothing cached was lost.'), findsOneWidget);
      expect(c.read(folderLoadErrorsProvider), isNot(contains(account.id)));
    });
  });

  test('with neither a password nor a token nothing is changed', () async {
    final account = await add();
    final c = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(c.dispose);

    await expectLater(
      c.read(accountsProvider.notifier).signInAgain(accountId: account.id),
      throwsArgumentError,
    );
    expect(await credentials.readSecret(account.id), 'oldoldoldoldold1');
  });
}
