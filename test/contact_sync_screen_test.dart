import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/backup_providers.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/put_away_providers.dart';
import 'package:myemail/ui/accounts/microsoft_sign_in_screen.dart';
import 'package:myemail/ui/common/text_size.dart';
import 'package:myemail/ui/messages/date_format.dart' show formatClock;
import 'package:myemail/ui/settings/backup_screen.dart';
import 'package:myemail/ui/settings/contact_sync_screen.dart';
import 'package:myemail/ui/settings/settings_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fakes/fake_contact_sync.dart';
import 'fakes/fake_webview.dart';

/// Settings, Contact sync: the row, the screen in each of its states, Allow,
/// Save backup, and the shell's start, stop and message.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const gmail = Account(
    id: 'acct-g',
    displayName: 'Personal',
    emailAddress: 'ron@gmail.example',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );
  const hadco = Account(
    id: 'acct-h',
    displayName: 'Hadco',
    emailAddress: 'ron@hadco.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF107C41,
  );

  const studio = Account(
    id: 'acct-m',
    displayName: 'Myhomestudio',
    emailAddress: 'ron@studio.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF5C2D91,
  );

  final today = DateTime.now();
  final at1042 = DateTime(today.year, today.month, today.day, 10, 42);

  /// The pair chosen, the first sync done, the last run at 10:42.
  ContactSyncStatus synced({
    ContactSyncTally? last,
    ContactSyncHalt? halt,
    List<ContactSyncQuestion> questions = const [],
    List<ContactSyncLook> looks = const [],
    List<ContactSyncDeleted> deleted = const [],
    ContactSyncProgress? running,
    DateTime? lastDoneAt,
    DateTime? firstDoneAt,
    bool firstDone = true,
    int? googleCount,
    int? graphCount,
    ContactSyncNotice? notice,
  }) =>
      ContactSyncStatus(
        googleAccountId: gmail.id,
        graphAccountId: hadco.id,
        firstStartedAt: at1042.subtract(const Duration(days: 3)),
        firstDoneAt: firstDone
            ? firstDoneAt ?? at1042.subtract(const Duration(days: 3))
            : null,
        lastDoneAt: lastDoneAt ?? (firstDone ? at1042 : null),
        last: last,
        halt: halt,
        questions: questions,
        needsALook: looks,
        recentlyDeleted: deleted,
        running: running,
        googleCount: googleCount,
        graphCount: graphCount,
        notice: notice,
      );

  const chosenOnly = ContactSyncStatus(
    googleAccountId: 'acct-g',
    graphAccountId: 'acct-h',
  );

  group("the Settings row's subtitle", () {
    String say(
      ContactSyncStatus? s, {
      bool on = true,
      List<Account> accounts = const [gmail, hadco],
    }) =>
        contactSyncSubtitle(
          on: on,
          status: s == null ? const AsyncLoading() : AsyncData(s),
          accounts: accounts,
          now: today,
        );

    test('off, loading, and not set up', () {
      expect(say(synced(), on: false), 'Off');
      expect(say(null), 'Loading');
      expect(say(const ContactSyncStatus()), 'Not set up yet');
      expect(
        say(synced(), accounts: const [gmail]),
        'Not set up yet',
        reason: 'a removed account is not named',
      );
    });

    test('the first sync, before and while', () {
      expect(say(chosenOnly), 'Gmail and Hadco, not started yet');
      expect(
        say(synced(firstDone: false)),
        'Gmail and Hadco, first sync unfinished',
      );
      expect(
        say(synced(
          running: const ContactSyncProgress(step: ContactSyncStep.reading),
        )),
        'Gmail and Hadco, syncing now',
      );
    });

    test('when it last synced', () {
      expect(say(synced()), 'Gmail and Hadco, synced at 10:42');
      final before = at1042.subtract(const Duration(days: 2));
      expect(
        say(synced(lastDoneAt: before)),
        'Gmail and Hadco, synced on ${before.day} ${const [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ][before.month - 1]}',
      );
      expect(
        say(synced(looks: const [
          ContactSyncLook(id: 1, kind: ContactReviewKind.clash),
          ContactSyncLook(id: 2, kind: ContactReviewKind.clash),
          ContactSyncLook(
            id: 3,
            kind: ContactReviewKind.clash,
            answer: ContactSyncChoice.keepNewer,
          ),
        ])),
        '2 contacts need a look',
      );
    });

    test('a question waiting for an answer comes first', () {
      ContactSyncQuestion q(ContactSyncQuestionKind kind, int n) =>
          ContactSyncQuestion(kind: kind, items: [
            for (var i = 0; i < n; i++)
              ContactSyncQuestionItem(
                title: 'Person $i',
                side: ContactSide.google,
              ),
          ]);
      expect(
        say(synced(questions: [q(ContactSyncQuestionKind.deletions, 12)])),
        '12 deletions need your OK',
      );
      expect(
        say(synced(questions: [q(ContactSyncQuestionKind.changes, 1)])),
        'Changes to 1 contact need your OK',
      );
      expect(
        say(synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.emptyAnswer,
            side: ContactSide.graph,
            listed: 0,
            expected: 400,
          ),
        ])),
        'Stopped: Hadco listed too few contacts',
      );
      expect(
        say(synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.deletions,
            answer: ContactSyncChoice.deleteThem,
          ),
        ])),
        'Gmail and Hadco, synced at 10:42',
        reason: 'an answered question is no longer waiting',
      );
    });

    test('why it stopped', () {
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.notAllowed,
          at: at1042,
          side: ContactSide.graph,
        ))),
        'Not allowed yet for Hadco',
      );
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.otherDevice,
          at: at1042,
        ))),
        'Syncing on your other device',
      );
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at1042,
        ))),
        'Could not sync at 10:42',
      );
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.putAway,
          at: at1042,
        ))),
        'Gmail and Hadco, synced at 10:42',
        reason: 'put away is not a stop to report',
      );
    });
  });

  group('the screen', () {
    late FakeContactSync sync;
    late _Engine engine;
    late MemoryUiStateStore ui;
    late _Files files;

    setUp(() {
      sync = FakeContactSync(status: synced());
      engine = _Engine(sync, const [gmail, hadco]);
      ui = MemoryUiStateStore();
      files = _Files();
    });

    Future<ProviderContainer> pumpScreen(
      WidgetTester tester, {
      bool on = true,
      MicrosoftOAuth? oauth,
      Size size = const Size(800, 3000),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (on) await ui.writeString(UiStateKeys.contactSyncDevice, 'on');
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        backupFilesProvider.overrideWithValue(files),
        if (oauth != null) microsoftOAuthProvider.overrideWithValue(oauth),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: ContactSyncScreen()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    Finder button(String key) => find.byKey(ValueKey(key));

    bool enabled(WidgetTester tester, String key) =>
        tester.widget<ButtonStyleButton>(button(key)).onPressed != null;

    testWidgets('off and on again carries on with the pair the runner has, '
        'and chooses nothing', (tester) async {
      // Myhomestudio is listed before Hadco: turning the switch off and on,
      // as Ron will before an Undo changes, must not pair Gmail with it.
      engine = _Engine(sync, const [gmail, studio, hadco]);
      await pumpScreen(tester, on: false);

      expect(
        tester.widget<SwitchListTile>(button('contact-sync-on')).value,
        isFalse,
      );
      expect(
        find.text('Off: nothing syncs on this device. Turning it off deletes '
            'nothing, and turning it on again carries on syncing Gmail with '
            'Hadco where it stopped.'),
        findsOneWidget,
      );
      expect(find.text('Sync Gmail with'), findsNothing);
      expect(find.text('Sync now'), findsNothing);
      expect(sync.accessAsked, isEmpty, reason: 'nothing is asked while off');

      await tester.tap(button('contact-sync-on'));
      await tester.pumpAndSettle();
      expect(ui.readString(UiStateKeys.contactSyncDevice), 'on');
      expect(sync.chosen, isEmpty);
      expect(
        find.descendant(
          of: button('contact-sync-with'),
          matching: find.text('Hadco'),
        ),
        findsOneWidget,
      );
      expect(find.text('Sync now'), findsOneWidget);

      await tester.tap(button('contact-sync-on'));
      await tester.pumpAndSettle();
      expect(ui.readString(UiStateKeys.contactSyncDevice), isNull);
      expect(sync.count('stop'), 1);
      expect(sync.chosen, isEmpty);
    });

    testWidgets('an account not allowed yet says so, with Allow',
        (tester) async {
      sync = FakeContactSync(status: chosenOnly, access: {
        'acct-h': const ContactSyncAccess(ContactSyncAccessState.needsSignIn),
      });
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      final hadcoRow = button('contact-sync-access:acct-h');
      expect(
        find.descendant(
          of: hadcoRow,
          matching: find.text(
            'Not allowed yet. Allow, then sign in. Where your organisation '
            'has to approve it, the sign-in sends them the request, and once '
            'they have, it starts on its own.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hadcoRow, matching: find.text('Allow')),
        findsOneWidget,
      );
      final gmailRow = button('contact-sync-access:acct-g');
      expect(
        find.descendant(of: gmailRow, matching: find.text('Allowed.')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: gmailRow, matching: find.text('Allow')),
        findsNothing,
      );
    });

    testWidgets('a Gmail on an app password is offered Google sign-in',
        (tester) async {
      const onPassword = Account(
        id: 'acct-g',
        displayName: 'Personal',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.appPassword,
        colorValue: 0xFF0F6CBD,
      );
      sync = FakeContactSync(status: chosenOnly, access: {
        'acct-g': const ContactSyncAccess(ContactSyncAccessState.notPossible),
      });
      engine = _Engine(sync, const [onPassword, hadco]);
      await pumpScreen(tester);

      final row = button('contact-sync-access:acct-g');
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Uses an app password'),
        ),
        findsOneWidget,
      );
      expect(find.descendant(of: row, matching: find.text('Allow')),
          findsOneWidget);
    });

    testWidgets('Allow on the Microsoft account asks for its contacts beside '
        'the mail', (tester) async {
      final web = FakeWebViewPlatform.install();
      sync = FakeContactSync(status: chosenOnly, access: {
        'acct-h': const ContactSyncAccess(ContactSyncAccessState.needsSignIn),
      });
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester, oauth: _grants());
      expect(sync.accessAsked.where((id) => id == 'acct-h'), hasLength(1));

      await tester.tap(find.descendant(
        of: button('contact-sync-access:acct-h'),
        matching: find.text('Allow'),
      ));
      // Not pumpAndSettle: the sign-in page never says it has loaded here,
      // so its progress bar would run for ever.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(MicrosoftSignInScreen), findsOneWidget);
      final asked = web.loadedUrls.last;
      final scope = asked.queryParameters['scope']!;
      expect(scope, contains('https://graph.microsoft.com/Contacts.ReadWrite'));
      expect(scope, contains('Mail.ReadWrite'),
          reason: 'the mail consent stays beside the new one');
      expect(asked.queryParameters['login_hint'], 'ron@hadco.example');

      await web.navigationHandler!(NavigationRequest(
        url: '${MicrosoftOAuth.redirectUri}?code=the-code'
            '&state=${asked.queryParameters['state']}',
        isMainFrame: true,
      ));
      await tester.pumpAndSettle();

      expect(engine.signedInAgain, ['acct-h']);
      expect(find.byType(ContactSyncScreen), findsOneWidget);
      expect(sync.accessAsked.where((id) => id == 'acct-h'), hasLength(2),
          reason: 'the row asks again after the sign-in');
    });

    testWidgets('the preview, and Start greyed out until both backup files '
        'are saved', (tester) async {
      sync = FakeContactSync(
        status: chosenOnly,
        previewAnswer: const ContactSyncPreview(
          googleListed: 340,
          graphListed: 412,
          addToGoogle: 45,
          addToGraph: 120,
          pairUp: 300,
          needsALook: 4,
          differingPairs: 12,
        ),
        backupFiles: _backupFiles,
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('First sync'), findsOneWidget);
      expect(enabled(tester, 'contact-sync-start'), isFalse);
      expect(find.textContaining('Start sync is ready once'), findsOneWidget);

      await tester.tap(button('contact-sync-preview'));
      await tester.pumpAndSettle();
      final table = button('contact-sync-preview-table');
      for (final (label, value) in [
        ('In Gmail now:', '340'),
        ('In Hadco now:', '412'),
        ('To be added to Hadco:', '120'),
        ('To be added to Gmail:', '45'),
        ('Already in both, to be paired up:', '300'),
        ('Of those, with details that differ, left as they are:', '12'),
        ('Need a look:', '4'),
        ('Deleted:', 'none'),
      ]) {
        expect(find.descendant(of: table, matching: find.text(label)),
            findsOneWidget, reason: label);
        final row = find.ancestor(
          of: find.descendant(of: table, matching: find.text(label)),
          matching: find.byType(Row),
        );
        expect(find.descendant(of: row, matching: find.text(value)),
            findsOneWidget, reason: '$label $value');
      }
      expect(enabled(tester, 'contact-sync-start'), isFalse,
          reason: 'no backup yet');

      // Backed out of the second file's dialog.
      files.answers.addAll([true, false]);
      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(files.saved, hasLength(2));
      expect(enabled(tester, 'contact-sync-start'), isFalse,
          reason: 'only one file is saved');
      expect(find.textContaining('Start sync needs both files'),
          findsOneWidget);

      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-start'), isTrue);
      expect(find.textContaining('Keep MyEmail open until this says Synced'),
          findsOneWidget);

      await tester.tap(button('contact-sync-start'));
      await tester.pumpAndSettle();
      expect(sync.count('start'), 1);
    });

    testWidgets('a preview that fails says why, with the way out',
        (tester) async {
      sync = FakeContactSync(status: chosenOnly)
        ..previewFailure = const ContactSyncFailed('No connection.');
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester, oauth: _grants());

      await tester.tap(button('contact-sync-preview'));
      await tester.pumpAndSettle();
      expect(find.text('No connection.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(sync.count('preview'), 2);

      sync.previewFailure = const ContactSyncNeedsSignIn(
        side: ContactSide.graph,
        accountId: 'acct-h',
        message: 'Hadco has not allowed contact sync yet.',
      );
      await tester.tap(button('contact-sync-preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in again'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(MicrosoftSignInScreen), findsOneWidget,
          reason: "the Microsoft account's Allow");
    });

    testWidgets('both backup files saved without a preview still leave Start '
        'greyed out', (tester) async {
      sync = FakeContactSync(status: chosenOnly, backupFiles: _backupFiles);
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(find.text('Both files are saved.'), findsNothing);
      expect(find.textContaining('Saved myemail-google-contacts'),
          findsOneWidget);
      expect(enabled(tester, 'contact-sync-start'), isFalse);
    });

    testWidgets('Save backup writes both files, each named and typed',
        (tester) async {
      sync = FakeContactSync(status: chosenOnly, backupFiles: _backupFiles);
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();

      expect(sync.count('backup'), 1);
      expect(files.saved, [
        (
          fileName: 'myemail-google-contacts-2026-11-21.vcf',
          contents: 'BEGIN:VCARD',
          mimeType: 'text/x-vcard',
          dialogTitle: "Save Gmail's contacts",
        ),
        (
          fileName: 'myemail-outlook-contacts-2026-11-21.csv',
          contents: '\u{FEFF}"First Name"',
          mimeType: 'text/csv',
          dialogTitle: "Save Hadco's contacts",
        ),
      ]);
      expect(
        find.text(
          'Saved myemail-google-contacts-2026-11-21.vcf, 340 contacts, which '
          'Google Contacts can import, and '
          'myemail-outlook-contacts-2026-11-21.csv, 412 contacts, which '
          'Outlook on the web can import.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('running: how far it has got', (tester) async {
      sync = FakeContactSync(status: synced(
        firstDone: false,
        running: const ContactSyncProgress(
          step: ContactSyncStep.writing,
          done: 12,
          total: 340,
          firstSync: true,
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('Copying changes: 12 of 340'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(button('contact-sync-progress'))
            .value,
        closeTo(12 / 340, 1e-9),
      );
      expect(find.textContaining('Keep MyEmail open until this says Synced'),
          findsOneWidget);
      expect(find.text('Start sync'), findsNothing);

      sync.set(synced(
        running: const ContactSyncProgress(step: ContactSyncStep.reading),
      ));
      // Not settled: a bar with no end to it moves for ever.
      await tester.pump();
      await tester.pump();
      expect(find.text('Reading both address books…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(button('contact-sync-progress'))
            .value,
        isNull,
      );
    });

    testWidgets('the last result, with Sync now', (tester) async {
      sync = FakeContactSync(status: synced(
        last: ContactSyncTally(
          at: at1042,
          addedToGraph: 2,
          changedGoogle: 1,
        ),
        googleCount: 340,
        graphCount: 412,
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      final clock = formatClock(at1042, use24h: false);
      expect(
        find.text('Synced at $clock: 2 added, 1 changed, none deleted'),
        findsOneWidget,
      );
      expect(
        find.text(
          'As the sync counts them, Gmail has 340 contacts and Hadco has '
          '412: for checking against Google Contacts and Outlook on the web.',
        ),
        findsOneWidget,
      );
      expect(find.text('First sync'), findsNothing);
      expect(find.textContaining("Turn this off before using Google's Undo"),
          findsOneWidget);

      await tester.tap(button('contact-sync-now'));
      await tester.pumpAndSettle();
      expect(sync.count('syncNow'), 1);
    });

    testWidgets('a first sync left unfinished says how far it got',
        (tester) async {
      sync = FakeContactSync(status: synced(
        firstDone: false,
        last: ContactSyncTally(
          at: at1042,
          complete: false,
          firstSync: true,
          planned: 340,
          done: 120,
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(
        find.text('The first sync got 120 of 340 changes done. It carries '
            'on when MyEmail is open.'),
        findsOneWidget,
      );
    });

    testWidgets('the other device syncing, with Sync here', (tester) async {
      sync = FakeContactSync(status: synced(
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.otherDevice,
          at: at1042,
          claimedAt: at1042.subtract(const Duration(hours: 1)),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('Contact sync is on on your other device'),
          findsOneWidget);
      expect(find.text('Sync now'), findsNothing,
          reason: 'it would only stop again');
      await tester.tap(button('contact-sync-here'));
      await tester.pumpAndSettle();
      expect(sync.count('syncHere'), 1);
    });

    testWidgets('a failed run says why, with Try again', (tester) async {
      sync = FakeContactSync(status: synced(
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at1042,
          error: const ContactSyncFailed('Hadco could not be reached.'),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('Hadco could not be reached.'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing,
          reason: 'Try again is the same, beside the reason');
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(sync.count('syncNow'), 1);
    });

    testWidgets('not allowed: the stop names the account, and Sign in again '
        'is its Allow', (tester) async {
      sync = FakeContactSync(status: synced(
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.notAllowed,
          at: at1042,
          side: ContactSide.graph,
          error: const ContactSyncNeedsSignIn(
            side: ContactSide.graph,
            accountId: 'acct-h',
            message: 'Hadco has not allowed contact sync.',
          ),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester, oauth: _grants());

      expect(find.text('Contact sync has stopped: not allowed yet for Hadco.'),
          findsOneWidget);
      await tester.tap(find.text('Sign in again'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(MicrosoftSignInScreen), findsOneWidget);
    });

    group("each brake's question", () {
      testWidgets('deletions: Delete them, or keep them unpaired',
          (tester) async {
        sync = FakeContactSync(status: synced(questions: [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.deletions,
            items: [
              for (final name in ['Ann', 'Ben', 'Cal', 'Dee', 'Eve', 'Fay'])
                ContactSyncQuestionItem(title: name, side: ContactSide.google),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(find.text('6 deletions need your OK'), findsOneWidget);
        expect(find.text('Ann: deleted in Gmail'), findsOneWidget);
        expect(find.textContaining('they stay in Hadco but stop syncing'),
            findsOneWidget);
        expect(find.text('Delete them'), findsOneWidget);

        await tester.tap(find.text("Don't delete them"));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.deletions, ContactSyncChoice.dontDelete),
        ]);
      });

      testWidgets('changes: Apply them, or Copy them back', (tester) async {
        sync = FakeContactSync(status: synced(questions: [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              for (var i = 0; i < 11; i++)
                ContactSyncQuestionItem(
                  title: 'Person $i',
                  side: ContactSide.graph,
                ),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(find.text('Changes to 11 contacts need your OK'),
            findsOneWidget);
        expect(find.text('Person 0: would lose details in Hadco'),
            findsOneWidget);
        expect(find.text('Apply them'), findsOneWidget);
        await tester.tap(find.text('Copy them back'));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.changes, ContactSyncChoice.copyThemBack),
        ]);
      });

      testWidgets("empty answers: That's right, carry on, or Keep waiting",
          (tester) async {
        sync = FakeContactSync(status: synced(
          halt: ContactSyncHalt(
            kind: ContactSyncHaltKind.emptyAnswer,
            at: at1042,
            side: ContactSide.graph,
          ),
          questions: const [
            ContactSyncQuestion(
              kind: ContactSyncQuestionKind.emptyAnswer,
              side: ContactSide.graph,
              listed: 3,
              expected: 120,
            ),
          ],
        ));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(find.text('Hadco listed only 3 contacts'), findsOneWidget);
        expect(find.textContaining('120 were expected'), findsOneWidget);
        expect(find.text('Sync now'), findsNothing,
            reason: 'it would only stop again before the answer');
        expect(find.text('Keep waiting'), findsOneWidget);
        await tester.tap(find.text("That's right, carry on"));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.emptyAnswer, ContactSyncChoice.carryOn),
        ]);
      });

      testWidgets('an answer waiting for the next sync shows no buttons',
          (tester) async {
        sync = FakeContactSync(status: synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.deletions,
            items: [
              ContactSyncQuestionItem(title: 'Ann', side: ContactSide.graph),
            ],
            answer: ContactSyncChoice.deleteThem,
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(find.text('Ann: gone from Hadco'), findsOneWidget);
        expect(
          find.text('You chose Delete them. The next sync carries it out.'),
          findsOneWidget,
        );
        expect(find.text("Don't delete them"), findsNothing);
      });
    });

    testWidgets('Needs a look: each item with its answers', (tester) async {
      sync = FakeContactSync(status: synced(looks: const [
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.newContact,
          reason: ContactReviewReason.sameName,
          side: ContactSide.google,
          title: 'Dana Levi',
          candidates: [
            ContactSyncCandidate(id: 'h-1', title: 'Dana Levi (Haifa)'),
            ContactSyncCandidate(id: 'h-2', title: 'Dana Levi (Tel Aviv)'),
          ],
          choices: [
            ContactSyncChoice.samePerson,
            ContactSyncChoice.copyAnyway,
            ContactSyncChoice.leaveOut,
          ],
        ),
        ContactSyncLook(
          id: 2,
          kind: ContactReviewKind.differing,
          title: 'Ori Cohen',
          fields: [ContactField.mobile],
          googleValues: {ContactField.mobile: '+972 50 111 2222'},
          graphValues: {ContactField.mobile: '+972 50 111 3333'},
          choices: [
            ContactSyncChoice.useGoogle,
            ContactSyncChoice.useGraph,
            ContactSyncChoice.leaveAsTheyAre,
          ],
        ),
        ContactSyncLook(
          id: 3,
          kind: ContactReviewKind.differing,
          title: 'Tal Mor',
          fields: [ContactField.jobTitle],
          googleValues: {ContactField.jobTitle: 'Buyer'},
          choices: [
            ContactSyncChoice.useGoogle,
            ContactSyncChoice.useGraph,
            ContactSyncChoice.leaveAsTheyAre,
          ],
        ),
        ContactSyncLook(
          id: 4,
          kind: ContactReviewKind.clash,
          title: 'Avi Ben',
          fields: [ContactField.company],
          googleValues: {ContactField.company: 'Hadco Metals Inc'},
          graphValues: {ContactField.company: 'Hadco Metals Inc'},
          losing: 'Hadco Metal',
          losingSide: ContactSide.graph,
          choices: [ContactSyncChoice.useOther, ContactSyncChoice.keepNewer],
        ),
        ContactSyncLook(
          id: 5,
          kind: ContactReviewKind.kept,
          reason: ContactReviewReason.changedSince,
          side: ContactSide.google,
          title: 'Noa Gal',
          choices: [
            ContactSyncChoice.copyBack,
            ContactSyncChoice.deleteHereToo,
            ContactSyncChoice.keepOnlyHere,
          ],
        ),
        ContactSyncLook(
          id: 6,
          kind: ContactReviewKind.refused,
          side: ContactSide.graph,
          title: 'Long Notes',
          choices: [ContactSyncChoice.retry],
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      await tester.tap(find.text('Needs a look (6)'));
      await tester.pumpAndSettle();

      expect(
        find.text('New in Gmail. Hadco has a contact with the same name and '
            'nothing else in common.'),
        findsOneWidget,
      );
      expect(find.text('Copy it anyway'), findsOneWidget);
      await tester.tap(find.text('Same person as Dana Levi (Tel Aviv)'));
      await tester.pumpAndSettle();

      expect(find.text('Gmail: +972 50 111 2222'), findsOneWidget);
      expect(find.text('Hadco: +972 50 111 3333'), findsOneWidget);
      expect(find.text('Hadco: (none)'), findsOneWidget);
      await tester.tap(button('contact-sync-look:2:useGraph'));
      await tester.pumpAndSettle();
      await tester.tap(button('contact-sync-all:leaveAsTheyAre'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Hadco had: Hadco Metal'), findsOneWidget);
      await tester.tap(find.text("Use Hadco's instead"));
      await tester.pumpAndSettle();

      expect(find.text('Deleted in Gmail, changed in Hadco since: kept.'),
          findsOneWidget);
      expect(find.text('Copy it back'), findsOneWidget);
      expect(find.text('Keep it only in Hadco'), findsOneWidget);
      await tester.tap(find.text('Delete it in Hadco too'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not copy to Hadco'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(sync.lookAnswers, [
        (id: 1, choice: ContactSyncChoice.samePerson, candidateId: 'h-2'),
        (id: 2, choice: ContactSyncChoice.useGraph, candidateId: null),
        (id: 4, choice: ContactSyncChoice.useOther, candidateId: null),
        (id: 5, choice: ContactSyncChoice.deleteHereToo, candidateId: null),
        (id: 6, choice: ContactSyncChoice.retry, candidateId: null),
      ]);
      expect(sync.allDiffering, [ContactSyncChoice.leaveAsTheyAre]);
    });

    testWidgets('Recently deleted, with Restore', (tester) async {
      sync = FakeContactSync(status: synced(deleted: [
        ContactSyncDeleted(
          id: 7,
          title: 'Rina Dar',
          side: ContactSide.graph,
          state: ContactSyncDeletedState.deleted,
          deletedAt: at1042,
        ),
        const ContactSyncDeleted(
          id: 8,
          title: 'Yossi Bar',
          side: ContactSide.google,
          state: ContactSyncDeletedState.back,
        ),
        const ContactSyncDeleted(
          id: 9,
          title: 'Gil Or',
          side: ContactSide.google,
          state: ContactSyncDeletedState.deleted,
          restoreAsked: true,
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      await tester.tap(find.text('Recently deleted (3)'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Outlook's fax, pager and anniversary"),
          findsOneWidget);
      expect(
        find.text('Deleted from Hadco at ${formatClock(at1042, use24h: false)}'),
        findsOneWidget,
      );
      expect(find.text('Already back'), findsOneWidget);
      expect(find.textContaining('Restore asked for'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget,
          reason: 'only the one not back and not asked for');

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(sync.restored, [7]);
    });

    testWidgets('a second Microsoft account can be chosen instead',
        (tester) async {
      sync = FakeContactSync(status: chosenOnly);
      engine = _Engine(sync, const [gmail, hadco, studio]);
      await pumpScreen(tester);

      await tester.tap(button('contact-sync-with'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Myhomestudio'));
      await tester.pumpAndSettle();

      expect(sync.chosen.last, (google: 'acct-g', graph: 'acct-m'));
      expect(button('contact-sync-access:acct-m'), findsOneWidget);
    });

    testWidgets('fits at the largest text on a phone, every part of it',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.15;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await ui.writeString(
        UiStateKeys.display,
        jsonEncode(
          const DisplaySettings(textSize: TextSize.extraLarge).toJson(),
        ),
      );
      sync = FakeContactSync(status: synced(
        last: ContactSyncTally(at: at1042, addedToGraph: 2, paired: 300),
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at1042,
          error: const ContactSyncFailed('Hadco could not be reached.'),
        ),
        questions: [
          for (final kind in ContactSyncQuestionKind.values)
            ContactSyncQuestion(
              kind: kind,
              side: ContactSide.graph,
              listed: 3,
              expected: 120,
              items: const [
                ContactSyncQuestionItem(
                  title: 'Alexandra Rosenblum-Katzenellenbogen',
                  side: ContactSide.graph,
                ),
              ],
            ),
        ],
        looks: const [
          ContactSyncLook(
            id: 1,
            kind: ContactReviewKind.newContact,
            reason: ContactReviewReason.namesDisagree,
            side: ContactSide.graph,
            title: 'Alexandra Rosenblum-Katzenellenbogen',
            candidates: [
              ContactSyncCandidate(id: 'g', title: 'Alexandra Rosenblum'),
            ],
            choices: [
              ContactSyncChoice.samePerson,
              ContactSyncChoice.copyAnyway,
              ContactSyncChoice.leaveOut,
            ],
          ),
        ],
        deleted: [
          ContactSyncDeleted(
            id: 1,
            title: 'Alexandra Rosenblum-Katzenellenbogen',
            side: ContactSide.graph,
            state: ContactSyncDeletedState.deleted,
            deletedAt: at1042.subtract(const Duration(days: 3)),
          ),
        ],
        googleCount: 1340,
        graphCount: 1412,
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await ui.writeString(UiStateKeys.contactSyncDevice, 'on');
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: (context, child) => AppTextSize(child: child!),
          home: const ContactSyncScreen(),
        ),
      ));
      await tester.pumpAndSettle();

      // An overflow anywhere is reported by the framework and fails the
      // test; each part is scrolled to so that it is laid out.
      final list = find.byType(Scrollable).first;
      for (final part in [
        find.text('Delete them'),
        find.text('Copy them back'),
        find.text("That's right, carry on"),
        find.textContaining("Turn this off before using Google's Undo"),
      ]) {
        await tester.scrollUntilVisible(part, 300, scrollable: list);
      }
      await tester.tap(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Same person'), findsOneWidget);
      Navigator.of(tester.element(find.text('Same person'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently deleted (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
    });
  });

  group('the Settings row', () {
    testWidgets('says Off, then how it went, and opens the screen',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sync = FakeContactSync(status: synced());
      final ui = MemoryUiStateStore();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(
          _Engine(sync, const [gmail, hadco]),
        ),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: SettingsScreen()),
      ));
      await tester.pumpAndSettle();

      Finder subtitle(String text) => find.descendant(
            of: find.ancestor(
              of: find.text('Contact sync'),
              matching: find.byType(ListTile),
            ),
            matching: find.text(text),
          );
      expect(subtitle('Off'), findsOneWidget);

      await c.read(contactSyncOnProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(
        subtitle('Gmail and Hadco, synced at '
            '${formatClock(at1042, use24h: false)}'),
        findsOneWidget,
      );

      sync.set(synced(questions: const [
        ContactSyncQuestion(
          kind: ContactSyncQuestionKind.deletions,
          items: [
            ContactSyncQuestionItem(title: 'Ann', side: ContactSide.google),
          ],
        ),
      ]));
      await tester.pumpAndSettle();
      expect(subtitle('1 deletion needs your OK'), findsOneWidget);

      await tester.tap(find.text('Contact sync'));
      await tester.pumpAndSettle();
      expect(find.byType(ContactSyncScreen), findsOneWidget);
    });
  });

  group('the shell', () {
    late FakeContactSync sync;
    late MemoryUiStateStore ui;
    late StreamController<void> putAway;

    setUp(() {
      ui = MemoryUiStateStore();
      putAway = StreamController<void>.broadcast();
      addTearDown(putAway.close);
    });

    Future<void> pumpApp(WidgetTester tester, {bool on = true}) async {
      if (on) await ui.writeString(UiStateKeys.contactSyncDevice, 'on');
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(_SampleWith(sync)),
        appPutAwayProvider.overrideWithValue(putAway.stream),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> away(WidgetTester tester) async {
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
    }

    Future<void> back(WidgetTester tester) async {
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('starts a run when MyEmail is opened, and again when it '
        'comes back, at most once an hour', (tester) async {
      sync = FakeContactSync(status: synced(
        lastDoneAt: today.subtract(const Duration(hours: 2)),
      ));
      sync.now = today;
      await pumpApp(tester);
      expect(sync.count('startIfDue'), 1);
      expect(sync.runs, 1);

      // Focus back only, the shade pushed up: not an opening.
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();
      expect(sync.count('startIfDue'), 1);

      await away(tester);
      sync.now = today.add(const Duration(minutes: 10));
      await back(tester);
      expect(sync.count('startIfDue'), 2);
      expect(sync.runs, 1, reason: 'ten minutes after the last run');

      await away(tester);
      sync.now = today.add(const Duration(minutes: 61));
      await back(tester);
      expect(sync.count('startIfDue'), 3);
      expect(sync.runs, 2);
    });

    testWidgets('switched off, it starts nothing and says nothing',
        (tester) async {
      sync = FakeContactSync(status: synced(
        lastDoneAt: today.subtract(const Duration(hours: 2)),
        notice: ContactSyncNotice(at: at1042, heldDeletions: 12),
      ));
      await pumpApp(tester, on: false);
      await away(tester);
      await back(tester);

      expect(sync.count('startIfDue'), 0);
      expect(find.textContaining('Contact sync has stopped'), findsNothing);
      expect(sync.noticesSeen, isEmpty);
    });

    testWidgets('put away, the run stops', (tester) async {
      sync = FakeContactSync(status: synced());
      await pumpApp(tester);
      expect(sync.count('stop'), 0);

      putAway.add(null);
      await tester.pumpAndSettle();
      expect(sync.count('stop'), 1);
    });

    testWidgets('says a stop once, with Open', (tester) async {
      final first = DateTime(today.year, today.month, today.day, 9);
      sync = FakeContactSync(status: synced(
        notice: ContactSyncNotice(at: first, heldDeletions: 12),
      ));
      await pumpApp(tester);

      expect(find.text('Contact sync has stopped: 12 deletions need your OK'),
          findsOneWidget);
      expect(sync.noticesSeen, [first]);

      ScaffoldMessenger.of(tester.element(find.byType(AppShell)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await away(tester);
      await back(tester);
      expect(find.textContaining('Contact sync has stopped'), findsNothing,
          reason: 'said once per stop');

      // Another stop, while MyEmail is in front.
      final second = first.add(const Duration(hours: 1));
      sync.set(synced(
        notice: ContactSyncNotice(at: second, heldChanges: 15),
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Contact sync has stopped: changes to 15 contacts need '
            'your OK'),
        findsOneWidget,
      );
      expect(sync.noticesSeen, [first, second]);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(ContactSyncScreen), findsOneWidget);
    });

    testWidgets('over the Contact sync screen, a stop is not said again',
        (tester) async {
      sync = FakeContactSync(status: synced());
      await pumpApp(tester);
      unawaited(tester.state<NavigatorState>(find.byType(Navigator).first)
          .push(MaterialPageRoute<void>(
        builder: (_) => const ContactSyncScreen(),
      )));
      await tester.pumpAndSettle();

      final at = DateTime(today.year, today.month, today.day, 9);
      sync.set(synced(notice: ContactSyncNotice(at: at, heldDeletions: 6)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Contact sync has stopped'), findsNothing);
      expect(sync.noticesSeen, [at], reason: 'the screen shows it already');
    });
  });

  group('the one-line message', () {
    test('names what stopped it', () {
      String? say(ContactSyncNotice n) =>
          contactSyncNoticeText(n, graphName: 'Hadco');
      expect(
        say(ContactSyncNotice(at: at1042, heldDeletions: 1)),
        'Contact sync has stopped: 1 deletion needs your OK',
      );
      expect(
        say(ContactSyncNotice(at: at1042, heldDeletions: 12, heldChanges: 1)),
        'Contact sync has stopped: 12 deletions and changes to 1 contact '
        'need your OK',
      );
      expect(
        say(ContactSyncNotice(
          at: at1042,
          halt: ContactSyncHalt(
            kind: ContactSyncHaltKind.notAllowed,
            at: at1042,
            side: ContactSide.graph,
          ),
        )),
        'Contact sync has stopped: not allowed yet for Hadco',
      );
      expect(
        say(ContactSyncNotice(
          at: at1042,
          halt: ContactSyncHalt(
            kind: ContactSyncHaltKind.otherDevice,
            at: at1042,
          ),
        )),
        'Contact sync is on on your other device',
      );
      expect(
        say(ContactSyncNotice(
          at: at1042,
          halt: ContactSyncHalt(kind: ContactSyncHaltKind.putAway, at: at1042),
        )),
        isNull,
      );
    });
  });
}

const _backupFiles = [
  ContactSyncBackupFile(
    side: ContactSide.google,
    fileName: 'myemail-google-contacts-2026-11-21.vcf',
    mimeType: 'text/x-vcard',
    contents: 'BEGIN:VCARD',
    count: 340,
  ),
  ContactSyncBackupFile(
    side: ContactSide.graph,
    fileName: 'myemail-outlook-contacts-2026-11-21.csv',
    mimeType: 'text/csv',
    contents: '\u{FEFF}"First Name"',
    count: 412,
  ),
];

/// A Microsoft that redeems any code for a token.
MicrosoftOAuth _grants() => MicrosoftOAuth(
      clientId: 'test-client',
      authority: 'https://login.example/common/oauth2/v2.0',
      httpClient: http_testing.MockClient((request) async => http.Response(
            jsonEncode({
              'access_token': 'access',
              'refresh_token': 'refresh',
              'expires_in': 3600,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          )),
    );

/// The sample engine with [accounts] and [contacts]' contact sync; a
/// sign-in again is noted.
class _Engine extends SampleMailEngine {
  _Engine(this.contacts, this.accounts);

  final FakeContactSync contacts;
  final List<Account> accounts;
  final List<String> signedInAgain = [];

  @override
  ContactSyncService get contactSync => contacts;

  @override
  Future<List<Account>> loadAccounts() async => accounts;

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
  }) async =>
      signedInAgain.add(accountId);
}

/// The sample engine, with its own accounts and mail, and [contacts]'
/// contact sync.
class _SampleWith extends SampleMailEngine {
  _SampleWith(this.contacts);

  final FakeContactSync contacts;

  @override
  ContactSyncService get contactSync => contacts;
}

/// The save dialogs, answered in turn by [answers] (saved when it runs
/// out), and what each was given.
class _Files implements BackupFiles {
  final List<bool> answers = [];
  final List<
      ({
        String fileName,
        String contents,
        String mimeType,
        String dialogTitle,
      })> saved = [];

  @override
  Future<bool> save({
    required String fileName,
    required String contents,
    String mimeType = 'application/json',
    String dialogTitle = 'Save MyEmail settings',
  }) async {
    saved.add((
      fileName: fileName,
      contents: contents,
      mimeType: mimeType,
      dialogTitle: dialogTitle,
    ));
    return answers.isEmpty ? true : answers.removeAt(0);
  }

  @override
  Future<String?> pick() async => null;
}
