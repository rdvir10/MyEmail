import 'dart:async';
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
import 'package:myemail/data/compose/quote_builder.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
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
      await open(
        tester,
        Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.newMessage,
          subject: 'Had a file',
          htmlBody: '<p>Words</p>',
          savedAs: 'acct-personal:Drafts#3',
          lostAttachmentNames: const ['report.pdf'],
        ),
      );

      expect(find.textContaining('had an attachment'), findsOneWidget);
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
  });
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
