import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/settings/edit_account_screen.dart';

import 'fakes/fake_imap_transport.dart';

/// Renaming and recolouring an account, and popping a message out full screen.
void main() {
  group('editing an account', () {
    late FakeImapTransport server;
    late MemoryAccountStore accounts;
    late CachedImapEngine engine;

    setUp(() {
      server = FakeImapTransport();
      accounts = MemoryAccountStore();
      engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      server.folder('INBOX', role: FolderRole.inbox);
    });

    Future<Account> add() => engine.addAccount(
          displayName: 'Personal',
          emailAddress: 'me@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );

    test('renaming keeps everything else about the account', () async {
      final account = await add();

      final updated = await engine.updateAccount(
        accountId: account.id,
        displayName: 'Home',
      );

      expect(updated.displayName, 'Home');
      expect(updated.id, account.id, reason: 'the cache is keyed on this');
      expect(updated.emailAddress, 'me@example.com');
      expect(updated.colorValue, account.colorValue);
    });

    test('the change is written, not just returned', () async {
      final account = await add();

      await engine.updateAccount(accountId: account.id, displayName: 'Home');

      expect(accounts.read().single.displayName, 'Home');
    });

    test('recolouring leaves the name alone', () async {
      final account = await add();

      final updated =
          await engine.updateAccount(accountId: account.id, colorValue: 0xFF00838F);

      expect(updated.colorValue, 0xFF00838F);
      expect(updated.displayName, 'Personal');
    });

    test('a blank name is refused rather than stored', () async {
      // An empty name leaves a heading in the folder tree with nothing in it
      // and no way to tell which mailbox it belongs to.
      final account = await add();

      final updated =
          await engine.updateAccount(accountId: account.id, displayName: '   ');

      expect(updated.displayName, 'Personal');
    });

    test('surrounding whitespace is trimmed', () async {
      final account = await add();

      final updated = await engine.updateAccount(
        accountId: account.id,
        displayName: '  Home  ',
      );

      expect(updated.displayName, 'Home');
    });

    test('an unknown account is an error, not a silent no-op', () async {
      await expectLater(
        engine.updateAccount(accountId: 'nope', displayName: 'Home'),
        throwsA(isA<StateError>()),
      );
    });

    test('editing opens no connection, so it works offline', () async {
      final account = await add();
      server.offline = true;

      final updated = await engine.updateAccount(
        accountId: account.id,
        displayName: 'Home',
      );

      expect(updated.displayName, 'Home');
    });
  });

  group('the edit screen', () {
    const account = Account(
      id: 'acct-1',
      displayName: 'Personal',
      emailAddress: 'me@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    );

    Widget app() => const ProviderScope(
          child: MaterialApp(home: EditAccountScreen(account: account)),
        );

    /// The name box specifically. There are two text fields on this screen
    /// now — the other is the new app password — so an unscoped
    /// find.byType(TextField) is ambiguous.
    Finder nameField() => find.ancestor(
          of: find.text('Name in the folder list'),
          matching: find.byType(TextField),
        );

    /// A window tall enough for the whole screen at once.
    ///
    /// Otherwise Save and the sign-in section sit below the fold, where a
    /// lazily built ListView has not created them, and scrollUntilVisible
    /// cannot help: the text fields bring scrollables of their own, so it
    /// cannot tell which one to drive.
    void useTallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('starts from the current name', (tester) async {
      await tester.pumpWidget(app());

      // Two fields carry the name now: the folder-list label holds it, and
      // the sender name offers it as what it falls back to.
      final label = find.ancestor(
        of: find.text('Name in the folder list'),
        matching: find.byType(TextField),
      );
      expect(label, findsOneWidget);
      expect(tester.widget<TextField>(label).controller!.text, 'Personal');
    });

    testWidgets('the sender name is empty until one is chosen',
        (tester) async {
      // Empty rather than pre-filled with the label: the field has to be
      // able to say "nothing chosen here", or clearing it would be the same
      // as typing the label and the fallback could never come back.
      await tester.pumpWidget(app());

      final sender = find.ancestor(
        of: find.text('Name on mail you send'),
        matching: find.byType(TextField),
      );
      expect(sender, findsOneWidget);
      expect(tester.widget<TextField>(sender).controller!.text, isEmpty);
    });

    testWidgets('Save is dead until something actually changes',
        (tester) async {
      useTallView(tester);
      await tester.pumpWidget(app());

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('typing a new name wakes Save up', (tester) async {
      await tester.pumpWidget(app());

      useTallView(tester);
      await tester.enterText(nameField(), 'Home');
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('shows the address but does not offer to change it',
        (tester) async {
      // The address is what the stored secret was proved against and what
      // every cached folder is filed under. Showing it greyed, with the
      // reason, beats leaving someone hunting for a field.
      await tester.pumpWidget(app());

      expect(find.text('me@example.com'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'me@example.com'), findsNothing);
      expect(
        find.textContaining('The address cannot be changed'),
        findsOneWidget,
      );
    });

    testWidgets('offers a new app password for a password account',
        (tester) async {
      useTallView(tester);
      await tester.pumpWidget(app());

      expect(find.text('New app password'), findsOneWidget);
      expect(find.text('Sign in with Microsoft'), findsNothing);
    });

    testWidgets('offers Microsoft sign-in for an OAuth account',
        (tester) async {
      // No password field at all: there is nothing a person could type that
      // would work, so showing one would only invite them to try.
      useTallView(tester);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: EditAccountScreen(
              account: Account(
                id: 'acct-2',
                displayName: 'Work',
                emailAddress: 'me@outlook.example',
                provider: MailProvider.outlook,
                authMethod: AuthMethod.oauth,
                colorValue: 0xFF107C41,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Sign in with Microsoft'), findsOneWidget);
      expect(find.text('New app password'), findsNothing);
    });

    testWidgets('the check button waits for a password to be typed',
        (tester) async {
      useTallView(tester);
      await tester.pumpWidget(app());

      var button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Check and save'),
      );
      expect(button.onPressed, isNull);

      await tester.enterText(
        find.ancestor(
          of: find.text('New app password'),
          matching: find.byType(TextField),
        ),
        'newnewnewnewnew1',
      );
      await tester.pump();

      button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Check and save'),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('popping a message out', () {
    // The reading pane asks the engine for a body, and the sample engine
    // answers after a deliberate delay. pump() alone leaves that timer
    // outstanding when the tree is torn down, which the binding reports as a
    // failure; settling lets it land first.
    testWidgets('a pane offers it', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ReadingPane(
                message: _message,
                onPopOut: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
    });

    testWidgets('a message already full screen does not', (tester) async {
      // MessageScreen passes no callback. A button promising to open what is
      // already open would do nothing visible and read as broken.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: ReadingPane(message: _message)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.open_in_full), findsNothing);
    });

    testWidgets('tapping it calls back', (tester) async {
      var popped = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ReadingPane(
                message: _message,
                onPopOut: () => popped++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();

      expect(popped, 1);
    });
  });
}

final _message = MailMessage(
  id: 'a:INBOX#1',
  accountId: 'a',
  folderId: 'a:INBOX',
  uid: 1,
  subject: 'The subject line',
  from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
  to: const [MailAddress(email: 'me@example.com')],
  date: DateTime(2026, 9, 14, 9, 41),
  preview: 'The preview line',
);
