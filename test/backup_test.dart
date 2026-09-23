import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/backup/backup_service.dart';
import 'package:myemail/data/backup/secret_vault.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/settings_backup.dart';
import 'package:myemail/state/backup_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/accounts/add_account_screen.dart';
import 'package:myemail/ui/settings/backup_screen.dart';

/// Taking the app's setup to another device.
void main() {
  late MemoryAccountStore accounts;
  late MemoryUiStateStore uiState;
  late BackupService service;

  const personal = Account(
    id: 'acct-aaa',
    displayName: 'Personal',
    emailAddress: 'me@example.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0xFF0F6CBD,
  );
  const work = Account(
    id: 'acct-bbb',
    displayName: 'Work',
    emailAddress: 'me@work.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF107C41,
  );

  setUp(() {
    accounts = MemoryAccountStore([personal, work]);
    uiState = MemoryUiStateStore();
    service = BackupService(
      accountStore: accounts,
      uiState: uiState,
      appVersion: '1.6.0+10',
      now: () => DateTime.utc(2026, 9, 18, 10),
    );
  });

  Future<void> seedSettings() async {
    await uiState.writeIds(UiStateKeys.favorites, {'acct-aaa:INBOX'});
    await uiState.writeIds(UiStateKeys.hidden, {'acct-aaa:Spam'});
    await uiState.writeIds(UiStateKeys.collapsedAccounts, {'acct-bbb'});
    await uiState.writeOrder(UiStateKeys.order, {'acct-aaa:Work': 2});
    await uiState.writeString(UiStateKeys.display, '{"density":"compact"}');
    await uiState.writeIds(UiStateKeys.trustedSenders, {'@shop.example'});
  }

  group('what goes in the file', () {
    test('accounts and settings survive a round trip', () async {
      await seedSettings();

      final restored = SettingsBackup.parse((await service.export()).toJsonString());

      expect(restored.accounts.map((a) => a.emailAddress),
          ['me@example.com', 'me@work.example']);
      expect(restored.entries[UiStateKeys.favorites], ['acct-aaa:INBOX']);
      expect(restored.entries[UiStateKeys.order], {'acct-aaa:Work': 2});
      expect(restored.entries[UiStateKeys.display], '{"density":"compact"}');
      expect(restored.entries[UiStateKeys.trustedSenders], ['@shop.example'],
          reason: 'who may load pictures is a decision worth carrying over');
    });

    test('account ids are preserved, because the settings point at them',
        () async {
      // Folder ids are "<accountId>:<path>", and those ids are the keys for
      // favourites, hidden folders, Quick Steps and signatures. Reissuing ids
      // on restore would leave every one of those pointing at nothing while
      // the restore still looked like it had worked.
      await seedSettings();

      final restored = SettingsBackup.parse((await service.export()).toJsonString());

      expect(restored.accounts.first.id, 'acct-aaa');
      final favourite =
          (restored.entries[UiStateKeys.favorites] as List).single as String;
      expect(favourite, startsWith('${restored.accounts.first.id}:'));
    });

    test('no secret of any kind is in the file', () async {
      // The security case for the whole feature. A file carrying an app
      // password or a refresh token opens the mailbox to whoever finds it,
      // and a settings file ends up in a cloud folder by design.
      //
      // Planted secrets rather than a keyword sweep: "appPassword" is the
      // name of an auth method and belongs in the file, so searching for the
      // word "password" only catches that. What must never appear is a
      // value.
      await seedSettings();
      const secrets = [
        'abcdabcdabcdabcd',
        'refresh-token-value',
        'access-token-value',
      ];

      final json = (await service.export()).toJsonString();

      for (final secret in secrets) {
        expect(json, isNot(contains(secret)), reason: secret);
      }
      // Nor any field that looks like a place to put one later. The service
      // is never handed a credential store, so it cannot leak a secret even
      // by accident; this guards the format against someone adding a field.
      for (final key in ['"password"', '"secret"', '"token"', '"refreshToken"']) {
        expect(json, isNot(contains(key)), reason: key);
      }
    });

    test('the auth method is kept, so the restore knows how to sign in',
        () async {
      final restored =
          SettingsBackup.parse((await service.export()).toJsonString());

      expect(restored.accounts[1].authMethod, AuthMethod.oauth);
      expect(restored.accounts[1].provider, MailProvider.outlook);
    });

    test('per-device bookkeeping is left out', () async {
      // The selected folder is where you happened to be standing, and recent
      // moves are a history rather than a setting. Notification watermarks
      // are worse: restored onto another device they claim mail it has never
      // seen was already announced, so its first sync goes silent.
      await uiState.writeIds(UiStateKeys.selected, {'acct-aaa:INBOX'});
      await uiState.writeString(UiStateKeys.recentMoves, 'acct-aaa:Work');

      final entries = (await service.export()).entries;

      expect(entries.containsKey(UiStateKeys.selected), isFalse);
      expect(entries.containsKey(UiStateKeys.recentMoves), isFalse);
    });

    test('empty settings are omitted rather than written as blanks', () async {
      expect((await service.export()).entries, isEmpty);
    });
  });

  group('reading a file back', () {
    test('restores settings onto a bare device', () async {
      await seedSettings();
      final file = (await service.export()).toJsonString();

      final fresh = MemoryUiStateStore();
      final freshAccounts = MemoryAccountStore();
      final report = await BackupService(
        accountStore: freshAccounts,
        uiState: fresh,
      ).import(SettingsBackup.parse(file));

      expect(report.settingsRestored, 6);
      expect(report.accountsAdded, hasLength(2));
      expect(fresh.readIds(UiStateKeys.favorites), {'acct-aaa:INBOX'});
      expect(fresh.readIds(UiStateKeys.trustedSenders), {'@shop.example'});
      expect(fresh.readOrder(UiStateKeys.order), {'acct-aaa:Work': 2});
      expect(freshAccounts.read().first.id, 'acct-aaa');
    });

    test('says the restored accounts still need signing in', () async {
      final file = (await service.export()).toJsonString();

      final report = await BackupService(
        accountStore: MemoryAccountStore(),
        uiState: MemoryUiStateStore(),
      ).import(SettingsBackup.parse(file));

      expect(report.needsSignIn, isTrue);
    });

    test('an account already on this device keeps its working sign-in',
        () async {
      // The copy here has a secret behind it and the copy in the file does
      // not, so preferring the file would sign a working account out.
      final file = (await service.export()).toJsonString();

      final report = await service.import(SettingsBackup.parse(file));

      expect(report.accountsAdded, isEmpty);
      expect(report.accountsAlreadyHere, hasLength(2));
      expect(accounts.read(), hasLength(2), reason: 'no duplicates');
    });

    test('the same mailbox added separately on two devices is not duplicated',
        () async {
      // Different ids, same address. Matching on id alone would add it twice
      // and leave two entries for one mailbox.
      final file = (await service.export()).toJsonString();
      final other = MemoryAccountStore([
        const Account(
          id: 'acct-different',
          displayName: 'Personal',
          emailAddress: 'ME@example.com',
          provider: MailProvider.gmail,
          authMethod: AuthMethod.appPassword,
          colorValue: 0xFF0F6CBD,
        ),
      ]);

      final report = await BackupService(
        accountStore: other,
        uiState: MemoryUiStateStore(),
      ).import(SettingsBackup.parse(file));

      expect(report.accountsAdded.map((a) => a.emailAddress),
          ['me@work.example']);
      expect(other.read(), hasLength(2));
    });

    test("and that mailbox's settings follow it to this device's id",
        () async {
      // The phone's favourites and signature came across under the phone's
      // account id, which the tablet does not have: favourites emptied,
      // hidden folders came back, and mail went out with no signature.
      await seedSettings();
      await uiState.writeString(
        UiStateKeys.signatures,
        '[{"accountId":"acct-aaa","html":"<p>Ron</p>","onReply":true}]',
      );
      final file = (await service.export()).toJsonString();
      final tablet = MemoryUiStateStore();
      await tablet.writeIds(UiStateKeys.favorites, {'acct-own:INBOX'});
      await tablet.writeString(
        UiStateKeys.signatures,
        '[{"accountId":"acct-own","html":"<p>Own</p>","onReply":true}]',
      );

      await BackupService(
        accountStore: MemoryAccountStore([
          const Account(
            id: 'acct-different',
            displayName: 'Personal',
            emailAddress: 'ME@example.com',
            provider: MailProvider.gmail,
            authMethod: AuthMethod.appPassword,
            colorValue: 0xFF0F6CBD,
          ),
          const Account(
            id: 'acct-own',
            displayName: 'Only here',
            emailAddress: 'only@here.example',
            provider: MailProvider.gmail,
            authMethod: AuthMethod.appPassword,
            colorValue: 0xFF0F6CBD,
          ),
        ]),
        uiState: tablet,
      ).import(SettingsBackup.parse(file));

      expect(tablet.readIds(UiStateKeys.favorites),
          {'acct-different:INBOX', 'acct-own:INBOX'},
          reason: "the phone's, under this device's id, and this device's own");
      expect(tablet.readIds(UiStateKeys.hidden), {'acct-different:Spam'});
      expect(tablet.readOrder(UiStateKeys.order), {'acct-different:Work': 2});
      final signatures = tablet.readString(UiStateKeys.signatures)!;
      expect(signatures, contains('"accountId":"acct-different"'));
      expect(signatures, contains('"accountId":"acct-own"'));
      expect(signatures, isNot(contains('acct-aaa')));
    });

    test('the name mail goes out under comes back too', () async {
      // Without it a restored account sent as its folder-list label.
      final named = MemoryAccountStore([
        const Account(
          id: 'acct-aaa',
          displayName: 'Personal',
          emailAddress: 'me@example.com',
          provider: MailProvider.gmail,
          authMethod: AuthMethod.appPassword,
          colorValue: 0xFF0F6CBD,
          chosenSenderName: 'Ron Dvir',
        ),
      ]);
      final file = (await BackupService(
        accountStore: named,
        uiState: MemoryUiStateStore(),
      ).export())
          .toJsonString();
      final fresh = MemoryAccountStore();

      await BackupService(accountStore: fresh, uiState: MemoryUiStateStore())
          .import(SettingsBackup.parse(file));

      expect(fresh.read().single.senderName, 'Ron Dvir');
    });

    test('every setting a restore writes is read again on screen', () {
      // A restore writes under the notifiers, which read once and write
      // their whole state back on any change: the old favourites went on
      // showing, and the next star wrote them back over the restored ones.
      expect(reloadedAfterRestore, BackupService.exported.keys.toSet());
    });

    test('a key this build does not know is skipped, not written blind',
        () async {
      // A file from a newer version. Writing an unknown key could put a value
      // of the wrong shape where a notifier expects to read one.
      final backup = SettingsBackup(
        accounts: const [],
        entries: const {'something.new.v9': 42},
      );

      final report = await service.import(backup);

      expect(report.settingsRestored, 0);
    });

    test('a value of the wrong shape is skipped rather than crashing',
        () async {
      final backup = SettingsBackup(
        accounts: const [],
        entries: const {UiStateKeys.favorites: 'not a list'},
      );

      final report = await service.import(backup);

      expect(report.settingsRestored, 0);
      expect(uiState.readIds(UiStateKeys.favorites), isEmpty);
    });
  });

  group('a file that is not one of ours', () {
    test('random JSON is refused in words a person can act on', () {
      expect(
        () => SettingsBackup.parse('{"hello":"world"}'),
        throwsA(isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('not a MyEmail settings file'),
        )),
      );
    });

    test('something that is not JSON at all is refused the same way', () {
      expect(
        () => SettingsBackup.parse('not json'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a newer format says to update rather than half-restoring', () {
      final future = jsonEncode({
        'format': 'myemail.settings',
        'formatVersion': SettingsBackup.formatVersion + 1,
        'accounts': const [],
        'settings': const {},
      });

      expect(
        () => SettingsBackup.parse(future),
        throwsA(isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('newer version'),
        )),
      );
    });

    test('one unreadable account does not cost the rest of the file', () {
      final partial = jsonEncode({
        'format': 'myemail.settings',
        'formatVersion': 1,
        'accounts': [
          {'id': 'acct-aaa', 'emailAddress': 'me@example.com'},
          {'displayName': 'no id or address'},
        ],
        'settings': {UiStateKeys.favorites: ['acct-aaa:INBOX']},
      });

      final backup = SettingsBackup.parse(partial);

      expect(backup.accounts, hasLength(1));
      expect(backup.entries, isNotEmpty);
    });
  });

  group('the Backup screen', () {
    testWidgets('says what happens to sign-in details', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(accounts),
            uiStateStoreProvider.overrideWithValue(uiState),
          ],
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      expect(
        find.textContaining('only in the file if you asked for them'),
        findsOneWidget,
      );
    });

    testWidgets('exporting writes a file and reports what went in it',
        (tester) async {
      final files = _FakeBackupFiles();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(accounts),
            uiStateStoreProvider.overrideWithValue(uiState),
            backupFilesProvider.overrideWithValue(files),
          ],
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      await tester.tap(find.text('Save to a file'));
      await tester.pumpAndSettle();

      // The dialog asks whether sign-ins travel. Turning that off is the
      // path that needs no passphrase.
      await tester.tap(find.text('Include sign-in details'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(files.saved, isNotNull);
      expect(files.savedName, endsWith('.json'));
      expect(find.textContaining('2 accounts'), findsOneWidget);
    });

    testWidgets('backing out of the save dialog reports nothing',
        (tester) async {
      final files = _FakeBackupFiles(accept: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(accounts),
            uiStateStoreProvider.overrideWithValue(uiState),
            backupFilesProvider.overrideWithValue(files),
          ],
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      await tester.tap(find.text('Save to a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Include sign-in details'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Saved'), findsNothing);
    });

    testWidgets('restoring asks before it overwrites anything',
        (tester) async {
      // A file with something in it: an empty one proved nothing, since
      // restoring it and cancelling it leave the same empty settings.
      await seedSettings();
      final files = _FakeBackupFiles()
        ..toPick = (await service.export()).toJsonString();
      final target = MemoryUiStateStore();
      final targetAccounts = MemoryAccountStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(targetAccounts),
            uiStateStoreProvider.overrideWithValue(target),
            backupFilesProvider.overrideWithValue(files),
          ],
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      await tester.tap(find.text('Restore from a file'));
      await tester.pumpAndSettle();

      expect(find.text('Restore these settings?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(targetAccounts.read(), isEmpty,
          reason: 'cancelling must write nothing at all');
      for (final key in BackupService.exported.keys) {
        expect(target.readIds(key), isEmpty, reason: key);
        expect(target.readOrder(key), isEmpty, reason: key);
        expect(target.readString(key), isNull, reason: key);
      }
    });

    testWidgets('after a restore the app shows what was restored',
        (tester) async {
      // The screens had read their settings once and went on showing the
      // old ones, and the next change wrote those back over the restore.
      await seedSettings();
      final files = _FakeBackupFiles()
        ..toPick = (await service.export()).toJsonString();
      final target = MemoryUiStateStore();
      await target.writeIds(UiStateKeys.favorites, {'x:Old'});
      final targetAccounts = MemoryAccountStore();
      final c = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWithValue(targetAccounts),
          uiStateStoreProvider.overrideWithValue(target),
          backupFilesProvider.overrideWithValue(files),
        ],
      );
      addTearDown(c.dispose);
      c.listen(favoriteFoldersProvider, (_, _) {});
      expect(c.read(favoriteFoldersProvider), {'x:Old'});
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      await tester.tap(find.text('Restore from a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      final restored = target.readIds(UiStateKeys.favorites);
      expect(restored, isNot({'x:Old'}));
      expect(c.read(favoriteFoldersProvider), restored);
      expect(targetAccounts.read(), hasLength(2));
      expect(find.textContaining('2 accounts added'), findsOneWidget);
    });

    group('with sign-in details', () {
      const passphrase = 'correct horse battery staple';

      /// A vault with a cheap iteration count: the real 120,000 is there to
      /// slow an attacker down, and would only slow the suite down here.
      BackupService serviceOver(
        MemoryAccountStore store,
        MemoryUiStateStore ui,
        MemoryCredentialStore creds,
      ) =>
          BackupService(
            accountStore: store,
            uiState: ui,
            credentialStore: creds,
            vault: const SecretVault(iterations: 1000),
          );

      Future<void> pumpOver(
        WidgetTester tester, {
        required MemoryAccountStore store,
        required MemoryUiStateStore ui,
        required MemoryCredentialStore creds,
        required _FakeBackupFiles files,
      }) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountStoreProvider.overrideWithValue(store),
              uiStateStoreProvider.overrideWithValue(ui),
              backupServiceProvider
                  .overrideWithValue(serviceOver(store, ui, creds)),
              backupFilesProvider.overrideWithValue(files),
            ],
            child: const MaterialApp(home: BackupScreen()),
          ),
        );
      }

      Finder field(String label) => find.widgetWithText(TextField, label);

      /// The vault's work runs outside the test's clock: real time is let
      /// pass, a little at a time, with a frame after each.
      Future<void> settleVault(WidgetTester tester) async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }
      FilledButton save(WidgetTester tester) =>
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

      Future<String> sealedFile() async {
        final creds = MemoryCredentialStore();
        await creds.writeSecret('acct-aaa', 'abcdabcdabcdabcd');
        await seedSettings();
        return (await serviceOver(accounts, uiState, creds)
                .export(passphrase: passphrase))
            .toJsonString();
      }

      testWidgets('Save waits for a passphrase long enough and typed twice',
          (tester) async {
        // Sealed under a typo, the file opens for nobody.
        final creds = MemoryCredentialStore();
        await creds.writeSecret('acct-aaa', 'abcdabcdabcdabcd');
        final files = _FakeBackupFiles();
        await pumpOver(tester,
            store: accounts, ui: uiState, creds: creds, files: files);
        await tester.tap(find.text('Save to a file'));
        await tester.pumpAndSettle();

        expect(save(tester).onPressed, isNull, reason: 'nothing typed');
        await tester.enterText(field('Passphrase'), 'too short');
        await tester.enterText(field('Type it again'), 'too short');
        await tester.pump();
        expect(save(tester).onPressed, isNull, reason: 'too short');
        await tester.enterText(field('Passphrase'), passphrase);
        await tester.enterText(field('Type it again'), '${passphrase}x');
        await tester.pump();
        expect(save(tester).onPressed, isNull, reason: 'not the same twice');
        await tester.enterText(field('Type it again'), passphrase);
        await tester.pump();
        expect(save(tester).onPressed, isNotNull);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await settleVault(tester);

        expect(files.saved, isNotNull);
        expect(SettingsBackup.parse(files.saved!).hasSecrets, isTrue);
        expect(files.saved, isNot(contains('abcdabcdabcdabcd')));
      });

      testWidgets('a sealed file is restored signed in, after a wrong try',
          (tester) async {
        final files = _FakeBackupFiles()..toPick = await sealedFile();
        final store = MemoryAccountStore();
        final creds = MemoryCredentialStore();
        await pumpOver(tester,
            store: store, ui: MemoryUiStateStore(), creds: creds, files: files);

        await tester.tap(find.text('Restore from a file'));
        await tester.pumpAndSettle();
        expect(find.textContaining('carries sign-in details'), findsOneWidget,
            reason: 'not "never put in the file", of a file that has them');
        await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
        await tester.pumpAndSettle();

        await tester.enterText(field('Passphrase'), 'wrong passphrase');
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
        await settleVault(tester);
        expect(find.text('That passphrase did not open the file. Try again.'),
            findsOneWidget);
        expect(store.read(), isEmpty);

        await tester.enterText(field('Passphrase'), passphrase);
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
        await settleVault(tester);

        expect(store.read(), hasLength(2));
        expect(await tester.runAsync(() => creds.readSecret('acct-aaa')),
            'abcdabcdabcdabcd');
        expect(find.textContaining('1 signed in'), findsOneWidget);
      });

      testWidgets('cancelling at the passphrase writes nothing',
          (tester) async {
        final files = _FakeBackupFiles()..toPick = await sealedFile();
        final store = MemoryAccountStore();
        final ui = MemoryUiStateStore();
        await pumpOver(tester,
            store: store,
            ui: ui,
            creds: MemoryCredentialStore(),
            files: files);

        await tester.tap(find.text('Restore from a file'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(store.read(), isEmpty);
        expect(ui.readIds(UiStateKeys.favorites), isEmpty);
        expect(find.textContaining('restored'), findsNothing);
      });
    });

    testWidgets('a file without them says new accounts will need signing in',
        (tester) async {
      final files = _FakeBackupFiles()
        ..toPick = (await service.export()).toJsonString();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(MemoryAccountStore()),
            uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
            backupFilesProvider.overrideWithValue(files),
          ],
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      await tester.tap(find.text('Restore from a file'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no sign-in details in it'), findsOneWidget);
    });

    testWidgets('a file that is not ours is reported, not swallowed',
        (tester) async {
      final files = _FakeBackupFiles()..toPick = '{"hello":"world"}';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(accounts),
            uiStateStoreProvider.overrideWithValue(uiState),
            backupFilesProvider.overrideWithValue(files),
          ],
          child: const MaterialApp(home: BackupScreen()),
        ),
      );

      await tester.tap(find.text('Restore from a file'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not a MyEmail settings file'), findsOneWidget);
    });
  });

  group('one-click restore', () {
    const passphrase = 'correct horse battery staple';

    /// Both services share a vault with a cheap iteration count: the real
    /// 120,000 is there to slow an attacker down and would only slow the
    /// suite down here.
    BackupService serviceWith({
      required MemoryAccountStore store,
      required MemoryCredentialStore creds,
      required MemoryUiStateStore ui,
    }) =>
        BackupService(
          accountStore: store,
          uiState: ui,
          credentialStore: creds,
          vault: const SecretVault(iterations: 1000),
        );

    test('secrets travel and the accounts arrive signed in', () async {
      final creds = MemoryCredentialStore();
      await creds.writeSecret('acct-aaa', 'abcdabcdabcdabcd');
      await creds.writeSecret('acct-bbb', '{"refresh_token":"r-1"}');
      final from = serviceWith(
        store: accounts,
        creds: creds,
        ui: uiState,
      );

      final file = (await from.export(passphrase: passphrase)).toJsonString();

      final toCreds = MemoryCredentialStore();
      final toAccounts = MemoryAccountStore();
      final report = await serviceWith(
        store: toAccounts,
        creds: toCreds,
        ui: MemoryUiStateStore(),
      ).import(SettingsBackup.parse(file), passphrase: passphrase);

      expect(report.accountsSignedIn, 2);
      expect(report.needsSignIn, isFalse,
          reason: 'this is the whole point of a one-click restore');
      expect(await toCreds.readSecret('acct-aaa'), 'abcdabcdabcdabcd');
      expect(await toCreds.readSecret('acct-bbb'), '{"refresh_token":"r-1"}');
    });

    test('a file saved without a passphrase carries no secrets', () async {
      final creds = MemoryCredentialStore();
      await creds.writeSecret('acct-aaa', 'abcdabcdabcdabcd');

      final backup = await serviceWith(
        store: accounts,
        creds: creds,
        ui: uiState,
      ).export();

      expect(backup.hasSecrets, isFalse);
      expect(backup.toJsonString(), isNot(contains('abcdabcdabcdabcd')));
    });

    test('the wrong passphrase writes nothing at all', () async {
      // Half a restore — accounts present, no sign-ins, settings replaced —
      // would be worse than none, because there is no obvious way back.
      final creds = MemoryCredentialStore();
      await creds.writeSecret('acct-aaa', 'abcdabcdabcdabcd');
      await seedSettings();
      final file = (await serviceWith(
        store: accounts,
        creds: creds,
        ui: uiState,
      ).export(passphrase: passphrase))
          .toJsonString();

      final toAccounts = MemoryAccountStore();
      final toUi = MemoryUiStateStore();

      await expectLater(
        serviceWith(
          store: toAccounts,
          creds: MemoryCredentialStore(),
          ui: toUi,
        ).import(SettingsBackup.parse(file), passphrase: 'wrong passphrase'),
        throwsA(isA<VaultWrongPassphrase>()),
      );

      expect(toAccounts.read(), isEmpty);
      expect(toUi.readIds(UiStateKeys.favorites), isEmpty);
    });

    test('an account already here keeps its own secret', () async {
      // The file's copy may be older than the device's, and a rotated OAuth
      // refresh token in it would be dead — writing it would sign a working
      // account out.
      final creds = MemoryCredentialStore();
      await creds.writeSecret('acct-aaa', 'from-the-file');
      final file = (await serviceWith(
        store: accounts,
        creds: creds,
        ui: uiState,
      ).export(passphrase: passphrase))
          .toJsonString();

      final liveCreds = MemoryCredentialStore();
      await liveCreds.writeSecret('acct-aaa', 'the-working-one');
      await serviceWith(
        store: accounts,
        creds: liveCreds,
        ui: uiState,
      ).import(SettingsBackup.parse(file), passphrase: passphrase);

      expect(await liveCreds.readSecret('acct-aaa'), 'the-working-one');
    });

    test('an account that was signed out does not restore an empty secret',
        () async {
      // Writing a blank would produce an account that looks signed in and
      // fails on first connect.
      final file = (await serviceWith(
        store: accounts,
        creds: MemoryCredentialStore(),
        ui: uiState,
      ).export(passphrase: passphrase))
          .toJsonString();

      final toCreds = MemoryCredentialStore();
      final report = await serviceWith(
        store: MemoryAccountStore(),
        creds: toCreds,
        ui: MemoryUiStateStore(),
      ).import(SettingsBackup.parse(file), passphrase: passphrase);

      expect(report.accountsSignedIn, 0);
      expect(report.needsSignIn, isTrue);
      expect(await toCreds.readSecret('acct-aaa'), isNull);
    });

    test('an older build reads a file with secrets, minus the secrets', () {
      // The secrets block is an extra key, not a new format version, so a
      // build that predates it restores everything else rather than refusing
      // the file outright.
      final withSecrets = jsonEncode({
        'format': 'myemail.settings',
        'formatVersion': 1,
        'accounts': [
          {'id': 'acct-aaa', 'emailAddress': 'me@example.com'},
        ],
        'settings': {UiStateKeys.favorites: ['acct-aaa:INBOX']},
        'secrets': {'cipher': 'aes-gcm-256'},
      });

      final parsed = SettingsBackup.parse(withSecrets);

      expect(parsed.accounts, hasLength(1));
      expect(parsed.hasSecrets, isTrue);
      expect(parsed.summary, contains('sign-in details'));
    });
  });

  group('the welcome screen', () {
    testWidgets('offers a restore, because Settings cannot be reached yet',
        (tester) async {
      // A new device has no accounts, so the shell shows the add-account
      // screen instead of the app and there is no route to Settings. Without
      // this button someone holding a backup has no way to use it.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(MemoryAccountStore()),
            uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          ],
          child: const MaterialApp(
            home: AddAccountScreen(isFirstAccount: true),
          ),
        ),
      );

      expect(find.text('Restore from a backup'), findsOneWidget);
    });

    testWidgets('the ordinary add-account screen does not offer it',
        (tester) async {
      // Reached from Settings, where Backup is already a row of its own.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(accounts),
            uiStateStoreProvider.overrideWithValue(uiState),
          ],
          child: const MaterialApp(home: AddAccountScreen()),
        ),
      );

      expect(find.text('Restore from a backup'), findsNothing);
    });

    testWidgets('it opens a restore-only screen', (tester) async {
      // Nothing on the device to save yet, so offering Save would be an
      // empty promise.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWithValue(MemoryAccountStore()),
            uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          ],
          child: const MaterialApp(
            home: AddAccountScreen(isFirstAccount: true),
          ),
        ),
      );

      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a backup file'), findsOneWidget);
      expect(find.text('Save to a file'), findsNothing);
    });
  });
}

/// Stands in for the document picker, which a widget test cannot answer.

class _FakeBackupFiles implements BackupFiles {
  _FakeBackupFiles({this.accept = true});

  final bool accept;
  String? saved;
  String? savedName;
  String? toPick;

  @override
  Future<bool> save({
    required String fileName,
    required String contents,
  }) async {
    if (!accept) return false;
    saved = contents;
    savedName = fileName;
    return true;
  }

  @override
  Future<String?> pick() async => toPick;
}
