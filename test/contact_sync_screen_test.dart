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
    bool firstStarted = true,
    int? googleCount,
    int? graphCount,
    ContactSyncNotice? notice,
    List<ContactSyncDuplicates> duplicates = const [],
    ContactSyncCopies copies = const ContactSyncCopies(),
  }) =>
      ContactSyncStatus(
        googleAccountId: gmail.id,
        graphAccountId: hadco.id,
        firstStartedAt:
            firstStarted ? at1042.subtract(const Duration(days: 3)) : null,
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
        duplicates: duplicates,
        copies: copies,
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
      ContactSyncQuestionItem item(String key, {ContactSyncChoice? answer}) =>
          ContactSyncQuestionItem(
            title: 'Person $key',
            side: ContactSide.graph,
            key: key,
            answer: answer,
          );
      expect(
        say(synced(questions: [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              item('a', answer: ContactSyncChoice.copyThemBack),
              item('b'),
              item('c'),
            ],
          ),
        ])),
        'Changes to 2 contacts need your OK',
        reason: 'one answered on its own waits for the sync, not for Ron',
      );
      expect(
        say(synced(questions: [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.deletions,
            items: [
              item('a', answer: ContactSyncChoice.deleteThem),
              item('b', answer: ContactSyncChoice.dontDelete),
            ],
          ),
        ])),
        'Gmail and Hadco, synced at 10:42',
        reason: 'every contact answered on its own',
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

    test('a stop that names no side names no account at a guess', () {
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.notAllowed,
          at: at1042,
          error: const ContactSyncNeedsSignIn(
            side: ContactSide.google,
            accountId: 'acct-g',
            message: 'Gmail has not allowed contact sync.',
          ),
        ))),
        'Not allowed yet for Gmail',
        reason: 'the failure names it',
      );
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.notAllowed,
          at: at1042,
        ))),
        'Not allowed yet for one of the accounts',
      );
      expect(
        say(synced(halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.emptyAnswer,
          at: at1042,
        ))),
        'Stopped: one address book listed too few contacts',
      );
      expect(
        contactSyncNoticeText(
          ContactSyncNotice(
            at: at1042,
            halt: ContactSyncHalt(
              kind: ContactSyncHaltKind.notAllowed,
              at: at1042,
            ),
          ),
          graphName: 'Hadco',
        ),
        'Contact sync has stopped: not allowed yet for one of the accounts',
      );
      expect(
        contactSyncNoticeText(
          ContactSyncNotice(
            at: at1042,
            halt: ContactSyncHalt(
              kind: ContactSyncHaltKind.emptyAnswer,
              at: at1042,
            ),
          ),
          graphName: 'Hadco',
        ),
        'Contact sync has stopped: one address book listed far fewer '
        'contacts than before',
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

    testWidgets('with no pair yet and two Microsoft accounts, nothing is '
        'guessed: Ron picks one before anything can start', (tester) async {
      sync = FakeContactSync();
      engine = _Engine(sync, const [gmail, studio, hadco]);
      await pumpScreen(tester);

      expect(
        find.descendant(
          of: button('contact-sync-with'),
          matching: find.text('Choose the Microsoft account'),
        ),
        findsOneWidget,
      );
      expect(button('contact-sync-access:acct-g'), findsOneWidget);
      expect(button('contact-sync-access:acct-h'), findsNothing);
      expect(button('contact-sync-access:acct-m'), findsNothing);
      expect(button('contact-sync-choose-first'), findsOneWidget);
      expect(find.textContaining('Worth knowing'), findsNothing,
          reason: "no \"the Microsoft account's IT\" before one is chosen");
      for (final key in [
        'contact-sync-preview',
        'contact-sync-backup',
        'contact-sync-start',
      ]) {
        expect(enabled(tester, key), isFalse, reason: key);
      }
      expect(sync.chosen, isEmpty);

      await tester.tap(button('contact-sync-with'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hadco'));
      await tester.pumpAndSettle();
      expect(sync.chosen, [(google: 'acct-g', graph: 'acct-h')]);
      expect(button('contact-sync-access:acct-h'), findsOneWidget);
      expect(button('contact-sync-choose-first'), findsNothing);
      expect(enabled(tester, 'contact-sync-preview'), isTrue);
      expect(find.textContaining("where Hadco's IT can see them"),
          findsOneWidget);
    });

    testWidgets('with no pair yet and two Gmail accounts, Ron picks one',
        (tester) async {
      const second = Account(
        id: 'acct-g2',
        displayName: 'Family',
        emailAddress: 'family@gmail.example',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFFC239B3,
      );
      sync = FakeContactSync();
      engine = _Engine(sync, const [gmail, second, hadco]);
      await pumpScreen(tester);

      expect(
        find.descendant(
          of: button('contact-sync-google'),
          matching: find.text('Choose the Gmail account'),
        ),
        findsOneWidget,
      );
      expect(button('contact-sync-access:acct-g'), findsNothing);
      expect(enabled(tester, 'contact-sync-preview'), isFalse);
      expect(sync.chosen, isEmpty);
    });

    testWidgets('with one account of each the pair is plain, and Preview '
        'chooses it', (tester) async {
      sync = FakeContactSync();
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(
        find.descendant(
          of: button('contact-sync-with'),
          matching: find.text('Hadco'),
        ),
        findsOneWidget,
      );
      expect(sync.chosen, isEmpty);
      await tester.tap(button('contact-sync-preview'));
      await tester.pumpAndSettle();
      expect(sync.chosen, [(google: 'acct-g', graph: 'acct-h')]);
      expect(button('contact-sync-preview-table'), findsOneWidget);
      expect(find.textContaining('Copies of the same person'), findsNothing,
          reason: 'said only where there are some');
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

    testWidgets('a Gmail account signed in with Google that cannot sync is '
        'not said to be on an app password', (tester) async {
      sync = FakeContactSync(status: chosenOnly, access: {
        'acct-g': const ContactSyncAccess(ContactSyncAccessState.notPossible),
      });
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      final row = button('contact-sync-access:acct-g');
      expect(
        find.descendant(
          of: row,
          matching: find.text('Not possible for this account.'),
        ),
        findsOneWidget,
      );
      expect(find.descendant(of: row, matching: find.text('Allow')),
          findsNothing);
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
          duplicateCopies: 37,
        ),
        backupFiles: _backupFiles,
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('First sync'), findsOneWidget);
      expect(button('contact-sync-backup-later'), findsNothing);
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
        ('Copies of the same person, left as they are:', '37'),
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

    testWidgets('a preview or a backup over an hour old is asked for again',
        (tester) async {
      sync = FakeContactSync(status: chosenOnly);
      engine = _Engine(sync, const [gmail, hadco]);
      final c = await pumpScreen(tester);
      final steps = c.read(contactSyncFirstStepsProvider.notifier);
      const pair = 'acct-g|acct-h';
      final now = DateTime.now();
      final old = now.subtract(const Duration(minutes: 61));
      String note() => tester
          .widget<Text>(find.descendant(
            of: button('contact-sync-start-note'),
            matching: find.byType(Text),
          ))
          .data!;

      steps.previewed(pair, const ContactSyncPreview(), at: old);
      steps.backupSaved(pair, ContactSide.google, at: now);
      steps.backupSaved(pair, ContactSide.graph, at: now);
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-start'), isFalse);
      expect(
        note(),
        'The preview is over an hour old, and the address books may have '
        'changed since: Preview again.',
      );

      steps.previewed(pair, const ContactSyncPreview(), at: now);
      steps.backupSaved(pair, ContactSide.graph, at: old);
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-start'), isFalse);
      expect(
        note(),
        'The backup files are over an hour old: Save backup again, so that '
        'they hold the address books as they are now.',
      );

      steps.backupSaved(pair, ContactSide.graph, at: now);
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-start'), isTrue);
      await tester.tap(button('contact-sync-start'));
      await tester.pumpAndSettle();
      expect(sync.count('start'), 1);
    });

    testWidgets('Start tapped twice asks for one first sync', (tester) async {
      sync = FakeContactSync(status: chosenOnly)..startGate = Completer<void>();
      engine = _Engine(sync, const [gmail, hadco]);
      final c = await pumpScreen(tester);
      final steps = c.read(contactSyncFirstStepsProvider.notifier);
      steps.previewed('acct-g|acct-h', const ContactSyncPreview());
      steps.backupSaved('acct-g|acct-h', ContactSide.google);
      steps.backupSaved('acct-g|acct-h', ContactSide.graph);
      await tester.pumpAndSettle();

      await tester.tap(button('contact-sync-start'));
      await tester.pump();
      await tester.tap(button('contact-sync-start'));
      await tester.pumpAndSettle();
      expect(sync.count('start'), 1);

      // The run ended without the status moving on: Start again.
      sync.startGate!.complete();
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-start'), isTrue);
    });

    testWidgets('a backup handed over with one side only does not count as '
        'both files', (tester) async {
      sync = FakeContactSync(
        status: chosenOnly,
        backupFiles: [_backupFiles.first],
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(button('contact-sync-preview'));
      await tester.pumpAndSettle();
      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Start sync needs both files'),
          findsOneWidget);
      expect(enabled(tester, 'contact-sync-start'), isFalse);
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

    testWidgets('after the first sync, Save backup is still offered',
        (tester) async {
      sync = FakeContactSync(
        status: synced(googleCount: 340, graphCount: 412),
        backupFiles: _backupFiles,
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('First sync'), findsNothing);
      expect(
        find.text('Two files, one Google Contacts can import and one Outlook '
            'on the web can import.'),
        findsOneWidget,
      );
      await tester.tap(button('contact-sync-backup-later'));
      await tester.pumpAndSettle();
      expect(sync.count('backup'), 1);
      expect(
        [
          for (final f in files.saved) (f.fileName, f.mimeType),
        ],
        [
          ('myemail-google-contacts-2026-11-21.vcf', 'text/x-vcard'),
          ('myemail-outlook-contacts-2026-11-21.csv', 'text/csv'),
        ],
      );
      expect(
        find.text(
          'Saved myemail-google-contacts-2026-11-21.vcf, 340 contacts, which '
          'Google Contacts can import, and '
          'myemail-outlook-contacts-2026-11-21.csv, 412 contacts, which '
          'Outlook on the web can import.',
        ),
        findsOneWidget,
      );

      // One file backed out of: said, and nothing about Start.
      files.answers.addAll([true, false]);
      await tester.tap(button('contact-sync-backup-later'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Saved myemail-google-contacts-2026-11-21.vcf, 340 contacts, which '
          'Google Contacts can import. The other file was not saved: Save '
          'backup again for both.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('two tries that saved one file each have saved both, and '
        "the first sync's message stays with its own Save backup",
        (tester) async {
      sync = FakeContactSync(
        status: chosenOnly,
        previewAnswer: const ContactSyncPreview(
          googleListed: 340,
          graphListed: 412,
        ),
        backupFiles: _backupFiles,
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(button('contact-sync-preview'));
      await tester.pumpAndSettle();

      files.answers.addAll([true, false]);
      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Saved myemail-google-contacts-2026-11-21.vcf, 340 contacts, which '
          'Google Contacts can import. Start sync needs both files: Save '
          'backup again.',
        ),
        findsOneWidget,
      );
      files.answers.addAll([false, true]);
      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Saved myemail-outlook-contacts-2026-11-21.csv, 412 contacts, which '
          'Outlook on the web can import. Both files are saved.',
        ),
        findsOneWidget,
      );
      expect(enabled(tester, 'contact-sync-start'), isTrue);

      // Started: the later Save backup has no message of its own yet.
      await tester.tap(button('contact-sync-start'));
      await tester.pumpAndSettle();
      expect(sync.count('start'), 1);
      sync.set(synced(googleCount: 340, graphCount: 412));
      await tester.pumpAndSettle();
      expect(button('contact-sync-backup-later'), findsOneWidget);
      expect(find.textContaining('Saved myemail-'), findsNothing);
    });

    testWidgets('one file saved over an hour ago is left to the note under '
        'Start', (tester) async {
      sync = FakeContactSync(status: chosenOnly, backupFiles: _backupFiles);
      engine = _Engine(sync, const [gmail, hadco]);
      final c = await pumpScreen(tester);
      const pair = 'acct-g|acct-h';
      c.read(contactSyncFirstStepsProvider.notifier)
        ..previewed(pair, const ContactSyncPreview())
        ..backupSaved(
          pair,
          ContactSide.google,
          at: DateTime.now().subtract(const Duration(minutes: 61)),
        );
      await tester.pumpAndSettle();

      files.answers.addAll([false, true]);
      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Saved myemail-outlook-contacts-2026-11-21.csv, 412 contacts, which '
          'Outlook on the web can import.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Both files are saved'), findsNothing);
      expect(find.textContaining('Start sync needs both files'), findsNothing);
      expect(enabled(tester, 'contact-sync-start'), isFalse);
      expect(
        tester
            .widget<Text>(find.descendant(
              of: button('contact-sync-start-note'),
              matching: find.byType(Text),
            ))
            .data,
        'The backup files are over an hour old: Save backup again, so that '
        'they hold the address books as they are now.',
      );
    });

    testWidgets("a Save backup's message stays with its pair",
        (tester) async {
      sync = FakeContactSync(status: chosenOnly, backupFiles: _backupFiles);
      engine = _Engine(sync, const [gmail, hadco, studio]);
      await pumpScreen(tester);

      await tester.tap(button('contact-sync-backup'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved myemail-'), findsOneWidget);

      await tester.tap(button('contact-sync-with'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Myhomestudio'));
      await tester.pumpAndSettle();
      expect(sync.chosen.last, (google: 'acct-g', graph: 'acct-m'));
      expect(find.text('First sync'), findsOneWidget);
      expect(find.textContaining('Saved myemail-'), findsNothing,
          reason: "Myhomestudio's files are not saved");
      expect(enabled(tester, 'contact-sync-start'), isFalse);
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

    testWidgets("running: merging Hadco's copies, a person at a time",
        (tester) async {
      sync = FakeContactSync(status: synced(
        running: const ContactSyncProgress(
          step: ContactSyncStep.merging,
          done: 120,
          total: 1336,
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text("Merging Hadco's copies: 120 of 1336 people"),
          findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(button('contact-sync-progress'))
            .value,
        closeTo(120 / 1336, 1e-9),
      );
      expect(find.text('Reading both address books…'), findsNothing);

      sync.set(synced(
        running: const ContactSyncProgress(step: ContactSyncStep.merging),
      ));
      // Not settled: a bar with no end to it moves for ever.
      await tester.pump();
      await tester.pump();
      expect(find.text("Merging Hadco's copies…"), findsOneWidget);
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
      expect(button('contact-sync-duplicates'), findsNothing,
          reason: 'no copies of anyone, no row for them');

      await tester.tap(button('contact-sync-now'));
      await tester.pumpAndSettle();
      expect(sync.count('syncNow'), 1);
    });

    testWidgets('the result says what was left for the next sync',
        (tester) async {
      sync = FakeContactSync(status: synced(
        last: ContactSyncTally(at: at1042, addedToGraph: 2, passedOver: 3),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(
        find.text('Synced at ${formatClock(at1042, use24h: false)}: 2 added, '
            'none changed, none deleted, 3 in Hadco could not be read whole, '
            'left for the next sync'),
        findsOneWidget,
      );
    });

    testWidgets('a copy of a contact that no longer syncs says so, with '
        'the kept answers', (tester) async {
      // Its pair may have gone, or been renamed away from it: nothing is
      // said to have been deleted.
      sync = FakeContactSync(status: synced(looks: const [
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.kept,
          reason: ContactReviewReason.copyOfGone,
          side: ContactSide.google,
          title: 'Ann Cole',
          choices: [
            ContactSyncChoice.copyBack,
            ContactSyncChoice.deleteHereToo,
            ContactSyncChoice.keepOnlyHere,
          ],
        ),
        ContactSyncLook(
          id: 2,
          kind: ContactReviewKind.kept,
          reason: ContactReviewReason.copyOfGone,
          side: ContactSide.graph,
          title: 'Bob Day',
          choices: [ContactSyncChoice.copyBack],
        ),
        ContactSyncLook(
          id: 3,
          kind: ContactReviewKind.kept,
          reason: ContactReviewReason.copyOfGone,
          title: 'Cy Fox',
          choices: [ContactSyncChoice.copyBack],
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (3)'));
      await tester.pumpAndSettle();

      // Each names the side its copy is on: the other from the item's.
      for (final (id, line) in [
        (
          1,
          'A copy of a contact that no longer syncs: its synced copy went, '
              'or no longer matches it. This copy in Hadco was left as it is.',
        ),
        (
          2,
          'A copy of a contact that no longer syncs: its synced copy went, '
              'or no longer matches it. This copy in Gmail was left as it is.',
        ),
        (
          3,
          'A copy of a contact that no longer syncs: its synced copy went, '
              'or no longer matches it. This copy was left as it is.',
        ),
      ]) {
        expect(
          find.descendant(
            of: button('contact-sync-look:$id'),
            matching: find.text(line),
          ),
          findsOneWidget,
          reason: line,
        );
      }
      // Ann's copy is in Hadco: the answers name it.
      expect(find.text('Keep it only in Hadco'), findsOneWidget);
      await tester.tap(find.text('Delete it in Hadco too'));
      await tester.pumpAndSettle();
      expect(sync.lookAnswers, [
        (id: 1, choice: ContactSyncChoice.deleteHereToo, candidateId: null),
      ]);
    });

    testWidgets('a kept contact whose side is not known offers no button '
        'naming a side', (tester) async {
      sync = FakeContactSync(status: synced(looks: const [
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.kept,
          title: 'Noa Gal',
          choices: [
            ContactSyncChoice.copyBack,
            ContactSyncChoice.deleteHereToo,
            ContactSyncChoice.keepOnlyHere,
          ],
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Copy it back'), findsOneWidget);
      expect(find.textContaining('Delete it in'), findsNothing);
      expect(find.textContaining('Keep it only in'), findsNothing);
      expect(find.text('Deleted on one side, kept on the other.'),
          findsOneWidget,
          reason: 'not "Deleted in Gmail, kept in Hadco" at a guess');
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
        last: ContactSyncTally(at: at1042, addedToGraph: 1),
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at1042,
          error: const ContactSyncFailed('Hadco could not be reached.'),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('Hadco could not be reached.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.textContaining('The last sync stopped')).dy,
        lessThan(tester.getTopLeft(button('contact-sync-last')).dy),
        reason: 'the stop above "Synced at", which would read as all well',
      );
      expect(find.text('Sync now'), findsNothing,
          reason: 'Try again is the same, beside the reason');
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(sync.count('syncNow'), 1);
    });

    testWidgets('a failure not worth trying again keeps Sync now',
        (tester) async {
      sync = FakeContactSync(status: synced(
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at1042,
          error: const ContactSyncRefused(
            'The People API is off in the Cloud project.',
          ),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('The People API is off in the Cloud project.'),
          findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      await tester.tap(find.text('Sync now'));
      await tester.pumpAndSettle();
      expect(sync.count('syncNow'), 1);
    });

    testWidgets('a stop before the first sync has started is shown too',
        (tester) async {
      sync = FakeContactSync(status: synced(
        firstDone: false,
        firstStarted: false,
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.otherDevice,
          at: at1042,
          claimedAt: at1042.subtract(const Duration(hours: 2)),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      final c = await pumpScreen(tester);

      expect(find.text('First sync'), findsOneWidget);
      expect(find.text('Contact sync is on on your other device'),
          findsOneWidget);
      // Sync here would start the first sync: not without Start's preview
      // and backup from the last hour (the tablet the next day, say).
      expect(enabled(tester, 'contact-sync-here'), isFalse);
      expect(
        find.text('To sync here instead, see the preview and save the backup '
            'below first.'),
        findsOneWidget,
      );
      final steps = c.read(contactSyncFirstStepsProvider.notifier);
      steps.previewed('acct-g|acct-h', const ContactSyncPreview());
      steps.backupSaved('acct-g|acct-h', ContactSide.google);
      steps.backupSaved('acct-g|acct-h', ContactSide.graph);
      await tester.pumpAndSettle();
      expect(button('contact-sync-here-note'), findsNothing);
      await tester.tap(button('contact-sync-here'));
      await tester.pumpAndSettle();
      expect(sync.count('syncHere'), 1);

      sync.set(synced(
        firstDone: false,
        firstStarted: false,
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.notAllowed,
          at: at1042,
          side: ContactSide.graph,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Contact sync has stopped: not allowed yet for Hadco.'),
          findsOneWidget);
    });

    testWidgets('a failure before the first sync has started offers no Try '
        'again: a run goes only through Start', (tester) async {
      sync = FakeContactSync(status: synced(
        firstDone: false,
        firstStarted: false,
        halt: ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at1042,
          error: const ContactSyncFailed('Hadco could not be reached.'),
        ),
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(
        find.text('The first sync could not begin: it stopped at '
            '${formatClock(at1042, use24h: false)}.'),
        findsOneWidget,
      );
      expect(find.text('Hadco could not be reached.'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('Start sync'), findsOneWidget);
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
        expect(
          find.text('One sync would remove or replace details in Hadco on '
              "these contacts at once, as Google's Undo changes, a backup "
              'imported again or a bulk edit can, so they are held for your '
              'OK, and everything else carries on. Under each name, each '
              'detail as it is in Hadco now, and what it would become.'),
          findsOneWidget,
        );
        expect(find.text('Person 0'), findsOneWidget);
        expect(find.text('Apply them'), findsOneWidget);
        await tester.tap(find.text('Copy them back'));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.changes, ContactSyncChoice.copyThemBack),
        ]);
      });

      testWidgets('changes: each contact says what it would lose, and can be '
          'answered alone', (tester) async {
        sync = FakeContactSync(status: synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              ContactSyncQuestionItem(
                title: 'Ann Cole',
                side: ContactSide.graph,
                key: 'a',
                changes: [
                  ContactSyncDetailChange(
                    field: ContactField.jobTitle,
                    before: 'Sales manager',
                    after: 'Purchasing manager',
                  ),
                  ContactSyncDetailChange(
                    field: ContactField.mobile,
                    before: '+1 555 123 4567',
                  ),
                  // A note too long to show, as the planner sends it.
                  ContactSyncDetailChange(
                    field: ContactField.notes,
                    after: 'changed',
                  ),
                ],
              ),
              ContactSyncQuestionItem(
                title: 'Ben Day',
                side: ContactSide.graph,
                key: 'b',
                changes: [
                  ContactSyncDetailChange(
                    field: ContactField.company,
                    before: 'Hadco Metal',
                    after: 'Hadco Metals Inc',
                  ),
                  ContactSyncDetailChange(
                    field: ContactField.workAddress,
                    before: '1200 Peachtree Industrial Boulevard, Suite 400, '
                        'Building C, Atlanta GA 30341',
                  ),
                  ContactSyncDetailChange(field: ContactField.notes),
                ],
              ),
              // Held before details were kept: shown after the next run.
              ContactSyncQuestionItem(
                title: 'Cy Fox',
                side: ContactSide.graph,
                key: 'c',
              ),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(
          find.text('One sync would remove or replace details in Hadco on '
              "these contacts at once, as Google's Undo changes, a backup "
              'imported again or a bulk edit can, so they are held for your '
              'OK, and everything else carries on. Under each name, each '
              'detail as it is in Hadco now, and what it would become.'),
          findsOneWidget,
        );
        expect(
          find.text('Apply makes these changes in Hadco. Copy back keeps '
              'what Hadco has and puts it back in Gmail, except a detail '
              'changed on both sides; a list only gains, so a replaced address '
              'leaves both. Either way each contact is read again first.'),
          findsOneWidget,
        );
        expect(find.text('For all 3 at once:'), findsOneWidget);

        Finder under(String key, String text) => find.descendant(
              of: button('contact-sync-item:$key'),
              matching: find.text(text),
            );
        expect(under('a', 'Ann Cole'), findsOneWidget);
        expect(
          under('a', 'Job title: Sales manager → Purchasing manager'),
          findsOneWidget,
        );
        expect(under('a', 'Mobile: +1 555 123 4567 → removed'),
            findsOneWidget);
        expect(under('a', 'Notes: changed'), findsOneWidget,
            reason: 'a note too long to show: changed, not "(none)"');
        expect(under('b', 'Notes: removed (too long to show here)'),
            findsOneWidget);
        expect(
          under(
            'b',
            'Work address: 1200 Peachtree Industrial Boulevard, Suite 400, '
                'Building C,… → removed',
          ),
          findsOneWidget,
          reason: 'a long value on one line, shortened',
        );
        expect(find.textContaining('(none)'), findsNothing);
        expect(
          under('b', 'Company: Hadco Metal → Hadco Metals Inc'),
          findsOneWidget,
        );
        expect(under('c', 'The details show after the next sync.'),
            findsOneWidget);
        // Wide, its buttons sit beside the contact, not under its details.
        expect(
          tester.getTopLeft(button('contact-sync-item:a:copyThemBack')).dy,
          lessThan(tester.getTopLeft(under('a',
                  'Job title: Sales manager → Purchasing manager')).dy),
        );

        // Ann alone, put back as she is in Hadco.
        await tester.tap(button('contact-sync-item:a:copyThemBack'));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.changes, ContactSyncChoice.copyThemBack),
        ]);
        expect(sync.questionItems, [
          {'a'},
        ]);
      });

      testWidgets('an answer held up at the last run says why, under that '
          'answer', (tester) async {
        const unread =
            'Could not be read just now: it is carried out when it can be.';
        const away = 'Its Outlook contact is not in Contacts: it is carried '
            'out once it is back.';
        ContactSyncQuestionItem person(
          String key,
          String title, {
          ContactSide side = ContactSide.graph,
          ContactSyncChoice? answer,
          String? problem,
        }) =>
            ContactSyncQuestionItem(
              title: title,
              side: side,
              key: key,
              answer: answer,
              answerProblem: problem,
            );
        ContactSyncQuestion deletions(List<ContactSyncQuestionItem> items) =>
            ContactSyncQuestion(
              kind: ContactSyncQuestionKind.deletions,
              answer: ContactSyncChoice.deleteThem,
              items: items,
            );
        sync = FakeContactSync(status: synced(questions: [
          // Answered one by one: under the contact's own answer.
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              person(
                'a',
                'Ann Cole',
                answer: ContactSyncChoice.applyThem,
                problem: unread,
              ),
              person('b', 'Ben Day'),
            ],
          ),
          // Answered as a whole, held up for one reason: said once, under
          // the question's answer.
          deletions([
            person('c', 'Cy Fox', side: ContactSide.google, problem: away),
            person('d', 'Di Ray', side: ContactSide.google, problem: away),
          ]),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        double top(Finder f) => tester.getTopLeft(f).dy;
        final ann = button('contact-sync-item:a');
        final annChose = find.descendant(
          of: ann,
          matching: find.text('You chose Apply: the next sync carries it out.'),
        );
        expect(find.descendant(of: ann, matching: find.text(unread)),
            findsOneWidget);
        expect(top(find.text(unread)), greaterThan(top(annChose)));
        expect(
          tester.widget<Text>(find.text(unread)).style?.color,
          Theme.of(tester.element(find.text(unread)))
              .colorScheme
              .onSurfaceVariant,
          reason: 'muted',
        );
        expect(
          find.descendant(
            of: button('contact-sync-item:b'),
            matching: find.textContaining('carried out'),
          ),
          findsNothing,
        );

        final card = button('contact-sync-question:deletions');
        expect(find.descendant(of: card, matching: find.text(away)),
            findsOneWidget);
        expect(top(find.text(away)),
            greaterThan(top(button('contact-sync-question-answer'))));
        expect(top(find.text(away)), lessThan(top(button('contact-sync-item:c'))));

        // Two reasons, and a contact not held up: each named.
        sync.set(synced(questions: [
          deletions([
            person('c', 'Cy Fox', side: ContactSide.google, problem: away),
            person('d', 'Di Ray', side: ContactSide.google, problem: unread),
            person('e', 'Ed Kim', side: ContactSide.google),
          ]),
        ]));
        await tester.pumpAndSettle();
        expect(find.text('Cy Fox: $away'), findsOneWidget);
        expect(find.text('Di Ray: $unread'), findsOneWidget);
        // Its name in a line of its own: not the contact's own line.
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && (w.data?.startsWith('Ed Kim') ?? false),
          ),
          findsNothing,
          reason: 'Ed Kim was not held up',
        );
        expect(find.text(away), findsNothing);
        expect(top(find.text('Cy Fox: $away')),
            greaterThan(top(button('contact-sync-question-answer'))));
      });

      testWidgets('a contact answered alone shows its answer, and the buttons '
          'for all answer the rest', (tester) async {
        ContactSyncQuestionItem person(
          String key,
          String title, {
          ContactSyncChoice? answer,
        }) =>
            ContactSyncQuestionItem(
              title: title,
              side: ContactSide.graph,
              key: key,
              answer: answer,
              changes: const [
                ContactSyncDetailChange(
                  field: ContactField.jobTitle,
                  before: 'Buyer',
                ),
              ],
            );
        sync = FakeContactSync(status: synced(questions: [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              person('a', 'Ann Cole', answer: ContactSyncChoice.copyThemBack),
              person('b', 'Ben Day'),
              person('c', 'Cy Fox'),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(
          find.descendant(
            of: button('contact-sync-item:a'),
            matching: find.text(
              'You chose Copy back: the next sync carries it out.',
            ),
          ),
          findsOneWidget,
        );
        expect(button('contact-sync-item:a:applyThem'), findsNothing);
        expect(button('contact-sync-item:b:applyThem'), findsOneWidget);
        expect(find.text('For the 2 not yet answered:'), findsOneWidget);
        expect(find.text('Changes to 2 contacts need your OK'), findsOneWidget,
            reason: 'only those still waiting for Ron');

        await tester.tap(find.text('Apply them'));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.changes, ContactSyncChoice.applyThem),
        ]);
        expect(
          sync.questionItems,
          [
            {'b', 'c'},
          ],
          reason: 'the contacts shown with no answer of their own, never '
              'one held since',
        );

        // Answered for the rest: Ann keeps her own answer.
        sync.set(synced(questions: [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            answer: ContactSyncChoice.applyThem,
            items: [
              person('a', 'Ann Cole', answer: ContactSyncChoice.copyThemBack),
              person('b', 'Ben Day'),
              person('c', 'Cy Fox'),
            ],
          ),
        ]));
        await tester.pumpAndSettle();
        expect(
          find.text('You chose Apply them for the rest. The next sync '
              'carries it out.'),
          findsOneWidget,
        );
        expect(find.text('Changes to 3 contacts, all answered'),
            findsOneWidget);
        expect(button('contact-sync-item:b:applyThem'), findsNothing);
        expect(
          find.text('You chose Copy back: the next sync carries it out.'),
          findsOneWidget,
        );
      });

      testWidgets('deletions: each contact told apart, and answered alone',
          (tester) async {
        sync = FakeContactSync(status: synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.deletions,
            items: [
              ContactSyncQuestionItem(
                title: 'Ann Cole',
                side: ContactSide.google,
                key: 'a',
                hint: 'ann@cole.example',
              ),
              ContactSyncQuestionItem(
                title: 'Ann Cole',
                side: ContactSide.google,
                key: 'a2',
                hint: '+1 555 000 1111',
              ),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(
          find.descendant(
            of: button('contact-sync-item:a'),
            matching: find.text('ann@cole.example'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: button('contact-sync-item:a2'),
            matching: find.text('+1 555 000 1111'),
          ),
          findsOneWidget,
        );
        expect(find.text('Ann Cole: deleted in Gmail'), findsNWidgets(2));
        // Its own Delete says where: the body names no side.
        expect(
          find.descendant(
            of: button('contact-sync-item:a:deleteThem'),
            matching: find.text('Delete in Hadco'),
          ),
          findsOneWidget,
        );
        expect(
          find.text('One sync would delete these contacts at once, so they '
              'are held for your OK, and everything else carries on.'),
          findsOneWidget,
          reason: 'no count beside the title, which counts those waiting',
        );
        expect(
          find.textContaining('Delete them deletes their copies in Hadco'),
          findsOneWidget,
        );

        await tester.tap(button('contact-sync-item:a2:dontDelete'));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.deletions, ContactSyncChoice.dontDelete),
        ]);
        expect(sync.questionItems, [
          {'a2'},
        ]);
      });

      testWidgets('a contact with changes on both sides names the side on '
          'each line, and a clash says its newer edit stays',
          (tester) async {
        sync = FakeContactSync(status: synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              ContactSyncQuestionItem(
                title: 'Ann Cole',
                side: ContactSide.graph,
                key: 'a',
                changes: [
                  ContactSyncDetailChange(
                    field: ContactField.company,
                    before: 'Acme',
                    after: 'Acme Corp',
                  ),
                  ContactSyncDetailChange(
                    field: ContactField.mobile,
                    before: '+1 555 0101',
                    side: ContactSide.google,
                    clash: true,
                  ),
                ],
              ),
              ContactSyncQuestionItem(
                title: 'Ben Day',
                side: ContactSide.graph,
                key: 'b',
                changes: [
                  ContactSyncDetailChange(
                    field: ContactField.jobTitle,
                    before: 'Buyer',
                    after: 'Senior buyer',
                    clash: true,
                  ),
                ],
              ),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        Finder under(String key, String text) => find.descendant(
              of: button('contact-sync-item:$key'),
              matching: find.text(text),
            );
        expect(under('a', 'Ann Cole'), findsOneWidget,
            reason: 'its lines name their sides');
        expect(under('a', 'In Hadco, Company: Acme \u2192 Acme Corp'),
            findsOneWidget);
        expect(
          under(
            'a',
            'In Gmail, Mobile: +1 555 0101 \u2192 removed (changed on both '
                'sides: the newer edit stays whichever you choose; the other '
                'value goes under Needs a look)',
          ),
          findsOneWidget,
        );
        expect(under('b', 'Ben Day: in Hadco'), findsOneWidget);
        expect(
          under(
            'b',
            'Job title: Buyer \u2192 Senior buyer (changed on both sides: '
                'the newer edit stays whichever you choose; the other value '
                'goes under Needs a look)',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('Under each name, each detail as it is now on '
              'the side named, and what it would become.'),
          findsOneWidget,
          reason: 'changes land on both sides',
        );
      });

      testWidgets('contacts of both sides each name theirs, and one alone has '
          'only the buttons for all', (tester) async {
        sync = FakeContactSync(status: synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              ContactSyncQuestionItem(
                title: 'Ann Cole',
                side: ContactSide.graph,
                key: 'a',
              ),
              ContactSyncQuestionItem(
                title: 'Ben Day',
                side: ContactSide.google,
                key: 'b',
              ),
            ],
          ),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);

        expect(find.text('Ann Cole: in Hadco'), findsOneWidget);
        expect(find.text('Ben Day: in Gmail'), findsOneWidget);
        expect(
          find.textContaining('Under each name, each detail as it is now on '
              'the side named, and what it would become.'),
          findsOneWidget,
        );
        expect(
          find.text('Apply makes each change on the side named. Copy back '
              'keeps what that side has and puts it back on the other, except '
              'a detail changed on both sides; a list only gains, so a '
              'replaced address leaves both. Either way each contact is read '
              'again first.'),
          findsOneWidget,
        );

        sync.set(synced(questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.changes,
            items: [
              ContactSyncQuestionItem(
                title: 'Ann Cole',
                side: ContactSide.graph,
                key: 'a',
              ),
            ],
          ),
        ]));
        await tester.pumpAndSettle();
        // While the screen stays open, Ben keeps his place, no longer held,
        // and nothing moves: Ann keeps her own buttons.
        expect(
          find.descendant(
            of: button('contact-sync-item:b'),
            matching: find.text('No longer held: nothing to answer.'),
          ),
          findsOneWidget,
        );
        expect(button('contact-sync-item:a:applyThem'), findsOneWidget);

        // Opened again: a question of one has only the buttons for all.
        await tester.pumpWidget(const SizedBox());
        await pumpScreen(tester);
        expect(button('contact-sync-item:b'), findsNothing);
        expect(button('contact-sync-item:a:applyThem'), findsNothing,
            reason: 'the same as the buttons for all');
        expect(button('contact-sync-question-for'), findsNothing);
        expect(find.text('Apply them'), findsOneWidget);
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
        expect(
          find.text("That's right, carry on takes 3 as the number to expect: "
              'the contacts no longer listed in Hadco are then taken as '
              'deleted there, and their copies in Gmail are deleted too (it '
              'asks first if that is more than 5). Keep waiting leaves it '
              'stopped, and the next sync looks again.'),
          findsOneWidget,
        );
        expect(find.text('Sync now'), findsOneWidget,
            reason: 'after Keep waiting, the way to look again');
        expect(find.text('Keep waiting'), findsOneWidget);
        await tester.tap(find.text("That's right, carry on"));
        await tester.pumpAndSettle();
        expect(sync.questionAnswers, [
          (ContactSyncQuestionKind.emptyAnswer, ContactSyncChoice.carryOn),
        ]);

        // The stop with no open question: not a dead end either.
        sync.set(synced(
          halt: ContactSyncHalt(
            kind: ContactSyncHaltKind.emptyAnswer,
            at: at1042,
            side: ContactSide.graph,
          ),
        ));
        await tester.pumpAndSettle();
        expect(
          find.text('Contact sync has stopped: Hadco listed far fewer '
              'contacts than expected.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Sync now'));
        await tester.pumpAndSettle();
        expect(sync.count('syncNow'), 1);
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
          find.text('One sync would delete this contact at once, so it is '
              'held for your OK, and everything else carries on.'),
          findsOneWidget,
          reason: 'no "more than 5" over a question holding one',
        );
        expect(
          find.text('You chose Delete them. The next sync carries it out.'),
          findsOneWidget,
        );
        expect(find.text("Don't delete them"), findsNothing);
      });

      testWidgets('contacts answered one by one stay where they are until '
          'the screen is left, and so does a question carried out',
          (tester) async {
        ContactSyncQuestionItem person(
          String key,
          String title, {
          ContactSyncChoice? answer,
        }) =>
            ContactSyncQuestionItem(
              title: title,
              side: ContactSide.graph,
              key: key,
              answer: answer,
              changes: const [
                ContactSyncDetailChange(
                  field: ContactField.jobTitle,
                  before: 'Buyer',
                ),
              ],
            );
        // Six deletions answered for all, waiting for the run, above the
        // changes Ron goes down one by one.
        final deletions = ContactSyncQuestion(
          kind: ContactSyncQuestionKind.deletions,
          answer: ContactSyncChoice.deleteThem,
          items: [
            for (final name in ['Eve', 'Fay', 'Gil', 'Hal', 'Ida', 'Jon'])
              ContactSyncQuestionItem(
                title: '$name Ash',
                side: ContactSide.google,
                key: 'd-$name',
              ),
          ],
        );
        ContactSyncStatus held(
          List<ContactSyncQuestionItem> changes, {
          bool withDeletions = true,
        }) =>
            synced(questions: [
              if (withDeletions) deletions,
              ContactSyncQuestion(
                kind: ContactSyncQuestionKind.changes,
                items: changes,
              ),
            ]);
        sync = FakeContactSync(status: held([
          person('a', 'Ann Cole'),
          person('b', 'Ben Day'),
          person('c', 'Cy Fox'),
          person('d', 'Di Ray'),
        ]));
        engine = _Engine(sync, const [gmail, hadco]);
        await pumpScreen(tester);
        double top(Finder f) => tester.getTopLeft(f).dy;
        Finder item(String key) => button('contact-sync-item:$key');
        Finder under(String key, String text) =>
            find.descendant(of: item(key), matching: find.text(text));

        // Ann answered on her own, then carried out by the run her answer
        // started: she stays, done, and nothing under her moves.
        await tester.tap(button('contact-sync-item:a:applyThem'));
        await tester.pumpAndSettle();
        expect(sync.questionItems.last, {'a'});
        sync.set(held([
          person('a', 'Ann Cole', answer: ContactSyncChoice.applyThem),
          person('b', 'Ben Day'),
          person('c', 'Cy Fox'),
          person('d', 'Di Ray'),
        ]));
        await tester.pumpAndSettle();
        final c = top(item('c'));
        sync.set(held([
          person('b', 'Ben Day'),
          person('c', 'Cy Fox'),
          person('d', 'Di Ray'),
        ]));
        await tester.pumpAndSettle();
        expect(under('a', 'You chose Apply: done. It is no longer held.'),
            findsOneWidget);
        expect(
          find.descendant(
            of: item('a'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
          findsNothing,
        );
        expect(top(item('c')), c, reason: 'nothing moved');
        expect(find.text('For the 3 not yet answered:'), findsOneWidget);

        // The deletions carried out, their question gone: it stays, done,
        // and the changes under it do not move.
        sync.set(held(
          [
            person('b', 'Ben Day'),
            person('c', 'Cy Fox'),
            person('d', 'Di Ray'),
          ],
          withDeletions: false,
        ));
        await tester.pumpAndSettle();
        expect(
          find.text('You chose Delete them: done. They are no longer held.'),
          findsOneWidget,
        );
        expect(find.text('Eve Ash: deleted in Gmail'), findsOneWidget);
        expect(
          find.descendant(
            of: button('contact-sync-question:deletions'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
          findsNothing,
        );
        expect(top(item('c')), c, reason: 'nothing moved');

        // Ben no longer held, with no answer: he stays, saying so.
        sync.set(held(
          [person('c', 'Cy Fox'), person('d', 'Di Ray')],
          withDeletions: false,
        ));
        await tester.pumpAndSettle();
        expect(
          under('b', 'No longer held: nothing to answer.'),
          findsOneWidget,
        );
        expect(button('contact-sync-item:b:applyThem'), findsNothing);

        // Held since: under the rest.
        sync.set(held(
          [
            person('c', 'Cy Fox'),
            person('d', 'Di Ray'),
            person('f', 'Fay Gil'),
          ],
          withDeletions: false,
        ));
        await tester.pumpAndSettle();
        expect(top(item('f')), greaterThan(top(item('d'))));

        // The buttons for the rest answer only the contacts listed now.
        await tester.tap(find.text('Apply them'));
        await tester.pumpAndSettle();
        expect(sync.questionItems.last, {'c', 'd', 'f'});
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
      expect(sync.allDiffering.single.choice, ContactSyncChoice.leaveAsTheyAre);
      expect(sync.allDiffering.single.looks.keys, {2, 3});
    });

    testWidgets('Needs a look: items answered stay where they are until the '
        'screen is left', (tester) async {
      ContactSyncLook differs(int id, {ContactSyncChoice? answer}) =>
          ContactSyncLook(
            id: id,
            kind: ContactReviewKind.differing,
            title: 'Person $id',
            fields: const [ContactField.jobTitle],
            googleValues: {ContactField.jobTitle: 'Buyer $id'},
            graphValues: {ContactField.jobTitle: 'Head buyer $id'},
            choices: const [
              ContactSyncChoice.useGoogle,
              ContactSyncChoice.useGraph,
              ContactSyncChoice.leaveAsTheyAre,
            ],
            answer: answer,
          );
      ContactSyncStatus listing(List<ContactSyncLook> looks) =>
          synced(looks: looks);
      sync = FakeContactSync(status: listing([
        for (var id = 1; id <= 6; id++) differs(id),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (6)'));
      await tester.pumpAndSettle();
      double top(Finder f) => tester.getTopLeft(f).dy;
      Finder look(int id) => button('contact-sync-look:$id');
      Finder under(int id, String text) =>
          find.descendant(of: look(id), matching: find.text(text));

      // Use Hadco's on the first, carried out by the run it started.
      await tester.tap(button('contact-sync-look:1:useGraph'));
      await tester.pumpAndSettle();
      sync.set(listing([
        differs(1, answer: ContactSyncChoice.useGraph),
        for (var id = 2; id <= 6; id++) differs(id),
      ]));
      await tester.pumpAndSettle();
      final fifthAnswered = top(look(5));
      sync.set(listing([for (var id = 2; id <= 6; id++) differs(id)]));
      await tester.pumpAndSettle();
      expect(
        under(1, "You chose Use Hadco's: done. No longer needs a look."),
        findsOneWidget,
      );
      expect(top(look(5)), fifthAnswered, reason: 'nothing moved');

      // Leave as they are, which takes the item away at once: it stays,
      // done, with the answer given here.
      await tester.tap(button('contact-sync-look:2:leaveAsTheyAre'));
      await tester.pumpAndSettle();
      sync.set(listing([for (var id = 3; id <= 6; id++) differs(id)]));
      await tester.pumpAndSettle();
      expect(
        under(2, 'You chose Leave as they are: done. No longer needs a look.'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: look(2),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        findsNothing,
      );

      // Gone with no answer (its contacts gone): it stays, saying so.
      sync.set(listing([differs(4), differs(5), differs(6)]));
      await tester.pumpAndSettle();
      expect(under(3, 'No longer needs a look.'), findsOneWidget);

      // Listed since: under the rest, and nothing above it moves.
      final fifth = top(look(5));
      sync.set(listing([differs(4), differs(5), differs(6), differs(7)]));
      await tester.pumpAndSettle();
      expect(top(look(7)), greaterThan(top(look(6))));
      expect(top(look(5)), fifth);
      expect(find.text('Nothing needs a look.'), findsNothing);

      // The answer for all names only the items listed now.
      await tester.tap(find.text('Leave all as they are'));
      await tester.pumpAndSettle();
      expect(sync.allDiffering.single.looks.keys, {4, 5, 6, 7});
    });

    testWidgets('a value never in step, written over by a change on one '
        'side, says so', (tester) async {
      sync = FakeContactSync(status: synced(looks: const [
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.clash,
          reason: ContactReviewReason.notInStep,
          title: 'Ann Cole',
          fields: [ContactField.notes],
          losing: 'Prefers email after 5',
          losingSide: ContactSide.graph,
          choices: [ContactSyncChoice.useOther, ContactSyncChoice.keepNewer],
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();

      expect(
        find.text('Changed in Gmail and copied to Hadco, where it was '
            'different. Hadco had: Prefers email after 5.'),
        findsOneWidget,
      );
      expect(find.textContaining('both sides'), findsNothing);
      await tester.tap(find.text("Use Hadco's instead"));
      await tester.pumpAndSettle();
      expect(sync.lookAnswers, [
        (id: 1, choice: ContactSyncChoice.useOther, candidateId: null),
      ]);
    });

    testWidgets("one side's details for every differing pair is asked again, "
        'naming the count and the side replaced', (tester) async {
      ContactSyncLook differs(int id) => ContactSyncLook(
            id: id,
            kind: ContactReviewKind.differing,
            title: 'Person $id',
            fields: const [ContactField.jobTitle],
            choices: const [
              ContactSyncChoice.useGoogle,
              ContactSyncChoice.useGraph,
              ContactSyncChoice.leaveAsTheyAre,
            ],
          );
      sync = FakeContactSync(status: synced(looks: [
        for (var id = 1; id <= 12; id++) differs(id),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (12)'));
      await tester.pumpAndSettle();

      expect(find.text('All 12 pairs whose details differ'), findsOneWidget);
      await tester.tap(find.text("Use Hadco's for all"));
      await tester.pumpAndSettle();
      expect(find.text("Use Hadco's details for all 12?"), findsOneWidget);
      expect(
        find.text("On the 12 contacts whose details differ, Gmail's are "
            "replaced with Hadco's at the next sync, which starts at once. "
            'This is the only time you are asked.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sync.allDiffering, isEmpty);

      await tester.tap(find.text("Use Gmail's for all"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Replace Hadco's"));
      await tester.pumpAndSettle();
      expect(
        [for (final a in sync.allDiffering) a.choice],
        [ContactSyncChoice.useGoogle],
      );

      // Leaving them as they are replaces nothing, and is not asked again.
      await tester.tap(find.text('Leave all as they are'));
      await tester.pumpAndSettle();
      expect(button('contact-sync-all-sure'), findsNothing);
      expect([for (final a in sync.allDiffering) a.choice], [
        ContactSyncChoice.useGoogle,
        ContactSyncChoice.leaveAsTheyAre,
      ]);
    });

    testWidgets('an answer for all names the pairs it counted: one listed '
        'while its question is open is not among them', (tester) async {
      ContactSyncLook differs(int id) => ContactSyncLook(
            id: id,
            kind: ContactReviewKind.differing,
            title: 'Person $id',
            fields: const [ContactField.jobTitle],
            googleValues: {ContactField.jobTitle: 'Buyer $id'},
            choices: const [
              ContactSyncChoice.useGoogle,
              ContactSyncChoice.useGraph,
              ContactSyncChoice.leaveAsTheyAre,
            ],
          );
      sync = FakeContactSync(status: synced(looks: [
        for (var id = 1; id <= 3; id++) differs(id),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (3)'));
      await tester.pumpAndSettle();

      await tester.tap(find.text("Use Hadco's for all"));
      await tester.pumpAndSettle();
      // A run lists another pair while the question is open.
      sync.set(synced(looks: [
        for (var id = 1; id <= 4; id++) differs(id),
      ]));
      await tester.pumpAndSettle();
      expect(find.text("Use Hadco's details for all 3?"), findsOneWidget);
      await tester.tap(find.text("Replace Gmail's"));
      await tester.pumpAndSettle();
      expect(sync.allDiffering.single.choice, ContactSyncChoice.useGraph);
      expect(sync.allDiffering.single.looks, {
        for (var id = 1; id <= 3; id++) id: differs(id).version,
      });

      // Refused, the pairs having changed since: said, and read again.
      sync.allDifferingFailure = const ContactSyncRefused(
        'Those contacts have changed since they were shown. Look at them '
        'again.',
      );
      final reads = sync.statusReads;
      await tester.tap(find.text('Leave all as they are'));
      await tester.pumpAndSettle();
      expect(
        find.text('Those contacts have changed since they were shown. Look '
            'at them again.'),
        findsOneWidget,
      );
      expect(sync.statusReads, greaterThan(reads),
          reason: 'read again, to be answered as it is now');
    });

    test("an item's version is what it shows", () {
      const look = ContactSyncLook(
        id: 1,
        kind: ContactReviewKind.differing,
        title: 'Ann Cole',
        fields: [ContactField.jobTitle],
        googleValues: {ContactField.jobTitle: 'Buyer'},
        graphValues: {ContactField.jobTitle: 'Head buyer'},
      );
      expect(look.version, hasLength(16));
      expect(look.version, isNot(contains('Buyer')));
      expect(
        const ContactSyncLook(
          id: 2,
          kind: ContactReviewKind.differing,
          title: 'Ann Cole',
          fields: [ContactField.jobTitle],
          googleValues: {ContactField.jobTitle: 'Buyer'},
          graphValues: {ContactField.jobTitle: 'Head buyer'},
          answer: ContactSyncChoice.useGraph,
        ).version,
        look.version,
        reason: 'not its id or its answer',
      );
      for (final other in const [
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.differing,
          title: 'Ann Cole',
          fields: [ContactField.jobTitle, ContactField.company],
          googleValues: {ContactField.jobTitle: 'Buyer'},
          graphValues: {ContactField.jobTitle: 'Head buyer'},
        ),
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.differing,
          title: 'Ann Cole',
          fields: [ContactField.jobTitle],
          googleValues: {ContactField.jobTitle: 'Buyer'},
          graphValues: {ContactField.jobTitle: 'Chief buyer'},
        ),
      ]) {
        expect(other.version, isNot(look.version));
      }
    });

    testWidgets('a new contact whose names disagree says so, however it was '
        'matched', (tester) async {
      // By an email or mobile, or by MyEmail's own link on a copy typed
      // over as someone else: one line true of both.
      sync = FakeContactSync(status: synced(looks: const [
        ContactSyncLook(
          id: 1,
          kind: ContactReviewKind.newContact,
          reason: ContactReviewReason.namesDisagree,
          side: ContactSide.graph,
          title: 'Dana Levi',
          candidates: [ContactSyncCandidate(id: 'g-1', title: 'Noa Gal')],
          choices: [
            ContactSyncChoice.samePerson,
            ContactSyncChoice.copyAnyway,
            ContactSyncChoice.leaveOut,
          ],
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();

      expect(
        find.text("New in Hadco. MyEmail's own link, or its email or mobile, "
            'points to Noa Gal in Gmail, but the names differ.'),
        findsOneWidget,
      );
    });

    testWidgets('copies of one person: a row of their own, not among Needs '
        'a look, opening one line for each', (tester) async {
      sync = FakeContactSync(status: synced(
        looks: const [
          ContactSyncLook(id: 1, kind: ContactReviewKind.clash),
          ContactSyncLook(id: 2, kind: ContactReviewKind.clash),
        ],
        // Not in order: the list is by name.
        duplicates: const [
          ContactSyncDuplicates(
            title: 'Eli Ho',
            googleCopies: 2,
            graphCopies: 2,
            googleSynced: true,
          ),
          ContactSyncDuplicates(
            title: 'Ann Cole',
            googleCopies: 2,
            graphCopies: 3,
            googleSynced: true,
            graphSynced: true,
          ),
          ContactSyncDuplicates(
            title: 'Dee Gal',
            graphCopies: 2,
            graphSynced: true,
          ),
          ContactSyncDuplicates(
            title: 'Bob Day',
            googleCopies: 3,
            googleSynced: true,
          ),
          ContactSyncDuplicates(
            title: 'cy Fox',
            googleCopies: 2,
            graphCopies: 1,
            googleSynced: true,
            graphSynced: true,
          ),
        ],
      ));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);

      expect(find.text('Needs a look (2)'), findsOneWidget,
          reason: 'copies are not questions');
      expect(find.text('Duplicates to merge when you like (5 people)'),
          findsOneWidget);
      expect(
        tester.getTopLeft(button('contact-sync-duplicates')).dy,
        greaterThan(tester.getTopLeft(button('contact-sync-looks')).dy),
      );

      await tester.tap(
        find.text('Duplicates to merge when you like (5 people)'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('These are copies of the same person. One copy on each side '
            "is synced; the others are left as they are. Merge Gmail's "
            'copies with Merge & fix in Google Contacts. Where a side holds '
            'more than one copy, whichever one you remove there, the sync '
            'moves to one that is left, and nothing is deleted on the other '
            "side. Removing a person's last copy on one side deletes it on "
            'the other too, as any deletion does. In Outlook on the web, '
            'deleting a contact can delete its hidden copies too, and the '
            'sync then deletes the person in Gmail.'),
        findsOneWidget,
      );
      expect(button('contact-sync-copies'), findsNothing,
          reason: "nothing for the merge of Hadco's copies to do");
      expect(find.text('People with copies (5)'), findsOneWidget);
      final lines = [
        'Ann Cole: 2 in Gmail, 3 in Hadco; one of each is synced',
        'Bob Day: 3 in Gmail; one is synced, and its copy in Hadco is still '
            'to be made',
        'cy Fox: 2 in Gmail, 1 in Hadco; one of each is synced',
        'Dee Gal: 2 in Hadco; one is synced, and its copy in Gmail is still '
            'to be made',
        'Eli Ho: 2 in Gmail, 2 in Hadco; one in Gmail is synced',
      ];
      for (final line in lines) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      for (var i = 1; i < lines.length; i++) {
        expect(
          tester.getTopLeft(find.text(lines[i])).dy,
          greaterThan(tester.getTopLeft(find.text(lines[i - 1])).dy),
          reason: 'by name: ${lines[i]}',
        );
      }
    });

    test('a side with no copies has none synced, whatever its flag says',
        () {
      // Hadco said synced, but holding none: its copy is still to be made.
      expect(
        contactSyncCopiesLine(
          const ContactSyncDuplicates(
            title: 'Ann Cole',
            googleCopies: 2,
            googleSynced: true,
            graphSynced: true,
          ),
          'Hadco',
        ),
        '2 in Gmail; one is synced, and its copy in Hadco is still to be '
        'made',
      );
      // Gmail said synced, but holding none, and Hadco not: none is.
      expect(
        contactSyncCopiesLine(
          const ContactSyncDuplicates(
            title: 'Bob Day',
            graphCopies: 2,
            googleSynced: true,
          ),
          'Hadco',
        ),
        '2 in Hadco; none is synced yet',
      );
    });

    testWidgets('an answer refused because the question changed is said, '
        'and the question read again', (tester) async {
      sync = FakeContactSync(status: synced(questions: const [
        ContactSyncQuestion(
          kind: ContactSyncQuestionKind.changes,
          items: [
            ContactSyncQuestionItem(
              title: 'Ann Cole',
              side: ContactSide.graph,
              key: 'a',
            ),
            ContactSyncQuestionItem(
              title: 'Ben Day',
              side: ContactSide.graph,
              key: 'b',
            ),
          ],
        ),
      ]))
        ..answerFailure = const ContactSyncRefused(
          'These contacts have changed since they were shown. Look again.',
        );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      final readsBefore = sync.statusReads;

      await tester.tap(find.text('Apply them'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'These contacts have changed since they were shown. Look again.',
        ),
        findsOneWidget,
      );
      expect(sync.statusReads, greaterThan(readsBefore),
          reason: 'read again, to be answered as it is now');
    });

    testWidgets('a few hundred copies of people scroll to the last',
        (tester) async {
      sync = FakeContactSync(status: synced(duplicates: [
        for (var i = 0; i < 300; i++)
          ContactSyncDuplicates(
            title: 'Person ${i.toString().padLeft(3, '0')}',
            googleCopies: 2,
            graphCopies: 2,
            googleSynced: true,
            graphSynced: true,
          ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester, size: const Size(412, 915));
      await tester.scrollUntilVisible(
        button('contact-sync-duplicates'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button('contact-sync-duplicates'));
      await tester.pumpAndSettle();

      final last = find.text(
        'Person 299: 2 in Gmail, 2 in Hadco; one of each is synced',
      );
      expect(
        find.text(
          'Person 299: 2 in Gmail, 2 in Hadco; one of each is synced',
          skipOffstage: false,
        ),
        findsNothing,
        reason: 'built as it scrolls, not all three hundred at once',
      );
      await tester.scrollUntilVisible(
        last,
        600,
        scrollable: find.descendant(
          of: button('contact-sync-duplicates-list'),
          matching: find.byType(Scrollable),
        ),
      );
      expect(last, findsOneWidget);
    });

    /// The Duplicates screen over [copies], a person with copies on each
    /// side to open it by.
    Future<void> openDuplicates(
      WidgetTester tester, {
      required ContactSyncCopies copies,
      ContactSyncProgress? running,
      Size size = const Size(800, 3000),
    }) async {
      sync = FakeContactSync(
        status: synced(
          running: running,
          copies: copies,
          duplicates: const [
            ContactSyncDuplicates(
              title: 'Ann Cole',
              googleCopies: 1,
              graphCopies: 3,
              googleSynced: true,
              graphSynced: true,
            ),
          ],
        ),
        backupFiles: _backupFiles,
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester, size: size);
      await tester.scrollUntilVisible(
        button('contact-sync-duplicates'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.text('Duplicates to merge when you like (1 person)'),
      );
      await tester.pumpAndSettle();
    }

    double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

    /// [s] with a merge asked for, as the runner says it once asked.
    ContactSyncStatus asked(ContactSyncStatus s) => synced(
          copies: ContactSyncCopies(
            people: s.copies.people,
            extras: s.copies.extras,
            notSynced: s.copies.notSynced,
            asked: true,
            last: s.copies.last,
            differing: s.copies.differing,
          ),
          duplicates: s.duplicates,
        );

    /// [lines] all within [of], each under the one before.
    void inOrder(WidgetTester tester, Finder of, List<String> lines) {
      Finder line(String text) =>
          find.descendant(of: of, matching: find.text(text));
      for (final text in lines) {
        expect(line(text), findsOneWidget, reason: text);
      }
      for (var i = 1; i < lines.length; i++) {
        expect(
          top(tester, line(lines[i])),
          greaterThan(top(tester, line(lines[i - 1]))),
          reason: lines[i],
        );
      }
    }

    testWidgets("Hadco's copies: what the merge does, and the counts",
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(
          people: 1336,
          extras: 1515,
          notSynced: 12,
        ),
      );

      expect(
        find.text('These are copies of the same person. One copy on each side '
            'is synced; the others are left as they are. Merge Gmail\'s '
            "copies with Merge & fix in Google Contacts, and Hadco's with "
            'the merge below. Where a side holds more than one copy, '
            'whichever one you remove there, the sync moves to one that is '
            'left, and nothing is deleted on the other side. Removing a '
            "person's last copy on one side deletes it on the other too, as "
            'any deletion does. In Outlook on the web, deleting a contact can '
            'delete its hidden copies too, and the sync then deletes the '
            'person in Gmail.'),
        findsOneWidget,
      );
      final panel = button('contact-sync-copies');
      inOrder(tester, panel, [
        "Merge Hadco's copies",
        // Where Graph's delete puts a contact is not yet known: true
        // either way.
        'Keeps the synced copy of each person, adds to it any detail only '
            'another copy has, and deletes the other copies. Outlook keeps '
            'deleted contacts for a while: in Deleted Items, or under Recover '
            'items deleted from this folder at the top of Deleted Items. When '
            'both copies have a photo, the synced copy keeps its own. Copies '
            'that differ are left for you to choose.',
        'Nothing is deleted in Gmail; it gets the added details at the next '
            'sync.',
        '1336 people have 1515 other copies in Hadco.',
        "12 people's copies in Hadco are left as they are: none is synced "
            'there, or a copy shares only the name.',
        "It starts once you have saved Hadco's backup file, which Outlook on "
            'the web can import.',
        'Save backup and merge',
      ]);
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);
      expect(find.textContaining('Copies that differ ('), findsNothing);
      expect(
        top(tester, find.text('People with copies (1)')),
        greaterThan(top(tester, panel)),
      );

      sync.set(synced(
        copies: const ContactSyncCopies(people: 1, extras: 1, notSynced: 1),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 2),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.text('1 person has 1 other copy in Hadco.'), findsOneWidget);
      expect(
        find.text("1 person's copies in Hadco are left as they are: none is "
            'synced there, or a copy shares only the name.'),
        findsOneWidget,
      );
    });

    testWidgets("Save backup and merge saves only Hadco's file, then asks for "
        'the merge', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );

      // The runner asks for the merge; the status here has not caught up.
      sync.onMergeCopies = () => sync.current = asked(sync.current);
      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(sync.count('backup'), 1);
      expect(sync.backupsOf, [ContactSide.graph], reason: 'Gmail not read');
      expect(
        [
          for (final f in files.saved) (f.fileName, f.mimeType, f.dialogTitle),
        ],
        [
          (
            'myemail-outlook-contacts-2026-11-21.csv',
            'text/csv',
            "Save Hadco's contacts",
          ),
        ],
      );
      expect(sync.count('mergeCopies'), 1);
      final startsNow = find.text('Saved myemail-outlook-contacts-2026-11-21.'
          'csv, 412 contacts, which Outlook on the web can import. The merge '
          'starts now.');
      expect(startsNow, findsOneWidget);
      // Off until the status shows the merge: no second read and dialog.
      expect(enabled(tester, 'contact-sync-copies-merge'), isFalse);

      // Shown asked: its progress takes over.
      sync.set(sync.current);
      await tester.pumpAndSettle();
      expect(startsNow, findsNothing);
      expect(
        find.text('Merge asked for: the next sync carries it out.'),
        findsOneWidget,
      );

      // Done: what it did, and nothing about it starting.
      sync.set(synced(
        copies: ContactSyncCopies(
          last: ContactSyncCopiesResult(
            at: DateTime.now(),
            people: 3,
            deleted: 4,
          ),
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', googleCopies: 2),
        ],
      ));
      await tester.pumpAndSettle();
      expect(button('contact-sync-copies-last'), findsOneWidget);
      expect(startsNow, findsNothing);
      expect(sync.count('backup'), 1);
    });

    testWidgets('a line said before goes once a newer result shows',
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      files.answers.add(false);
      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      final notSaved =
          find.text("Hadco's backup file was not saved, so nothing is merged.");
      expect(notSaved, findsOneWidget);

      sync.set(synced(
        copies: ContactSyncCopies(
          people: 3,
          extras: 4,
          last: ContactSyncCopiesResult(at: DateTime.now(), people: 1),
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(notSaved, findsNothing);
    });

    testWidgets('a backup not saved merges nothing, and says so',
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );

      files.answers.add(false);
      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(files.saved, hasLength(1), reason: 'the save dialog was shown');
      expect(sync.count('mergeCopies'), 0);
      expect(
        find.text("Hadco's backup file was not saved, so nothing is merged."),
        findsOneWidget,
      );
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);

      // Saved the second time: asked for then.
      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(sync.count('mergeCopies'), 1);
      expect(find.textContaining('was not saved'), findsNothing);
    });

    testWidgets('with nothing to merge by then, says so and asks nothing more',
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );

      // The runner asks for nothing: no copies to merge by then.
      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(sync.count('mergeCopies'), 1);
      expect(
        find.text('Saved myemail-outlook-contacts-2026-11-21.csv, 412 '
            'contacts, which Outlook on the web can import. There is nothing '
            'to merge just now.'),
        findsOneWidget,
      );
      expect(find.textContaining('The merge starts now'), findsNothing);
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);
    });

    testWidgets('leaving the screen while the backup is read asks nothing',
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.backupGate = Completer<void>();

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pump();
      Navigator.of(tester.element(find.text('Duplicates to merge'))).pop();
      await tester.pumpAndSettle();
      sync.backupGate!.complete();
      await tester.pumpAndSettle();
      expect(files.saved, isEmpty, reason: 'no save dialog');
      expect(sync.count('mergeCopies'), 0);
    });

    /// MyEmail out of sight, as with the screen off or a call, and back.
    void outOfSight(WidgetTester tester) {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    void backInFront(WidgetTester tester) {
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    testWidgets('a backup read while MyEmail is out of sight is kept, and '
        'saved once it is back', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.backupGate = Completer<void>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pump();
      outOfSight(tester);
      sync.backupGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(files.saved, isEmpty, reason: 'no dialog while out of sight');
      expect(sync.count('mergeCopies'), 0);

      backInFront(tester);
      await tester.pumpAndSettle();
      expect(sync.count('backup'), 1, reason: 'the file read is kept');
      expect(files.saved, hasLength(1));
      expect(sync.count('mergeCopies'), 1);
      expect(find.textContaining('put away'), findsNothing);
    });

    testWidgets('the screen closed while MyEmail is out of sight drops the '
        'backup read', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.backupGate = Completer<void>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pump();
      outOfSight(tester);
      sync.backupGate!.complete();
      await tester.pump();
      Navigator.of(tester.element(find.text('Duplicates to merge'))).pop();
      await tester.pump();
      backInFront(tester);
      await tester.pumpAndSettle();
      expect(files.saved, isEmpty);
      expect(sync.count('mergeCopies'), 0);
    });

    testWidgets('a status that cannot be read after the merge is asked for '
        'says it is asked for', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.onMergeCopies = () => sync.statusFailure =
          const ContactSyncFailed('This device could not read its record.');

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      sync.statusFailure = null;
      expect(sync.count('mergeCopies'), 1);
      expect(
        find.text('Saved myemail-outlook-contacts-2026-11-21.csv, 412 '
            'contacts, which Outlook on the web can import. The merge is '
            'asked for.'),
        findsOneWidget,
      );
      expect(find.text('Nothing is merged.'), findsNothing);
      expect(enabled(tester, 'contact-sync-copies-merge'), isFalse,
          reason: 'until the status shows it');

      // The next status: nothing asked, nothing newer. The runner asked
      // for nothing; the button is back.
      sync.set(synced(
        copies: const ContactSyncCopies(people: 3, extras: 4),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);
    });

    testWidgets('an ask read back as asked keeps the button off until the '
        'status here shows it', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.onMergeCopies = () => sync.current = asked(sync.current);
      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-copies-merge'), isFalse);

      // A status with nothing asked and nothing newer, from before the ask:
      // the button stays off.
      sync.set(synced(
        copies: const ContactSyncCopies(people: 3, extras: 4),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-copies-merge'), isFalse);
    });

    testWidgets('leaving the screen while the save dialog is open asks '
        'nothing', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      files.gate = Completer<bool>();

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pump();
      expect(files.saved, hasLength(1), reason: 'the dialog is open');
      Navigator.of(tester.element(find.text('Duplicates to merge'))).pop();
      await tester.pumpAndSettle();
      files.gate!.complete(true);
      await tester.pumpAndSettle();
      expect(sync.count('mergeCopies'), 0);
    });

    testWidgets('offered only once the first sync is done', (tester) async {
      sync = FakeContactSync(
        status: synced(
          firstDone: false,
          copies: const ContactSyncCopies(people: 3, extras: 4),
          duplicates: const [
            ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
          ],
        ),
        backupFiles: _backupFiles,
      );
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(
        find.text('Duplicates to merge when you like (1 person)'),
      );
      await tester.pumpAndSettle();

      expect(button('contact-sync-copies-merge'), findsNothing);
      inOrder(tester, button('contact-sync-copies'), [
        '3 people have 4 other copies in Hadco.',
        'Offered once the first sync is done.',
      ]);

      sync.set(synced(
        copies: const ContactSyncCopies(people: 3, extras: 4),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);
      expect(find.text('Offered once the first sync is done.'), findsNothing);
    });

    testWidgets('a merge that cannot be asked for after the file is saved '
        'says so, and Try again asks it alone', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.mergeFailure = const ContactSyncFailed(
        'Hadco could not be reached.',
      );

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      inOrder(tester, button('contact-sync-copies'), [
        'Save backup and merge',
        'Saved myemail-outlook-contacts-2026-11-21.csv, 412 contacts, which '
            'Outlook on the web can import.',
        'Hadco could not be reached.',
        'Nothing is merged.',
      ]);

      sync.mergeFailure = null;
      sync.onMergeCopies = () => sync.current = asked(sync.current);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(sync.count('backup'), 1, reason: 'the file is not read again');
      expect(files.saved, hasLength(1), reason: 'nor saved again');
      expect(sync.count('mergeCopies'), 2);
      expect(
        find.text('Saved myemail-outlook-contacts-2026-11-21.csv, 412 '
            'contacts, which Outlook on the web can import. The merge starts '
            'now.'),
        findsOneWidget,
      );
      expect(find.text('Nothing is merged.'), findsNothing);
    });

    testWidgets("a backup with no file for Hadco merges nothing",
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.backupFiles = [_backupFiles.first];

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(files.saved, isEmpty);
      expect(sync.count('mergeCopies'), 0);
      expect(
        find.text("Hadco's backup file was not made, so nothing is merged."),
        findsOneWidget,
      );
    });

    testWidgets('answered people stay where they are until the screen is '
        'left', (tester) async {
      ContactSyncCopiesPerson person(
        String key,
        String title, {
        String? answer,
        String? version,
      }) =>
          ContactSyncCopiesPerson(
            key: key,
            title: title,
            answer: answer,
            version: version ?? 'v-$key',
            copies: [
              ContactSyncCopy(
                key: '$key-s',
                synced: true,
                details: const [
                  ContactSyncCopyDetail(label: 'Job title', value: 'Buyer'),
                ],
              ),
              ContactSyncCopy(
                key: '$key-o',
                details: const [
                  ContactSyncCopyDetail(label: 'Job title', value: 'Head'),
                ],
              ),
            ],
          );
      ContactSyncStatus listing(List<ContactSyncCopiesPerson> differing) =>
          synced(
            copies: ContactSyncCopies(differing: differing),
            duplicates: const [
              ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
            ],
          );
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          differing: [
            person('a', 'Ann Cole', answer: 'a-o'),
            person('b', 'Ben Day'),
            person('c', 'Cy Fox'),
            person('d', 'Di Ray'),
          ],
        ),
      );
      Finder of(String key) => button('contact-sync-copies-person:$key');
      final b = top(tester, of('b'));
      final c = top(tester, of('c'));

      // Ann carried out; Eve found since, listed first by the runner.
      sync.set(listing([
        person('e', 'Eve Ash'),
        person('b', 'Ben Day'),
        person('c', 'Cy Fox'),
        person('d', 'Di Ray'),
      ]));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: of('a'),
          matching: find.text("You chose the other copy's details; see the "
              'result above.'),
        ),
        findsOneWidget,
        reason: 'done, or its write failed: nothing promised',
      );
      expect(
        find.descendant(
          of: of('a'),
          matching: find.textContaining('the next sync carries it out'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: of('a'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        findsNothing,
      );
      expect(top(tester, of('b')), b, reason: 'nothing moved');
      expect(top(tester, of('c')), c);
      expect(top(tester, of('e')), greaterThan(top(tester, of('d'))),
          reason: 'one found since goes under them');
      expect(find.text('Copies that differ (5)'), findsOneWidget,
          reason: 'as many as are shown');

      // Left as they are, by Ron, and no longer listed: done.
      sync.set(listing([
        person('b', 'Ben Day'),
        person('c', 'Cy Fox'),
        person('d', 'Di Ray', answer: ContactSyncCopiesPerson.leave),
        person('e', 'Eve Ash'),
      ]));
      await tester.pumpAndSettle();
      sync.set(listing([
        person('b', 'Ben Day'),
        person('c', 'Cy Fox'),
        person('e', 'Eve Ash'),
      ]));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: of('d'),
          matching: find.text('You chose to leave them as they are; done.'),
        ),
        findsOneWidget,
      );

      // Fay gone with no answer: not kept.
      sync.set(listing([
        person('b', 'Ben Day'),
        person('c', 'Cy Fox'),
        person('e', 'Eve Ash'),
        person('f', 'Fay Gil'),
      ]));
      await tester.pumpAndSettle();
      sync.set(listing([
        person('b', 'Ben Day'),
        person('c', 'Cy Fox'),
        person('e', 'Eve Ash'),
      ]));
      await tester.pumpAndSettle();
      expect(of('f'), findsNothing, reason: 'not answered: not kept');
      expect(top(tester, of('b')), b);

      // Ben answered here: shown so at once, before the status says so,
      // and kept once carried out.
      await tester.tap(button('contact-sync-copies-keep:b:b-s'));
      await tester.pumpAndSettle();
      expect(
        sync.copiesAnswers.last,
        (person: 'b', keep: 'b-s', version: 'v-b'),
      );
      final benAnswered = find.descendant(
        of: of('b'),
        matching: find.text("You chose the synced copy's details; the next "
            'sync carries it out.'),
      );
      expect(benAnswered, findsOneWidget);
      final cNow = top(tester, of('c'));
      sync.set(listing([person('c', 'Cy Fox'), person('e', 'Eve Ash')]));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: of('b'),
          matching: find.text("You chose the synced copy's details; see the "
              'result above.'),
        ),
        findsOneWidget,
      );
      expect(top(tester, of('c')), cNow, reason: 'nothing moved');

      // Listed again with other differences: the answer is not his.
      sync.set(listing([
        person('b', 'Ben Day', version: 'v-b2'),
        person('c', 'Cy Fox'),
        person('e', 'Eve Ash'),
      ]));
      await tester.pumpAndSettle();
      expect(benAnswered, findsNothing);
      expect(button('contact-sync-copies-keep:b:b-s'), findsOneWidget);

      // Left and opened again: as listed now.
      Navigator.of(tester.element(find.text('Duplicates to merge'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Duplicates to merge when you like (1 person)'),
      );
      await tester.pumpAndSettle();
      expect(of('a'), findsNothing);
      expect(of('b'), findsOneWidget);
    });

    testWidgets('a backup that cannot be made merges nothing, and says so',
        (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(people: 3, extras: 4),
      );
      sync.backupFailure = const ContactSyncFailed(
        'Hadco could not be reached.',
      );

      await tester.tap(button('contact-sync-copies-merge'));
      await tester.pumpAndSettle();
      expect(files.saved, isEmpty);
      expect(sync.count('mergeCopies'), 0);
      inOrder(tester, button('contact-sync-copies'), [
        'Save backup and merge',
        'Hadco could not be reached.',
        'Nothing is merged.',
      ]);
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);

      sync.backupFailure = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(sync.count('backup'), 2, reason: 'read again');
      expect(files.saved, hasLength(1));
      expect(sync.count('mergeCopies'), 1);
      expect(find.text('Nothing is merged.'), findsNothing);
    });

    testWidgets('while the merge is asked for, how far it has got',
        (tester) async {
      final asked = ContactSyncCopies(
        people: 1336,
        extras: 1515,
        asked: true,
        last: ContactSyncCopiesResult(at: at1042, people: 4),
      );
      await openDuplicates(
        tester,
        copies: asked,
        running: const ContactSyncProgress(
          step: ContactSyncStep.merging,
          done: 120,
          total: 1336,
        ),
      );

      expect(find.text('Merging: 120 of 1336 people'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              button('contact-sync-copies-progress'),
            )
            .value,
        closeTo(120 / 1336, 1e-9),
      );
      expect(
        find.text('Keep MyEmail open until it is done. If it is closed '
            'sooner, the merge carries on the next time MyEmail is opened.'),
        findsOneWidget,
      );
      expect(button('contact-sync-copies-merge'), findsNothing);
      expect(button('contact-sync-copies-last'), findsNothing,
          reason: 'the last merge waits until this one is done');
      expect(find.text('1336 people have 1515 other copies in Hadco.'),
          findsOneWidget);

      // Asked for, while the sync is still at its own changes.
      sync.set(synced(
        copies: asked,
        running: const ContactSyncProgress(
          step: ContactSyncStep.writing,
          done: 1,
          total: 4,
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      // Not settled: a bar with no end to it moves for ever.
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Merge asked for: it starts once the sync has made its '
            'changes.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              button('contact-sync-copies-progress'),
            )
            .value,
        isNull,
      );

      // Asked for, and no sync going.
      sync.set(synced(
        copies: asked,
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Merge asked for: the next sync carries it out.'),
        findsOneWidget,
      );
      expect(button('contact-sync-copies-progress'), findsNothing);
      expect(find.textContaining('Keep MyEmail open'), findsNothing,
          reason: 'only while a sync runs');
    });

    const annDiffers = ContactSyncCopiesPerson(
      key: 'p1',
      title: 'Ann Cole',
      version: 'va',
      copies: [
        ContactSyncCopy(
          key: 'a1',
          synced: true,
          details: [
            ContactSyncCopyDetail(label: 'Job title', value: 'Buyer'),
            ContactSyncCopyDetail(label: 'Work address'),
          ],
        ),
        ContactSyncCopy(
          key: 'a2',
          details: [
            ContactSyncCopyDetail(label: 'Job title', value: 'Head buyer'),
            ContactSyncCopyDetail(
              label: 'Work address',
              value: '12 Main St, Atlanta GA 30301',
            ),
          ],
        ),
      ],
    );
    const benDiffers = ContactSyncCopiesPerson(
      key: 'p2',
      title: 'Ben Day',
      version: 'vb',
      copies: [
        ContactSyncCopy(
          key: 'b1',
          synced: true,
          details: [
            ContactSyncCopyDetail(label: 'Notes', value: 'Met at the fair'),
          ],
        ),
        ContactSyncCopy(
          key: 'b2',
          details: [ContactSyncCopyDetail(label: 'Notes', value: '(long note)')],
        ),
        ContactSyncCopy(
          key: 'b3',
          details: [ContactSyncCopyDetail(label: 'Notes', value: ' ')],
        ),
      ],
    );

    testWidgets('the last merge, in a sentence', (tester) async {
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          people: 2,
          extras: 2,
          last: ContactSyncCopiesResult(
            at: at1042,
            people: 1089,
            deleted: 1143,
            added: 210,
            differing: 2,
            failed: 2,
          ),
          differing: const [annDiffers, benDiffers],
        ),
      );
      final clock = formatClock(at1042, use24h: false);
      inOrder(tester, button('contact-sync-copies'), [
        "Merge Hadco's copies",
        'Merged at $clock: 1089 people, 1143 copies deleted, 210 details '
            'added. 2 people whose copies differ are left for you. 2 people '
            'could not be merged in full: what is left of their copies is as '
            'it was, and the next merge tries again.',
        '2 people have 2 other copies in Hadco.',
        'Save backup and merge',
      ]);
      expect(find.text('Copies that differ (2)'), findsOneWidget);

      // All merged: the panel stays for what the merge did, with nothing
      // left to merge.
      sync.set(synced(
        copies: ContactSyncCopies(
          last: ContactSyncCopiesResult(
            at: at1042,
            people: 1,
            deleted: 1,
          ),
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', googleCopies: 2),
        ],
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Merged at $clock: 1 person, 1 copy deleted, no details '
            'added.'),
        findsOneWidget,
      );
      expect(button('contact-sync-copies-merge'), findsNothing);
      expect(button('contact-sync-copies-counts'), findsNothing);
    });

    test('the last merge: one of each, and nobody merged', () {
      final clock = formatClock(at1042, use24h: false);
      expect(
        contactSyncMergedLine(
          ContactSyncCopiesResult(
            at: at1042,
            people: 1,
            deleted: 2,
            differing: 1,
            failed: 1,
          ),
          today,
          graphName: 'Hadco',
          use24h: false,
        ),
        'Merged at $clock: 1 person, 2 copies deleted, no details added. 1 '
        'person whose copies differ is left for you. 1 person could not be '
        'merged in full: what is left of their copies is as it was, and the '
        'next merge tries again.',
      );
      expect(
        contactSyncMergedLine(
          ContactSyncCopiesResult(at: at1042, differing: 3),
          today,
          graphName: 'Hadco',
          use24h: false,
        ),
        'The merge at $clock merged nobody. 3 people whose copies differ are '
        'left for you.',
      );
    });

    test('the last merge: people left for the next one, and a merge given '
        'up', () {
      final clock = formatClock(at1042, use24h: false);
      String say(ContactSyncCopiesResult r, {bool tryAgain = false}) =>
          contactSyncMergedLine(
            r,
            today,
            graphName: 'Hadco',
            use24h: false,
            tryAgain: tryAgain,
          );
      expect(
        say(ContactSyncCopiesResult(
          at: at1042,
          people: 40,
          deleted: 52,
          added: 9,
          passedOver: 12,
        )),
        'Merged at $clock: 40 people, 52 copies deleted, 9 details added. 12 '
        'people were left for the next merge: a copy changed meanwhile, '
        'Hadco could not be read just then, a photo could not be read, or a '
        'copy is no longer in Contacts.',
      );
      expect(
        say(ContactSyncCopiesResult(at: at1042, passedOver: 1)),
        'The merge at $clock merged nobody. 1 person was left for the next '
        'merge: a copy changed meanwhile, Hadco could not be read just then, '
        'a photo could not be read, or a copy is no longer in Contacts.',
      );
      // Given up, with what it did before, and the way to try again.
      expect(
        say(
          ContactSyncCopiesResult(
            at: at1042,
            people: 120,
            deleted: 130,
            added: 40,
            failed: 1,
            stoppedShort: true,
          ),
          tryAgain: true,
        ),
        'The merge was given up at $clock: Hadco could not be read three '
        'times in a row. Before that: 120 people merged, 130 copies deleted, '
        '40 details added. 1 person could not be merged in full: what is left '
        'of their copies is as it was, and the next merge tries again. Save '
        'backup and merge to try again.',
      );
      // Given up before doing anything, where trying again is not offered.
      expect(
        say(ContactSyncCopiesResult(at: at1042, stoppedShort: true)),
        'The merge was given up at $clock: Hadco could not be read three '
        'times in a row.',
      );
    });

    testWidgets('a merge given up says so, with Save backup and merge to '
        'try again', (tester) async {
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          people: 1216,
          extras: 1385,
          last: ContactSyncCopiesResult(
            at: at1042,
            people: 120,
            deleted: 130,
            added: 40,
            stoppedShort: true,
          ),
        ),
      );
      final clock = formatClock(at1042, use24h: false);
      inOrder(tester, button('contact-sync-copies'), [
        'The merge was given up at $clock: Hadco could not be read three '
            'times in a row. Before that: 120 people merged, 130 copies '
            'deleted, 40 details added. Save backup and merge to try again.',
        '1216 people have 1385 other copies in Hadco.',
        'Save backup and merge',
      ]);
      expect(enabled(tester, 'contact-sync-copies-merge'), isTrue);

      // Not offered before the first sync is done: not pointed to either.
      sync.set(synced(
        firstDone: false,
        copies: ContactSyncCopies(
          people: 1216,
          extras: 1385,
          last: ContactSyncCopiesResult(at: at1042, stoppedShort: true),
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('The merge was given up at $clock: Hadco could not be read '
            'three times in a row.'),
        findsOneWidget,
      );
    });

    testWidgets('a pass that stopped short says the next sync tries again',
        (tester) async {
      final stopped = ContactSyncCopies(
        people: 1336,
        extras: 1515,
        asked: true,
        shortStops: 1,
      );
      await openDuplicates(tester, copies: stopped);
      const tries = 'The last try stopped short: Hadco could not be read. The '
          'next sync tries again (in about an hour, or Sync now).';
      expect(
        find.descendant(
          of: button('contact-sync-copies'),
          matching: find.text(tries),
        ),
        findsOneWidget,
      );
      expect(find.text('Merge asked for: the next sync carries it out.'),
          findsNothing);
      expect(find.textContaining('Keep MyEmail open'), findsNothing,
          reason: 'the next pass may wait the hour');
      expect(button('contact-sync-copies-merge'), findsNothing,
          reason: 'asked: no button, as before');

      // Merging again: how far it has got, as before.
      sync.set(synced(
        copies: stopped,
        running: const ContactSyncProgress(
          step: ContactSyncStep.merging,
          done: 10,
          total: 1336,
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.text('Merging: 10 of 1336 people'), findsOneWidget);
      expect(find.text(tries), findsNothing);

      // No short stop: as before.
      sync.set(synced(
        copies: const ContactSyncCopies(
          people: 1336,
          extras: 1515,
          asked: true,
        ),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.text(tries), findsNothing);
      expect(
        find.text('Merge asked for: the next sync carries it out.'),
        findsOneWidget,
      );
    });

    testWidgets('a merge asked for whose sync has stopped says why it waits, '
        'with the way on', (tester) async {
      const asked = ContactSyncCopies(people: 1336, extras: 1515, asked: true);
      ContactSyncStatus stopped(
        ContactSyncHalt? halt, {
        ContactSyncProgress? running,
      }) =>
          synced(
            copies: asked,
            halt: halt,
            running: running,
            duplicates: const [
              ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
            ],
          );
      await openDuplicates(tester, copies: asked);
      const waits = 'Merge asked for: it starts once the sync can carry on.';
      final panel = button('contact-sync-copies');
      final clock = formatClock(at1042, use24h: false);

      // The sync stopped, as Ron waits here for the merge.
      sync.set(stopped(ContactSyncHalt(
        kind: ContactSyncHaltKind.failed,
        at: at1042,
        error: const ContactSyncFailed('Hadco could not be reached.'),
      )));
      await tester.pumpAndSettle();
      inOrder(tester, panel, [
        waits,
        'The last sync stopped at $clock.',
        'Hadco could not be reached.',
        'Sync now',
      ]);
      expect(find.text('Merge asked for: the next sync carries it out.'),
          findsNothing);
      await tester.tap(button('contact-sync-copies-sync-now'));
      await tester.pumpAndSettle();
      expect(sync.count('syncNow'), 1);

      // Each stop in the Contact sync screen's own words.
      sync.set(stopped(ContactSyncHalt(
        kind: ContactSyncHaltKind.notAllowed,
        at: at1042,
        side: ContactSide.graph,
        error: const ContactSyncNeedsSignIn(
          side: ContactSide.graph,
          accountId: 'acct-h',
          message: 'Hadco needs you to sign in again.',
        ),
      )));
      await tester.pumpAndSettle();
      inOrder(tester, panel, [
        waits,
        'Contact sync has stopped: not allowed yet for Hadco.',
        'Hadco needs you to sign in again.',
        'Sync now',
      ]);
      sync.set(stopped(ContactSyncHalt(
        kind: ContactSyncHaltKind.emptyAnswer,
        at: at1042,
        side: ContactSide.graph,
      )));
      await tester.pumpAndSettle();
      inOrder(tester, panel, [
        waits,
        'Contact sync has stopped: Hadco listed far fewer contacts than '
            'expected.',
        'Sync now',
      ]);
      final renewed = at1042.add(const Duration(hours: 2));
      sync.set(stopped(ContactSyncHalt(
        kind: ContactSyncHaltKind.quota,
        at: at1042,
        side: ContactSide.google,
        until: renewed,
      )));
      await tester.pumpAndSettle();
      inOrder(tester, panel, [
        waits,
        "Google's daily limit on changes to contacts is spent. Contact sync "
            'carries on after ${formatClock(renewed, use24h: false)}.',
        'Sync now',
      ]);

      // Another device's claim, which Sync now would only meet again: Sync
      // here, as the Contact sync screen offers.
      sync.set(stopped(ContactSyncHalt(
        kind: ContactSyncHaltKind.otherDevice,
        at: at1042,
        claimedAt: at1042,
      )));
      await tester.pumpAndSettle();
      inOrder(tester, panel, [
        waits,
        'Contact sync is on on your other device',
        'It last synced there at $clock. Only one device may sync, or the '
            'two would work against each other: turn it off there, or sync '
            'here instead.',
        'Sync here',
      ]);
      expect(button('contact-sync-copies-sync-now'), findsNothing);
      await tester.tap(button('contact-sync-copies-here'));
      await tester.pumpAndSettle();
      expect(sync.count('syncHere'), 1);

      // Put away: nothing to say, the next opening carries it on.
      sync.set(stopped(ContactSyncHalt(
        kind: ContactSyncHaltKind.putAway,
        at: at1042,
      )));
      await tester.pumpAndSettle();
      expect(find.text('Merge asked for: the next sync carries it out.'),
          findsOneWidget);
      expect(button('contact-sync-copies-stop'), findsNothing);
      expect(button('contact-sync-copies-sync-now'), findsNothing);

      // A sync going again: how far it has got, not the stop before it.
      sync.set(stopped(
        ContactSyncHalt(kind: ContactSyncHaltKind.failed, at: at1042),
        running: const ContactSyncProgress(step: ContactSyncStep.reading),
      ));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Merge asked for: it starts once the sync has made its '
            'changes.'),
        findsOneWidget,
      );
      expect(button('contact-sync-copies-stop'), findsNothing);
      expect(button('contact-sync-copies-sync-now'), findsNothing);
    });

    testWidgets("copies that differ: each copy's values, and Keep these or "
        'Leave them', (tester) async {
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          last: ContactSyncCopiesResult(
            at: at1042,
            people: 5,
            deleted: 6,
            differing: 2,
          ),
          differing: const [annDiffers, benDiffers],
        ),
      );

      expect(find.text('Copies that differ (2)'), findsOneWidget);
      expect(
        find.text("Keep these puts that copy's values in the synced copy, "
            'which always stays, and in Gmail at the next sync; then every '
            'other copy is deleted, and Outlook keeps it for a while. Values '
            'the synced copy loses are kept only in your backup file. Leave '
            'them leaves every copy as it is. An answer is carried out in the '
            'next sync, which starts at once.'),
        findsOneWidget,
      );
      final ann = button('contact-sync-copies-person:p1');
      final ben = button('contact-sync-copies-person:p2');
      inOrder(tester, ann, [
        'Ann Cole',
        'Synced copy',
        'Job title: Buyer',
        'Work address: (none)',
        'Other copy',
        'Job title: Head buyer',
        'Work address: 12 Main St, Atlanta GA 30301',
        'Leave them',
      ]);
      inOrder(tester, ben, [
        'Ben Day',
        'Synced copy',
        'Notes: Met at the fair',
        'Copy 2',
        'Notes: (long note)',
        'Copy 3',
        'Notes: (none)',
        'Leave them',
      ]);
      expect(find.descendant(of: ann, matching: find.text('Keep these')),
          findsNWidgets(2));
      expect(find.descendant(of: ben, matching: find.text('Keep these')),
          findsNWidgets(3));
      // Under the merge, and above everyone with copies.
      expect(top(tester, find.text('Copies that differ (2)')),
          greaterThan(top(tester, button('contact-sync-copies'))));
      expect(top(tester, find.text('People with copies (1)')),
          greaterThan(top(tester, ben)));

      await tester.tap(button('contact-sync-copies-keep:p1:a2'));
      await tester.pumpAndSettle();
      await tester.tap(button('contact-sync-copies-leave:p2'));
      await tester.pumpAndSettle();
      expect(
        sync.copiesAnswers,
        [
          (person: 'p1', keep: 'a2', version: 'va'),
          (person: 'p2', keep: null, version: 'vb'),
        ],
        reason: 'each on the differences shown',
      );
    });

    testWidgets('a person answered shows the answer, and no buttons',
        (tester) async {
      ContactSyncCopiesPerson answered(
        ContactSyncCopiesPerson p,
        String key,
        String answer,
      ) =>
          ContactSyncCopiesPerson(
            key: key,
            title: p.title,
            copies: p.copies,
            answer: answer,
          );
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          differing: [
            answered(annDiffers, 'p1', 'a2'),
            answered(benDiffers, 'p2', 'b3'),
            answered(annDiffers, 'p3', 'a1'),
            answered(benDiffers, 'p4', ContactSyncCopiesPerson.leave),
          ],
        ),
      );

      for (final (key, said) in [
        ('p1', "You chose the other copy's details; the next sync carries it "
            'out.'),
        ('p2', "You chose Copy 3's details; the next sync carries it out."),
        ('p3', "You chose the synced copy's details; the next sync carries "
            'it out.'),
        ('p4', 'You chose to leave them as they are; the next sync carries '
            'it out.'),
      ]) {
        final person = button('contact-sync-copies-person:$key');
        expect(find.descendant(of: person, matching: find.text(said)),
            findsOneWidget, reason: key);
        expect(
          find.descendant(
            of: person,
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
          findsNothing,
          reason: key,
        );
      }
      expect(button('contact-sync-copies-all'), findsNothing);
    });

    testWidgets('an answer three syncs could not carry out says so, and that '
        'each sync tries again', (tester) async {
      ContactSyncCopiesPerson answered(String key, int tries) =>
          ContactSyncCopiesPerson(
            key: key,
            title: annDiffers.title,
            copies: annDiffers.copies,
            answer: 'a2',
            tries: tries,
          );
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          differing: [answered('p1', 2), answered('p2', 3)],
        ),
      );

      expect(
        find.descendant(
          of: button('contact-sync-copies-person:p1'),
          matching: find.text("You chose the other copy's details; the next "
              'sync carries it out.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: button('contact-sync-copies-person:p2'),
          matching: find.text("You chose the other copy's details; the last 3 "
              'syncs could not carry it out, and each sync tries again.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("Keep the synced copy's for all, asked first",
        (tester) async {
      await openDuplicates(
        tester,
        copies: ContactSyncCopies(
          differing: [
            const ContactSyncCopiesPerson(
              key: 'p0',
              title: 'Abe Ash',
              copies: [ContactSyncCopy(key: 'x1', synced: true)],
              answer: ContactSyncCopiesPerson.leave,
            ),
            annDiffers,
            benDiffers,
          ],
        ),
      );

      expect(find.text('Copies that differ (3)'), findsOneWidget);
      expect(find.text("Keep the synced copy's for all 2"), findsOneWidget,
          reason: 'those not yet answered');
      expect(
        top(tester, button('contact-sync-copies-all')),
        lessThan(top(tester, button('contact-sync-copies-person:p0'))),
      );
      await tester.tap(button('contact-sync-copies-all'));
      await tester.pumpAndSettle();
      expect(
        find.text("Keep the synced copy's details for all 2?"),
        findsOneWidget,
      );
      expect(
        find.text('For each of the 2 people, the synced copy keeps its values '
            'and gains the details only another copy has, and the other '
            'copies are deleted at the next sync, which starts at once. '
            'Outlook keeps deleted contacts for a while: in Deleted Items, or '
            'under Recover items deleted from this folder at the top of '
            'Deleted Items.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sync.count('answerAllCopies'), 0);

      await tester.tap(button('contact-sync-copies-all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Keep the synced copy's"));
      await tester.pumpAndSettle();
      expect(sync.allCopiesAnswers, [
        {'p1': 'va', 'p2': 'vb'},
      ]);
      expect(sync.copiesAnswers, isEmpty);
      for (final key in ['p1', 'p2']) {
        expect(
          find.descendant(
            of: button('contact-sync-copies-person:$key'),
            matching: find.text("You chose the synced copy's details; the "
                'next sync carries it out.'),
          ),
          findsOneWidget,
          reason: '$key, before the status says so',
        );
      }

      // Listed again with other differences, and one more found while the
      // question is up: only those shown are answered, as shown.
      ContactSyncCopiesPerson changed(
        ContactSyncCopiesPerson p,
        String version,
      ) =>
          ContactSyncCopiesPerson(
            key: p.key,
            title: p.title,
            copies: p.copies,
            version: version,
          );
      ContactSyncStatus listing(List<ContactSyncCopiesPerson> differing) =>
          synced(
            copies: ContactSyncCopies(differing: differing),
            duplicates: const [
              ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 2),
            ],
          );
      sync.set(listing([
        changed(annDiffers, 'va2'),
        changed(benDiffers, 'vb2'),
      ]));
      await tester.pumpAndSettle();
      expect(find.text("Keep the synced copy's for all 2"), findsOneWidget,
          reason: 'the answers given were on other differences');
      await tester.tap(button('contact-sync-copies-all'));
      await tester.pumpAndSettle();
      sync.set(listing([
        changed(annDiffers, 'va2'),
        changed(benDiffers, 'vb2'),
        const ContactSyncCopiesPerson(
          key: 'p3',
          title: 'Cy Fox',
          version: 'vc',
          copies: [
            ContactSyncCopy(key: 'c1', synced: true),
            ContactSyncCopy(key: 'c2'),
          ],
        ),
      ]));
      await tester.pump();
      await tester.tap(find.text("Keep the synced copy's"));
      await tester.pumpAndSettle();
      expect(sync.allCopiesAnswers.last, {'p1': 'va2', 'p2': 'vb2'});

      // One left to answer: its own buttons are enough.
      sync.set(listing([changed(annDiffers, 'va3')]));
      await tester.pumpAndSettle();
      expect(button('contact-sync-copies-keep:p1:a1'), findsOneWidget);
      expect(button('contact-sync-copies-all'), findsNothing);
    });

    testWidgets("Keep the synced copy's for all is off while a merge is "
        'asked for', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(
          people: 300,
          extras: 400,
          asked: true,
          differing: [annDiffers, benDiffers],
        ),
      );
      expect(find.text("Keep the synced copy's for all 2"), findsOneWidget);
      expect(enabled(tester, 'contact-sync-copies-all'), isFalse,
          reason: 'the merge lists people as it goes');
      expect(enabled(tester, 'contact-sync-copies-keep:p1:a1'), isTrue,
          reason: "each person's own answers stay");

      sync.set(synced(
        copies: const ContactSyncCopies(differing: [annDiffers, benDiffers]),
        duplicates: const [
          ContactSyncDuplicates(title: 'Ann Cole', graphCopies: 3),
        ],
      ));
      await tester.pumpAndSettle();
      expect(enabled(tester, 'contact-sync-copies-all'), isTrue);
    });

    testWidgets('an answer refused because the person changed is said, and '
        'the list read again', (tester) async {
      await openDuplicates(
        tester,
        copies: const ContactSyncCopies(differing: [annDiffers]),
      );
      sync.copiesFailure = const ContactSyncRefused(
        "This person's copies have changed since they were shown. Look "
        'again.',
      );
      final readsBefore = sync.statusReads;

      await tester.tap(button('contact-sync-copies-keep:p1:a1'));
      await tester.pumpAndSettle();
      expect(
        find.text("This person's copies have changed since they were shown. "
            'Look again.'),
        findsOneWidget,
      );
      expect(sync.statusReads, greaterThan(readsBefore),
          reason: 'read again, to be answered as it is now');
    });

    testWidgets('a few hundred people whose copies differ scroll to the last',
        (tester) async {
      await openDuplicates(
        tester,
        size: const Size(412, 915),
        copies: ContactSyncCopies(
          differing: [
            for (var i = 0; i < 300; i++)
              ContactSyncCopiesPerson(
                key: 'k$i',
                title: 'Person ${i.toString().padLeft(3, '0')}',
                copies: const [
                  ContactSyncCopy(
                    key: 's',
                    synced: true,
                    details: [ContactSyncCopyDetail(label: 'Job title')],
                  ),
                  ContactSyncCopy(
                    key: 'o',
                    details: [
                      ContactSyncCopyDetail(label: 'Job title', value: 'Buyer'),
                    ],
                  ),
                ],
              ),
          ],
        ),
      );

      final last = button('contact-sync-copies-person:k299');
      expect(
        find.byKey(
          const ValueKey('contact-sync-copies-person:k299'),
          skipOffstage: false,
        ),
        findsNothing,
        reason: 'built as it scrolls, not all three hundred at once',
      );
      await tester.scrollUntilVisible(
        last,
        900,
        maxScrolls: 200,
        scrollable: find.descendant(
          of: button('contact-sync-duplicates-list'),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.descendant(of: last, matching: find.text('Person 299')),
          findsOneWidget);
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

    testWidgets('a contact left by a merge in Gmail names Hadco, where its '
        'copy survives', (tester) async {
      // The runner sets the item's side to Gmail, where the merge was; the
      // buttons' "here" is the other side.
      sync = FakeContactSync(status: synced(looks: const [
        ContactSyncLook(
          id: 3,
          kind: ContactReviewKind.mergedInGoogle,
          side: ContactSide.google,
          title: 'Dana Levi',
          choices: [
            ContactSyncChoice.deleteHereToo,
            ContactSyncChoice.keepOnlyHere,
          ],
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();

      expect(
        find.text('Merged in Gmail with another contact: delete it in Hadco '
            'too, or keep it only there.'),
        findsOneWidget,
      );
      expect(find.text('Keep it only in Hadco'), findsOneWidget);
      await tester.tap(find.text('Delete it in Hadco too'));
      await tester.pumpAndSettle();
      expect(sync.lookAnswers, [
        (id: 3, choice: ContactSyncChoice.deleteHereToo, candidateId: null),
      ]);
    });

    testWidgets('a Restore refused says why under the contact, and Restore '
        'is offered again', (tester) async {
      sync = FakeContactSync(status: synced(deleted: [
        ContactSyncDeleted(
          id: 7,
          title: 'Rina Dar',
          side: ContactSide.google,
          state: ContactSyncDeletedState.deleted,
          deletedAt: at1042,
          // Whether or not the runner keeps it marked as asked for.
          restoreAsked: true,
          restoreProblem: 'Could not restore. Google would not take the '
              'contact (HTTP 400, INVALID_ARGUMENT).',
        ),
      ]));
      engine = _Engine(sync, const [gmail, hadco]);
      await pumpScreen(tester);
      await tester.tap(find.text('Recently deleted (1)'));
      await tester.pumpAndSettle();

      final row = button('contact-sync-deleted:7');
      expect(
        find.descendant(
          of: row,
          matching: find.text('Could not restore. Google would not take the '
              'contact (HTTP 400, INVALID_ARGUMENT).'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Restore asked for'), findsNothing,
          reason: 'not waiting: refused');
      await tester.tap(find.descendant(of: row, matching: find.text('Restore')));
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

      expect(button('contact-sync-replace'), findsNothing,
          reason: 'its first sync has not started: nothing to set aside');
      expect(sync.chosen.last, (google: 'acct-g', graph: 'acct-m'));
      expect(button('contact-sync-access:acct-m'), findsOneWidget);
    });

    testWidgets('replacing a pair whose first sync has started asks first',
        (tester) async {
      engine = _Engine(sync, const [gmail, hadco, studio]);
      await pumpScreen(tester);

      Future<void> pickStudio() async {
        await tester.tap(button('contact-sync-with'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Myhomestudio'));
        await tester.pumpAndSettle();
      }

      await pickStudio();
      expect(find.text('Sync Gmail with Myhomestudio instead?'),
          findsOneWidget);
      expect(
        find.text('Gmail and Hadco stop syncing. Their Needs a look and '
            'Recently deleted are set aside, and come back if you choose '
            'them again; no contact is deleted. The new pair starts with a '
            'first sync of its own.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sync.chosen, isEmpty);
      expect(
        find.descendant(
          of: button('contact-sync-with'),
          matching: find.text('Hadco'),
        ),
        findsOneWidget,
      );

      await pickStudio();
      await tester.tap(find.text('Switch accounts'));
      await tester.pumpAndSettle();
      expect(sync.chosen, [(google: 'acct-g', graph: 'acct-m')]);
    });

    testWidgets('a pick the runner refuses leaves the pair it has',
        (tester) async {
      sync = FakeContactSync(status: synced(
        running: const ContactSyncProgress(
          step: ContactSyncStep.writing,
          done: 1,
          total: 4,
        ),
        questions: const [
          ContactSyncQuestion(
            kind: ContactSyncQuestionKind.deletions,
            items: [
              ContactSyncQuestionItem(title: 'Ann', side: ContactSide.google),
            ],
          ),
        ],
      ))
        ..chooseFailure = const ContactSyncRefused('Contact sync is running.');
      engine = _Engine(sync, const [gmail, hadco, studio]);
      await pumpScreen(tester);
      // A send's Undo along the bottom, which the refusal must not take
      // away.
      ScaffoldMessenger.of(tester.element(find.byType(ContactSyncScreen)))
          .showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        persist: false,
        content: const Text('Sending'),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(button('contact-sync-with'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Myhomestudio'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Switch accounts'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(sync.count('choose'), 1);
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.text('Contact sync is running.'), findsOneWidget);
      expect(
        find.descendant(
          of: button('contact-sync-with'),
          matching: find.text('Hadco'),
        ),
        findsOneWidget,
      );
      expect(button('contact-sync-access:acct-m'), findsNothing);
      expect(find.text('Delete them'), findsOneWidget);
      expect(find.text('First sync'), findsNothing);
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
              // Two, each answerable alone, with long details and hints.
              items: [
                for (final key in ['a', 'b'])
                  ContactSyncQuestionItem(
                    title: 'Alexandra Rosenblum-Katzenellenbogen',
                    side: ContactSide.graph,
                    key: key,
                    hint: kind == ContactSyncQuestionKind.deletions
                        ? 'alexandra.rosenblum-katzenellenbogen@'
                            'northwind-steel.example'
                        : null,
                    changes: kind == ContactSyncQuestionKind.changes
                        ? const [
                            ContactSyncDetailChange(
                              field: ContactField.workAddress,
                              before: '1200 Peachtree Industrial Boulevard, '
                                  'Suite 400, Atlanta GA 30341',
                              after: '88 Harbor Road, Smyrna GA 30080',
                            ),
                            ContactSyncDetailChange(
                              field: ContactField.mobile,
                              before: '+1 404 555 0199',
                            ),
                          ]
                        : const [],
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
        duplicates: const [
          ContactSyncDuplicates(
            title: 'Alexandra Rosenblum-Katzenellenbogen',
            googleCopies: 12,
            graphCopies: 1,
            googleSynced: true,
          ),
        ],
        copies: ContactSyncCopies(
          people: 3,
          extras: 4,
          notSynced: 12,
          last: ContactSyncCopiesResult(
            at: at1042,
            people: 1089,
            deleted: 1143,
            added: 210,
            differing: 2,
            failed: 2,
          ),
          differing: [
            for (final key in ['a', 'b'])
              ContactSyncCopiesPerson(
                key: key,
                title: 'Alexandra Rosenblum-Katzenellenbogen',
                copies: const [
                  ContactSyncCopy(
                    key: 's',
                    synced: true,
                    details: [
                      ContactSyncCopyDetail(
                        label: 'Work address',
                        value: '1200 Peachtree Industrial Boulevard, Suite '
                            '400, Atlanta GA 30341',
                      ),
                      ContactSyncCopyDetail(label: 'Job title'),
                    ],
                  ),
                  ContactSyncCopy(
                    key: 'o',
                    details: [
                      ContactSyncCopyDetail(
                        label: 'Work address',
                        value: '88 Harbor Road, Smyrna GA 30080',
                      ),
                      ContactSyncCopyDetail(
                        label: 'Job title',
                        value: 'Purchasing and logistics coordinator',
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
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
        button('contact-sync-item:b:dontDelete'),
        find.text('Copy them back'),
        button('contact-sync-item:b:copyThemBack'),
        find.text("That's right, carry on"),
        find.textContaining("Turn this off before using Google's Undo"),
      ]) {
        await tester.scrollUntilVisible(part, 300, scrollable: list);
      }
      await tester.scrollUntilVisible(
        find.text('Needs a look (1)'),
        -300,
        scrollable: list,
      );
      await tester.ensureVisible(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needs a look (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Same person'), findsOneWidget);
      Navigator.of(tester.element(find.text('Same person'))).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recently deleted (1)'),
        300,
        scrollable: list,
      );
      await tester.ensureVisible(find.text('Recently deleted (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently deleted (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
      Navigator.of(tester.element(find.text('Restore'))).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Duplicates to merge when you like (1 person)'),
        -300,
        scrollable: list,
      );
      await tester.ensureVisible(
        find.text('Duplicates to merge when you like (1 person)'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Duplicates to merge when you like (1 person)'),
      );
      await tester.pumpAndSettle();
      final duplicates = find.descendant(
        of: button('contact-sync-duplicates-list'),
        matching: find.byType(Scrollable),
      );
      for (final part in [
        button('contact-sync-copies-what'),
        button('contact-sync-copies-merge'),
        button('contact-sync-copies-all'),
        button('contact-sync-copies-keep:b:o'),
        button('contact-sync-copies-leave:b'),
      ]) {
        await tester.scrollUntilVisible(part, 300, scrollable: duplicates);
        expect(part, findsOneWidget);
      }
      // Under the text, which at this size fills most of the screen.
      final person = find.text(
        'Alexandra Rosenblum-Katzenellenbogen: 12 in Gmail, 1 in Hadco; one '
        'in Gmail is synced',
      );
      await tester.scrollUntilVisible(person, 300, scrollable: duplicates);
      expect(person, findsOneWidget);
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

    /// [engine]: one with Gmail and Hadco, for the screens that need the
    /// pair's accounts; else the sample's own.
    Future<void> pumpApp(
      WidgetTester tester, {
      bool on = true,
      MailEngine? engine,
    }) async {
      if (on) await ui.writeString(UiStateKeys.contactSyncDevice, 'on');
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine ?? _SampleWith(sync)),
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
      expect(sync.statusReads, 0, reason: 'its status is not even read');
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

    testWidgets("a stop said while in front waits behind a send's Undo",
        (tester) async {
      sync = FakeContactSync(status: synced());
      await pumpApp(tester);
      ScaffoldMessenger.of(tester.element(find.byType(AppShell))).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          persist: false,
          content: const Text('Sending'),
          action: SnackBarAction(label: 'Undo', onPressed: () {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final at = DateTime(today.year, today.month, today.day, 9);
      sync.set(synced(notice: ContactSyncNotice(at: at, heldDeletions: 7)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Undo'), findsOneWidget, reason: 'not taken away');
      expect(find.textContaining('Contact sync has stopped'), findsNothing);
      expect(sync.noticesSeen, isEmpty, reason: 'not seen until it is shown');

      // Its turn comes once the Undo has had its time.
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.text('Contact sync has stopped: 7 deletions need your OK'),
          findsOneWidget);
      expect(sync.noticesSeen, [at]);
    });

    testWidgets('a stop whose turn comes over the Contact sync screen is not '
        'shown there, and is seen then', (tester) async {
      sync = FakeContactSync(status: synced());
      await pumpApp(tester);
      // A held send's bar, which waits until it is answered.
      final messenger =
          ScaffoldMessenger.of(tester.element(find.byType(AppShell)));
      messenger.showSnackBar(SnackBar(
        persist: true,
        content: const Text('Held'),
        action: SnackBarAction(label: 'Open', onPressed: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      final at = DateTime(today.year, today.month, today.day, 9);
      sync.set(synced(notice: ContactSyncNotice(at: at, heldDeletions: 7)));
      await tester.pump(const Duration(seconds: 30));
      expect(sync.noticesSeen, isEmpty,
          reason: 'behind a bar that waits, it may never be shown');

      unawaited(tester.state<NavigatorState>(find.byType(Navigator).first)
          .push(MaterialPageRoute<void>(
        builder: (_) => const ContactSyncScreen(),
      )));
      await tester.pumpAndSettle();
      messenger.removeCurrentSnackBar();
      await tester.pumpAndSettle();

      expect(find.textContaining('Contact sync has stopped'), findsNothing);
      expect(sync.noticesSeen, [at], reason: 'the screen shows it');
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

    testWidgets('a stop while Duplicates to merge is open over the Contact '
        'sync screen is said there, which shows no stop', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const duplicates = [
        ContactSyncDuplicates(
          title: 'Ann Cole',
          googleCopies: 1,
          graphCopies: 2,
          googleSynced: true,
          graphSynced: true,
        ),
      ];
      const copies = ContactSyncCopies(people: 1, extras: 1, asked: true);
      sync = FakeContactSync(
        status: synced(duplicates: duplicates, copies: copies),
      );
      await pumpApp(tester, engine: _Engine(sync, const [gmail, hadco]));
      unawaited(tester.state<NavigatorState>(find.byType(Navigator).first)
          .push(MaterialPageRoute<void>(
        builder: (_) => const ContactSyncScreen(),
      )));
      await tester.pumpAndSettle();
      // Ron waits on Duplicates to merge for the merge he asked for.
      await tester.tap(
        find.text('Duplicates to merge when you like (1 person)'),
      );
      await tester.pumpAndSettle();

      final first = DateTime(today.year, today.month, today.day, 9);
      ContactSyncStatus stopped(DateTime at) {
        final halt = ContactSyncHalt(
          kind: ContactSyncHaltKind.failed,
          at: at,
          error: const ContactSyncFailed('Hadco could not be reached.'),
        );
        return synced(
          halt: halt,
          notice: ContactSyncNotice(at: at, halt: halt),
          duplicates: duplicates,
          copies: copies,
        );
      }

      sync.set(stopped(first));
      await tester.pumpAndSettle();
      expect(find.text('Contact sync could not finish'), findsOneWidget);
      expect(sync.noticesSeen, [first]);

      // Back on the Contact sync screen, which shows the stop: the next one
      // is not said there.
      final inner = tester.element(find.text('Duplicates to merge'));
      ScaffoldMessenger.of(inner).removeCurrentSnackBar();
      Navigator.of(inner).pop();
      await tester.pumpAndSettle();
      final second = first.add(const Duration(hours: 1));
      sync.set(stopped(second));
      await tester.pumpAndSettle();
      expect(find.text('Contact sync could not finish'), findsNothing);
      expect(sync.noticesSeen, [first, second]);
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

  /// Holds a save until completed, as the save dialog waits for Ron.
  Completer<bool>? gate;
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
    if (gate case final gate?) return gate.future;
    return answers.isEmpty ? true : answers.removeAt(0);
  }

  @override
  Future<String?> pick() async => null;
}
