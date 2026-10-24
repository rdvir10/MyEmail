import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:enough_mail/enough_mail.dart' as em;
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/put_away_providers.dart';
import 'package:myemail/ui/shell/put_away.dart';
import 'package:myemail/data/compose/quote_builder.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/ui/common/problem_view.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/compose/header_fields.dart';
import 'package:myemail/ui/compose/open_compose.dart';

import 'fakes/fake_imap_transport.dart';
import 'fakes/fake_webview.dart';

Draft _draft({
  String subject = 'Half written',
  String html = '<p>Some words</p>',
  List<MailAddress> to = const [MailAddress(email: 'you@example.com')],
  String? savedAs,
  String accountId = 'a',
}) =>
    Draft(
      accountId: accountId,
      kind: ComposeKind.newMessage,
      to: to,
      subject: subject,
      htmlBody: html,
      savedAs: savedAs,
    );

/// The compose screen's Subject line.
Finder subjectField() => find.descendant(
      of: find.byWidgetPredicate(
          (w) => w is HeaderField && w.label == 'Subject'),
      matching: find.byType(TextField),
    );

String subject(WidgetTester tester) =>
    tester.widget<TextField>(subjectField()).controller!.text;

void main() {
  group('isWorthSaving', () {
    test('an untouched compose window is not', () {
      // Opening compose and changing your mind should not leave a blank draft
      // on the server, nor produce a dialog on the way out.
      expect(
        _draft(subject: '', html: '<p><br></p>', to: const []).isWorthSaving,
        isFalse,
      );
    });

    test('a reply with nothing typed above the quote is not', () {
      // The editor holds the whole quoted original from the moment it opens,
      // so "is the body empty" cannot be a string test on the HTML.
      final untouched = Draft(
        accountId: 'a',
        kind: ComposeKind.reply,
        htmlBody: '<p><br></p><blockquote><p>Their message</p></blockquote>',
      );
      expect(untouched.isWorthSaving, isFalse);
    });

    test('anything actually typed is', () {
      expect(_draft(subject: '', to: const []).isWorthSaving, isTrue);
      expect(
        _draft(subject: 'Just a subject', html: '<p><br></p>', to: const [])
            .isWorthSaving,
        isTrue,
      );
      expect(
        _draft(subject: '', html: '<p><br></p>').isWorthSaving,
        isTrue,
        reason: 'a recipient with nothing else is still worth keeping',
      );
    });

    test('an attachment alone is worth keeping', () {
      final withFile = Draft(
        accountId: 'a',
        kind: ComposeKind.newMessage,
        htmlBody: '<p><br></p>',
        attachments: [
          DraftAttachment(
            fileName: 'notes.txt',
            mimeType: 'text/plain',
            bytes: Uint8List(4),
          ),
        ],
      );
      expect(withFile.isWorthSaving, isTrue);
    });

    test('markup and spaces are not text', () {
      expect(
        _draft(subject: '', html: '<div>  &nbsp; <br></div>', to: const [])
            .isWorthSaving,
        isFalse,
      );
    });

    test('a signature the window put there is not writing', () {
      // Built the way a new message really is. Counted as text, every new
      // message on an account with a signature asked to be saved, and
      // Save draft put a signature on its own into Drafts.
      final untouched = Draft(
        accountId: 'a',
        kind: ComposeKind.newMessage,
        htmlBody: buildComposeHtml(
          kind: ComposeKind.newMessage,
          signatureHtml: '<p>Ron Dvir<br>MyHomeStudio</p>',
        ),
      );
      expect(untouched.isWorthSaving, isFalse);
      expect(
        untouched
            .copyWith(htmlBody: '<p>Hello</p>${untouched.htmlBody}')
            .isWorthSaving,
        isTrue,
      );
    });
  });

  group('saveDraft against a server', () {
    late FakeImapTransport server;
    late MemoryCacheStore cache;
    late CachedImapEngine engine;

    setUp(() {
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('[Gmail]/Drafts', role: FolderRole.drafts);
      cache = MemoryCacheStore();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => server,
        // Without this the send path opens a real socket to smtp.gmail.com
        // with a made-up password. A unit test must not touch the network.
        senderFactory: (_, _) =>
            const _SilentSender(
              host: 'smtp.example',
              user: '',
              credentials: PasswordCredentials(''),
            ),
      );
    });

    Future<Account> addAccount() => engine.addAccount(
          displayName: 'Personal',
          emailAddress: 'me@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );

    test('a draft is appended to Drafts with the Draft flag', () async {
      final account = await addAccount();

      final savedAs = await engine.saveDraft(_draft(accountId: account.id));

      expect(savedAs, isNotNull);
      expect(server.calls, contains(r'APPEND [Gmail]/Drafts \Draft'));
      expect(server.appended.single, contains('Half written'));
    });

    test('saving twice replaces rather than piling up versions', () async {
      final account = await addAccount();
      final first = await engine.saveDraft(_draft(accountId: account.id));

      await engine.saveDraft(
        _draft(accountId: account.id, subject: 'Second go', savedAs: first),
      );

      expect(server.calls, contains('EXPUNGE [Gmail]/Drafts'));
      expect(
        server.folder('[Gmail]/Drafts').messages.length,
        1,
        reason: 'the previous version was removed',
      );
    });

    test('the new copy is appended before the old one is deleted', () async {
      // The other order loses the draft outright if the append then fails.
      final account = await addAccount();
      final first = await engine.saveDraft(_draft(accountId: account.id));
      server.calls.clear();

      await engine.saveDraft(_draft(accountId: account.id, savedAs: first));

      final appendAt = server.calls.indexWhere((c) => c.startsWith('APPEND'));
      final expungeAt = server.calls.indexWhere((c) => c.startsWith('EXPUNGE'));
      expect(appendAt, greaterThanOrEqualTo(0));
      expect(expungeAt, greaterThan(appendAt));
    });

    test('an account with no Drafts folder says nothing was saved', () async {
      // It used to return quietly, and compose closed on "Saved to Drafts"
      // with the message saved nowhere. An error keeps compose open.
      server.folders.remove('[Gmail]/Drafts');
      final account = await addAccount();

      await expectLater(
        engine.saveDraft(_draft(accountId: account.id)),
        throwsA(isA<SendFailed>().having(
          (e) => e.message,
          'message',
          contains('not saved'),
        )),
      );
      expect(server.appended, isEmpty);
    });

    test('sending a saved draft clears it out of Drafts', () async {
      final account = await addAccount();
      final savedAs = await engine.saveDraft(_draft(accountId: account.id));
      expect(server.folder('[Gmail]/Drafts').messages, isNotEmpty);

      await engine.sendDraft(
        _draft(accountId: account.id, savedAs: savedAs),
      );

      expect(server.folder('[Gmail]/Drafts').messages, isEmpty,
          reason: 'it is away, so the draft is a duplicate of sent mail');
    });
  });

  group('compose screen', () {
    setUp(FakeWebViewPlatform.install);

    /// Compose pushed onto a route, so there is something to go back to.
    /// As the app's root it has no back button and pageBack cannot work.
    ///
    /// Not [disposable] unless asked: most of these stand for a message
    /// with writing in it, which is what a draft carried across from another
    /// window is.
    Future<void> open(
      WidgetTester tester,
      Draft draft, {
      bool disposable = false,
      SampleMailEngine? engine,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailEngineProvider.overrideWithValue(engine ?? SampleMailEngine()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) =>
                            ComposeScreen(draft: draft, disposable: disposable),
                      ),
                    ),
                    child: const Text('open compose'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open compose'));
      await tester.pumpAndSettle();
    }

    testWidgets('backing out of an untouched window asks nothing',
        (tester) async {
      await open(tester,
          const Draft(accountId: 'acct-personal', kind: ComposeKind.newMessage));

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Keep this message?'), findsNothing);
    });

    testWidgets('backing out of a written one offers to keep it',
        (tester) async {
      await open(tester, _draft(accountId: 'acct-personal'));

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Keep this message?'), findsOneWidget);
      expect(find.text('Save draft'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expect(find.text('Keep writing'), findsOneWidget);
    });

    testWidgets('Keep writing leaves the message on screen', (tester) async {
      await open(tester, _draft(accountId: 'acct-personal'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep writing'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
    });

    testWidgets('Save draft files it and says so', (tester) async {
      await open(tester, _draft(accountId: 'acct-personal'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();

      expect(find.text('Saved to Drafts'), findsOneWidget);
    });

    testWidgets('a reopened draft says an attachment did not come back',
        (tester) async {
      // Losing a file quietly between one session and the next is worse than
      // saying it was lost.
      // A copy of its own, as draftFromMessage opens it when the stored one
      // cannot be read, so the Bcc is gone with the file.
      await open(
        tester,
        Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.newMessage,
          subject: 'Had a file',
          htmlBody: '<p>Words</p>',
          lostAttachmentNames: const ['report.pdf'],
          storedCopyUnread: true,
        ),
      );

      expect(find.textContaining('its attachment and any Bcc'), findsOneWidget);
      expect(find.textContaining('add the Bcc again'), findsOneWidget);
      expect(find.textContaining('copy in Drafts still has them'),
          findsOneWidget);
    });

    testWidgets(
        'a reopened draft with no files still says its Bcc was not brought '
        'back, and that the copy in Drafts stays', (tester) async {
      // Nothing on screen said so: Save left two drafts with no word why,
      // and Send went without the Bcc and left the message in Drafts after
      // it had gone, to be sent again.
      await open(
        tester,
        const Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.newMessage,
          to: [MailAddress(email: 'dana@example.com')],
          subject: 'No files',
          htmlBody: '<p>Words</p>',
          storedCopyUnread: true,
        ),
      );

      expect(find.textContaining('any Bcc it had is not here'), findsOneWidget);
      expect(find.textContaining('even once this is saved or sent'),
          findsOneWidget);
      expect(find.textContaining('attachment'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Bcc'), findsNothing,
          reason: 'the line to add it on is showing already');
    });

    testWidgets('an editable draft says it will update the saved copy',
        (tester) async {
      await open(tester,
          _draft(accountId: 'acct-personal', savedAs: 'acct-personal:Drafts#3'));

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.textContaining('updates the copy in Drafts'), findsOneWidget);
    });

    testWidgets('backing out of an untouched reply asks nothing',
        (tester) async {
      // A reply has a recipient and a subject before anything is typed, so
      // one opened by mistake always asked to be saved.
      await open(
        tester,
        Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.reply,
          to: const [MailAddress(email: 'dana@example.com', name: 'Dana')],
          subject: 'Re: Budget',
          htmlBody: buildComposeHtml(
            kind: ComposeKind.reply,
            original: MailMessage(
              id: 'acct-personal:INBOX#7',
              accountId: 'acct-personal',
              folderId: 'acct-personal:INBOX',
              uid: 7,
              subject: 'Budget',
              from: const MailAddress(email: 'dana@example.com', name: 'Dana'),
              to: const [],
              date: DateTime(2026, 9, 20),
              preview: '',
            ),
            originalText: 'The numbers',
            signatureHtml: '<p>Ron</p>',
          ),
        ),
        disposable: true,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Keep this message?'), findsNothing);
      expect(find.byType(ComposeScreen), findsNothing);
    });

    testWidgets('but once anything changes, it asks', (tester) async {
      await open(
        tester,
        const Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.reply,
          to: [MailAddress(email: 'dana@example.com')],
          subject: 'Re: Budget',
          htmlBody: '<p><br></p>',
        ),
        disposable: true,
      );

      await tester.enterText(
          find.widgetWithText(TextField, 'Re: Budget'), 'Re: Budget, again');
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Keep this message?'), findsOneWidget);
    });

    testWidgets(
        'going into the background puts it in Drafts, and Discard takes '
        'that copy out again', (tester) async {
      // Android can end the app while the file picker is up or it sits in
      // Recents, and a message that lived only on screen went with it.
      final engine = SampleMailEngine();
      const draftsId = 'acct-personal:[Gmail]/Drafts';
      Future<List<String>> drafts() async =>
          (await tester.runAsync(() => engine.loadMessages(draftsId)))!
              .map((m) => m.subject)
              .toList();
      final before = await drafts();
      await open(tester, _draft(accountId: 'acct-personal'), engine: engine);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(await drafts(), unorderedEquals([...before, 'Half written']));
      expect(find.byType(ComposeScreen), findsOneWidget,
          reason: 'nothing on screen changes');

      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(await drafts(), unorderedEquals(before));
    });

    // The file picker puts the app in the background, which starts a copy
    // to Drafts. Ended before that copy landed, the window looked for it,
    // found none yet, and left it there: a sent message stayed a draft, and
    // a discarded one was saved after all.
    for (final how in ['sent', 'discarded']) {
      testWidgets(
          'a copy still being saved in the background when the message is '
          '$how is not left in Drafts', (tester) async {
        final engine = _SlowSave();
        const draftsId = 'acct-personal:[Gmail]/Drafts';
        Future<List<String>> drafts() async =>
            (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                .map((m) => m.subject)
                .toList();
        final before = await drafts();
        await open(tester, _draft(accountId: 'acct-personal'), engine: engine);

        final copying = engine.hold = Completer<void>();
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump(const Duration(milliseconds: 50));
        expect(engine.hold, isNull, reason: 'the background copy has begun');

        if (how == 'sent') {
          await tester.tap(find.byTooltip('Send'));
        } else {
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Discard'));
        }
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        expect(find.byType(ComposeScreen), findsNothing);

        // The save lands, and then whatever follows it has its turn.
        copying.complete();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(await drafts(), unorderedEquals(before));
      });
    }

    testWidgets(
        'Save draft while the background copy is still going up keeps the '
        'copy just saved', (tester) async {
      // Where a copy went is read back as the newest message in Drafts.
      // Saved alongside the background copy, Save's landed before the
      // background save looked, which took it for its own; that is the one
      // taken out as the window closed, and the older copy stayed.
      final engine = _SlowSave();
      const draftsId = 'acct-personal:[Gmail]/Drafts';
      Future<List<String>> drafts() async =>
          (await tester.runAsync(() => engine.loadMessages(draftsId)))!
              .map((m) => m.subject)
              .toList();
      final before = await drafts();
      await open(tester, _draft(accountId: 'acct-personal'), engine: engine);

      final copying = engine.hold = Completer<void>();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.hold, isNull, reason: 'the background copy has begun');

      // Back from the picker, something changes before Save.
      await tester.enterText(
          find.widgetWithText(TextField, 'Half written'), 'Finished');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save draft'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(ComposeScreen), findsOneWidget,
          reason: 'Save waits for the copy going up');

      copying.complete();
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.text('Saved to Drafts'), findsOneWidget);
      expect(await drafts(), unorderedEquals([...before, 'Finished']));
    });

    group('put away (Home, another app)', () {
      /// What Android does: the lifecycle first, then MainActivity's word
      /// that it was the person who left.
      Future<bool> putAway(WidgetTester tester) async {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        final guards = ProviderScope.containerOf(
          tester.element(find.byType(ComposeScreen)),
        ).read(putAwayGuardsProvider);
        bool? closed;
        unawaited(closeForPutAway(
          tester.state<NavigatorState>(find.byType(Navigator)),
          guards,
        ).then((all) => closed = all));
        for (var i = 0; i < 20 && closed == null; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        // And back, which is when anything is drawn again.
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        return closed!;
      }

      testWidgets('a written message goes to Drafts once, and closes',
          (tester) async {
        final engine = SampleMailEngine();
        const draftsId = 'acct-personal:[Gmail]/Drafts';
        Future<List<String>> drafts() async =>
            (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                .map((m) => m.subject)
                .toList();
        final before = await drafts();
        await open(tester, _draft(accountId: 'acct-personal'), engine: engine);

        expect(await putAway(tester), isTrue);

        expect(find.byType(ComposeScreen), findsNothing);
        expect(find.text('open compose'), findsOneWidget);
        expect(await drafts(), unorderedEquals([...before, 'Half written']),
            reason: 'the copy saved on the way out is not left beside it');
      });

      testWidgets('a reopened draft is updated in place, not copied',
          (tester) async {
        final engine = SampleMailEngine();
        const draftsId = 'acct-personal:[Gmail]/Drafts';
        Future<List<String>> drafts() async =>
            (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                .map((m) => m.subject)
                .toList();
        final saved =
            (await tester.runAsync(() => engine.loadMessages(draftsId)))!.first;
        final others = (await drafts())..remove(saved.subject);
        await open(
          tester,
          _draft(accountId: 'acct-personal', savedAs: saved.id),
          engine: engine,
        );

        expect(await putAway(tester), isTrue);

        expect(await drafts(), unorderedEquals([...others, 'Half written']));
      });

      testWidgets('an untouched one just closes, and saves nothing',
          (tester) async {
        final engine = SampleMailEngine();
        const draftsId = 'acct-personal:[Gmail]/Drafts';
        final before =
            (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                .length;
        await open(
          tester,
          const Draft(accountId: 'acct-personal', kind: ComposeKind.newMessage),
          disposable: true,
          engine: engine,
        );

        expect(await putAway(tester), isTrue);

        expect(find.byType(ComposeScreen), findsNothing);
        expect(
          (await tester.runAsync(() => engine.loadMessages(draftsId)))!.length,
          before,
        );
      });

      group('and back before it has finished', () {
        // Saving on the way out takes seconds on Graph. Back within them,
        // the person went on typing, and the screen was then taken away
        // from under them, with what they had typed since saved nowhere.
        const draftsId = 'acct-personal:[Gmail]/Drafts';

        void leave(WidgetTester tester) {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        }

        void comeBack(WidgetTester tester) {
          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        }

        /// Where closing for the last put-away got to: null while it is
        /// still going, then whether it got all the way down.
        bool? closed;

        /// How many put-aways there have been, so an earlier one ending
        /// does not speak for the last.
        var putAways = 0;

        /// Put away while [engine] still holds the saves.
        Future<void> putAwayWhileHeld(WidgetTester tester) async {
          closed = null;
          final last = ++putAways;
          leave(tester);
          final guards = ProviderScope.containerOf(
            tester.element(find.byType(ComposeScreen)),
          ).read(putAwayGuardsProvider);
          unawaited(closeForPutAway(
            tester.state<NavigatorState>(find.byType(Navigator)),
            guards,
          ).then((all) {
            if (last == putAways) closed = all;
          }));
          await tester.pump(const Duration(milliseconds: 100));
        }

        /// Put away, and back while [engine] still holds the saves.
        Future<void> putAwayAndComeBack(WidgetTester tester) async {
          await putAwayWhileHeld(tester);
          comeBack(tester);
        }

        /// The saves [engine] holds let go, and everything waiting on them
        /// done.
        Future<void> letGo(WidgetTester tester, _HeldSaves engine) async {
          engine.letGo();
          for (var i = 0; i < 20 && closed == null; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.pumpAndSettle(const Duration(milliseconds: 50));
        }

        /// Put away, back while [engine] holds the saves, and the saves
        /// then let go. Whether the closing got all the way down.
        Future<bool> putAwayAndBack(
          WidgetTester tester,
          _HeldSaves engine, {
          String? typedMeanwhile,
        }) async {
          await putAwayAndComeBack(tester);
          if (typedMeanwhile != null) {
            await tester.enterText(subjectField(), typedMeanwhile);
          }
          await letGo(tester, engine);
          return closed!;
        }

        testWidgets('it stays open, with what was typed since',
            (tester) async {
          // Held from the first: the copy saved as the app went out of
          // sight.
          final engine = _HeldSaves(holdFrom: 1);
          await open(tester, _draft(accountId: 'acct-personal'),
              engine: engine);

          expect(
            await putAwayAndBack(tester, engine,
                typedMeanwhile: 'Half written, and more'),
            isFalse,
          );

          expect(find.byType(ComposeScreen), findsOneWidget);
          expect(subject(tester), 'Half written, and more');
        });

        testWidgets('a later save replaces the copy it made, not a second',
            (tester) async {
          // Held from the second: the save of putting it away.
          final engine = _HeldSaves(holdFrom: 2);
          Future<List<String>> drafts() async =>
              (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                  .map((m) => m.subject)
                  .toList();
          final before = await drafts();
          await open(tester, _draft(accountId: 'acct-personal'),
              engine: engine);

          expect(await putAwayAndBack(tester, engine), isFalse);
          await tester.enterText(subjectField(), 'Finished');
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save draft'));
          await tester.pumpAndSettle();

          expect(find.byType(ComposeScreen), findsNothing);
          expect(await drafts(), unorderedEquals([...before, 'Finished']));
        });

        testWidgets('a reopened draft saved again after is still one draft',
            (tester) async {
          // The save on the way out gave the draft a new name, and a later
          // save went on replacing the old one, which was gone already.
          final engine = _HeldSaves(holdFrom: 2);
          Future<List<String>> drafts() async =>
              (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                  .map((m) => m.subject)
                  .toList();
          final saved =
              (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                  .first;
          final others = (await drafts())..remove(saved.subject);
          await open(
            tester,
            _draft(accountId: 'acct-personal', savedAs: saved.id),
            engine: engine,
          );

          expect(await putAwayAndBack(tester, engine), isFalse);
          expect(engine.saves, 2, reason: 'saved on the way out, and back');
          await tester.enterText(subjectField(), 'Finished');
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save draft'));
          await tester.pumpAndSettle();

          expect(await drafts(), unorderedEquals([...others, 'Finished']));
        });

        testWidgets('thrown away after, it leaves nothing in Drafts',
            (tester) async {
          // What putting it away saved was a copy against the app being
          // ended, as the background one is, not a draft the person kept.
          // Discard still means discard.
          final engine = _HeldSaves(holdFrom: 2);
          Future<List<String>> drafts() async =>
              (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                  .map((m) => m.subject)
                  .toList();
          final before = await drafts();
          await open(tester, _draft(accountId: 'acct-personal'),
              engine: engine);

          expect(await putAwayAndBack(tester, engine), isFalse);
          expect(engine.saves, 2, reason: 'saved on the way out, and back');
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Discard'));
          await tester.pumpAndSettle(const Duration(milliseconds: 50));

          expect(find.byType(ComposeScreen), findsNothing);
          expect(await drafts(), unorderedEquals(before));
        });

        testWidgets('away again, what was typed while back is what is saved',
            (tester) async {
          // Back for a moment, a few words, and away again. The second
          // save, with the words, was done before the first, which then
          // put what it had read over them, and closed the screen.
          final engine = _HeldSaves(holdFrom: 2, holdTo: 2);
          Future<List<String>> drafts() async =>
              (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                  .map((m) => m.subject)
                  .toList();
          final before = await drafts();
          await open(tester, _draft(accountId: 'acct-personal'),
              engine: engine);

          await putAwayAndComeBack(tester);
          await tester.enterText(subjectField(), 'Typed while back');
          await putAwayWhileHeld(tester);
          await letGo(tester, engine);
          comeBack(tester);
          await tester.pumpAndSettle(const Duration(milliseconds: 50));

          expect(closed, isTrue);
          expect(find.byType(ComposeScreen), findsNothing);
          expect(
              await drafts(), unorderedEquals([...before, 'Typed while back']));
        });

        testWidgets('back to stay, it goes on keeping a background copy',
            (tester) async {
          // The save on the way out took the background copy's place and
          // marked the window ended, so a screen the person had come back
          // to never saved another: typed on, the screen turned off, and an
          // Android that ended the app meanwhile lost all of it.
          final engine = _HeldSaves(holdFrom: 2, holdTo: 2);
          final saved =
              (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                  .first;
          await open(
            tester,
            _draft(accountId: 'acct-personal', savedAs: saved.id),
            engine: engine,
          );

          expect(await putAwayAndBack(tester, engine), isFalse);
          expect(engine.saves, 2, reason: 'saved on the way out, and back');
          await tester.enterText(subjectField(), 'Typed after');
          leave(tester);
          await tester.pump(const Duration(milliseconds: 100));

          expect(engine.saves, 3, reason: 'a background copy, as before');
        });

        testWidgets('Send waits for a put-away still waiting on its copy',
            (tester) async {
          // Back before the copy saved as the app went out of sight had
          // landed, and Send: the put-away, waiting on that copy, went on
          // once it had, and saved a copy of the message just sent, or
          // closed a screen showing that its send had failed.
          final engine = _HeldSaves(holdFrom: 1, holdTo: 1);
          Future<List<String>> subjectsIn(String folderId) async =>
              (await tester.runAsync(() => engine.loadMessages(folderId)))!
                  .map((m) => m.subject)
                  .toList();
          const sentId = 'acct-personal:[Gmail]/Sent Mail';
          final before = await subjectsIn(draftsId);
          await open(tester, _draft(accountId: 'acct-personal'),
              engine: engine);

          await putAwayAndComeBack(tester);
          await tester.tap(find.byTooltip('Send'));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(await subjectsIn(sentId), isNot(contains('Half written')),
              reason: 'held until the put-away has finished');

          await letGo(tester, engine);

          expect(closed, isFalse, reason: 'the put-away left it to Send');
          expect(find.byType(ComposeScreen), findsNothing);
          expect(await subjectsIn(sentId), contains('Half written'));
          expect(await subjectsIn(draftsId), unorderedEquals(before));
        });

        group('and done with before it has finished', () {
          // The screen is there to use while the save goes on, and what it
          // saved is only known once it has. Left meanwhile, its copy was
          // in Drafts with nothing to remove it or save over it.
          testWidgets('thrown away, it leaves nothing in Drafts',
              (tester) async {
            final engine = _HeldSaves(holdFrom: 2);
            Future<List<String>> drafts() async =>
                (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                    .map((m) => m.subject)
                    .toList();
            final before = await drafts();
            await open(tester, _draft(accountId: 'acct-personal'),
                engine: engine);

            await putAwayAndComeBack(tester);
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.text('Discard'));
            await tester.pump();
            await letGo(tester, engine);

            expect(find.byType(ComposeScreen), findsNothing);
            expect(await drafts(), unorderedEquals(before));
          });

          testWidgets('saved, it is one draft', (tester) async {
            // Saving is done before the save on the way out, whose copy
            // then came after the screen had dropped the copy it knew of.
            final engine = _HeldSaves(holdFrom: 2, holdTo: 2);
            Future<List<String>> drafts() async =>
                (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                    .map((m) => m.subject)
                    .toList();
            final before = await drafts();
            await open(tester, _draft(accountId: 'acct-personal'),
                engine: engine);

            await putAwayAndComeBack(tester);
            await tester.enterText(subjectField(), 'Finished');
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.text('Save draft'));
            await tester.pump();
            await letGo(tester, engine);

            expect(find.byType(ComposeScreen), findsNothing);
            expect(await drafts(), unorderedEquals([...before, 'Finished']));
          });

          testWidgets('a reopened draft saved is still one draft',
              (tester) async {
            final engine = _HeldSaves(holdFrom: 2);
            Future<List<String>> drafts() async =>
                (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                    .map((m) => m.subject)
                    .toList();
            final saved =
                (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                    .first;
            final others = (await drafts())..remove(saved.subject);
            await open(
              tester,
              _draft(accountId: 'acct-personal', savedAs: saved.id),
              engine: engine,
            );

            await putAwayAndComeBack(tester);
            await tester.enterText(subjectField(), 'Finished');
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.text('Save draft'));
            await tester.pump();
            await letGo(tester, engine);

            expect(find.byType(ComposeScreen), findsNothing);
            expect(await drafts(), unorderedEquals([...others, 'Finished']));
          });

          testWidgets('a reopened draft sent leaves nothing in Drafts',
              (tester) async {
            final engine = _HeldSaves(holdFrom: 2);
            Future<List<String>> drafts() async =>
                (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                    .map((m) => m.subject)
                    .toList();
            final saved =
                (await tester.runAsync(() => engine.loadMessages(draftsId)))!
                    .first;
            final others = (await drafts())..remove(saved.subject);
            await open(
              tester,
              _draft(accountId: 'acct-personal', savedAs: saved.id),
              engine: engine,
            );

            await putAwayAndComeBack(tester);
            await tester.tap(find.byTooltip('Send'));
            await tester.pump();
            await letGo(tester, engine);

            expect(find.byType(ComposeScreen), findsNothing);
            expect(await drafts(), unorderedEquals(others));
          });
        });
      });

      testWidgets('one that cannot be saved stays open', (tester) async {
        // Closing it then would lose it, which is the thing to avoid.
        await open(tester, _draft(accountId: 'acct-personal'),
            engine: _NoDrafts());

        expect(await putAway(tester), isFalse);

        expect(find.byType(ComposeScreen), findsOneWidget);
      });
    });

    testWidgets('a draft whose body cannot be read is not opened',
        (tester) async {
      // It used to open with its one-line preview standing in for the
      // body, and saving that replaced the whole draft in Drafts.
      final saved = MailMessage(
        id: 'acct-personal:[Gmail]/Drafts#99',
        accountId: 'acct-personal',
        folderId: 'acct-personal:[Gmail]/Drafts',
        uid: 99,
        subject: 'Long draft',
        from: const MailAddress(email: 'me@example.com'),
        to: const [MailAddress(email: 'dana@example.com')],
        date: DateTime(2026, 9, 20),
        preview: 'Only the first line',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailEngineProvider.overrideWithValue(_OfflineBodies()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ElevatedButton(
                  onPressed: () => openSavedDraft(context, ref, saved),
                  child: const Text('open draft'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open draft'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'the spinner comes down on a failure too');
      expect(find.textContaining('could not be opened'), findsOneWidget);
    });

    testWidgets(
        'a spinner put away with Back cancels the reply, and closes nothing '
        'else', (tester) async {
      // Offline, the reply's original takes a while. Back took the spinner
      // down, and when the wait ended the spinner's own pop closed the
      // message being read instead, with compose opening over the list.
      final body = Completer<MailBody>();
      final original = MailMessage(
        id: 'acct-personal:INBOX#1',
        accountId: 'acct-personal',
        folderId: 'acct-personal:INBOX',
        uid: 1,
        subject: 'Numbers',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'personal@example.com')],
        date: DateTime(2026, 9, 20),
        preview: 'The figures',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailEngineProvider.overrideWithValue(_SlowBodies(body.future)),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: Consumer(
                        builder: (context, ref, _) => ElevatedButton(
                          onPressed: () => openCompose(
                            context,
                            ref,
                            kind: ComposeKind.reply,
                            original: original,
                          ),
                          child: const Text('reply'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('read'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('read'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('reply'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      body.complete(const MailBody(text: 'The figures'));
      await tester.pumpAndSettle();

      expect(find.text('reply'), findsOneWidget,
          reason: 'the message being read is still open');
      expect(find.byType(ComposeScreen), findsNothing,
          reason: 'Back said not to wait for it');
    });

    testWidgets('a Bcc that is not an address stops the send',
        (tester) async {
      // To and Cc were checked and Bcc was not, so a mistyped blind copy went
      // to the server, which could refuse it while taking the rest.
      await open(
        tester,
        const Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.newMessage,
          to: [MailAddress(email: 'you@example.com')],
          bcc: [MailAddress(email: 'bob.example.com')],
          subject: 'Hi',
          htmlBody: '<p>Hi</p>',
        ),
      );

      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(find.text('One of the addresses does not look right.'),
          findsOneWidget);
      expect(find.byType(ComposeScreen), findsOneWidget);
    });

    testWidgets(
        'Back while it is being sent offers nothing, and a failure is still '
        'shown', (tester) async {
      // Back asked whether to keep a message "not sent", and Discard closed
      // the window while the send went on. When that send then failed,
      // nothing said so, and the message was gone.
      final engine = _SlowSend();
      await open(tester, _draft(accountId: 'acct-personal'), engine: engine);

      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pageBack();
      // Not settled: the Send button spins while it sends.
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Keep this message?'), findsNothing);
      expect(find.byType(ComposeScreen), findsOneWidget);

      engine.sending.completeError(
          const ConnectionFailed('Could not reach smtp.gmail.com.'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.byType(ProblemView), findsOneWidget);
    });

    testWidgets('a send that fails after the window has gone fails quietly',
        (tester) async {
      // Saying so threw, on a screen that was no longer there.
      final engine = _SlowSend();
      await open(tester, _draft(accountId: 'acct-personal'), engine: engine);
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpWidget(const SizedBox());
      engine.sending.completeError(
          const ConnectionFailed('Could not reach smtp.gmail.com.'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}

/// A send that ends when the test says, and how.
class _SlowSend extends SampleMailEngine {
  final sending = Completer<void>();

  @override
  Future<void> sendDraft(Draft draft) => sending.future;
}

/// Has the folders and lists, and no connection for a body.
class _OfflineBodies extends SampleMailEngine {
  @override
  Future<MailBody> loadMessageBody(String messageId) async =>
      throw const ConnectionFailed('Could not reach the server.');
}

/// Has the folders and lists, and a body that arrives when the test says.
class _SlowBodies extends SampleMailEngine {
  _SlowBodies(this.body);

  final Future<MailBody> body;

  @override
  Future<MailBody> loadMessageBody(String messageId) => body;
}

/// Accepts every message and sends nothing.
class _SilentSender extends SmtpSender {
  const _SilentSender({
    required super.host,
    required super.user,
    required super.credentials,
  });

  @override
  Future<void> send(em.MimeMessage message) async {}
}

/// Drafts cannot be saved: offline, say.
class _NoDrafts extends SampleMailEngine {
  @override
  Future<String?> saveDraft(Draft draft) async =>
      throw const SocketException('offline');
}

/// Saves as the real engine makes them, one command after another: the
/// copy goes up, and then the newest message in Drafts is read back as
/// where it went. The next upload waits until the test lets it through, as
/// one on a slow connection does; the ones after it do not.
class _SlowSave extends SampleMailEngine {
  Completer<void>? hold;

  /// The last command asked for, which the next one waits behind.
  Future<void> _tail = Future.value();

  Future<T> _inTurn<T>(Future<T> Function() command) {
    final done = _tail.then((_) => command());
    _tail = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    final held = hold;
    hold = null;
    final landed = await _inTurn(() async {
      await held?.future;
      return super.saveDraft(draft);
    });
    final folderId = landed!.substring(0, landed.lastIndexOf('#'));
    return _inTurn(() async {
      final copies = await loadMessages(folderId, limit: 1000);
      return copies.reduce((a, b) => a.uid > b.uid ? a : b).id;
    });
  }
}

/// Saves drafts once the test lets them go, the way a slow connection
/// does: from the [holdFrom]th save on, counting from one.
class _HeldSaves extends SampleMailEngine {
  _HeldSaves({required this.holdFrom, this.holdTo});

  final int holdFrom;

  /// The last save held; null holds every one from [holdFrom] on. A save
  /// asked for later then goes straight through, and can be done first.
  final int? holdTo;

  final _gate = Completer<void>();

  /// How many saves have been asked for.
  var saves = 0;

  void letGo() => _gate.complete();

  @override
  Future<String?> saveDraft(Draft draft) async {
    final n = ++saves;
    if (n >= holdFrom && n <= (holdTo ?? n)) await _gate.future;
    return super.saveDraft(draft);
  }
}
