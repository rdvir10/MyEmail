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
import 'package:myemail/ui/compose/compose_screen.dart';

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

    test('an account with no Drafts folder reports that rather than throwing',
        () async {
      server.folders.remove('[Gmail]/Drafts');
      final account = await addAccount();

      expect(await engine.saveDraft(_draft(accountId: account.id)), isNull);
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
    Future<void> open(WidgetTester tester, Draft draft) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailEngineProvider.overrideWithValue(SampleMailEngine()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) => ComposeScreen(draft: draft),
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
  });
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
