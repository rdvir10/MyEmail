import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/compose_providers.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';

/// What compose asks of the app before and after the screen: the draft it
/// opens with, and what a send or a save leaves behind.
void main() {
  /// A WidgetRef over [c], which is what these functions are written against.
  Future<WidgetRef> refOver(WidgetTester tester, ProviderContainer c) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: Consumer(builder: (_, ref, _) {
          captured = ref;
          return const SizedBox();
        }),
      ),
    );
    return captured;
  }

  ProviderContainer over(SampleMailEngine engine) {
    final c = ProviderContainer(
      overrides: [mailEngineProvider.overrideWithValue(engine)],
    );
    addTearDown(c.dispose);
    return c;
  }

  const draft = Draft(
    accountId: 'acct-personal',
    kind: ComposeKind.newMessage,
    to: [MailAddress(email: 'dana@example.com')],
    subject: 'Numbers',
    htmlBody: '<p>The figures for Thursday.</p>',
  );

  testWidgets('a reopened draft reaches the editor with no script in it',
      (tester) async {
    // A Drafts folder holds whatever other clients, server rules and shared
    // mailboxes put there, and the editor runs JavaScript with a bridge
    // that can send.
    final c = over(_Engine()
      ..body = const MailBody(
        text: 'Hi',
        html: '<p>Hi</p><img src="x" onerror="MyEmail.postMessage(1)">'
            '<script>MyEmail.postMessage(2)</script>',
      ));
    final ref = await refOver(tester, c);

    final opened = (await tester.runAsync(() => draftFromMessage(
          ref: ref,
          message: _message(
            id: 'acct-personal:[Gmail]/Drafts#7',
            to: const [MailAddress(email: 'dana@example.com')],
          ),
        )))!;

    expect(opened.htmlBody, contains('Hi'));
    expect(opened.htmlBody.toLowerCase(), isNot(contains('onerror')));
    expect(opened.htmlBody.toLowerCase(), isNot(contains('script')));
  });

  testWidgets('Reply all leaves your other accounts off the copy',
      (tester) async {
    // The message reached two of your accounts. Answered from one, the
    // other was copied in, so the reply came back to your own inbox and
    // showed everyone on the thread your other address.
    final c = over(_Engine());
    final ref = await refOver(tester, c);
    await tester.runAsync(() => c.read(accountsProvider.future));

    final reply = (await tester.runAsync(() => buildDraft(
          ref: ref,
          kind: ComposeKind.replyAll,
          accountId: 'acct-personal',
          original: _message(
            id: 'acct-personal:INBOX#1',
            to: const [
              MailAddress(email: 'personal@example.com'),
              MailAddress(email: 'Projects@example.com'),
            ],
            cc: const [MailAddress(email: 'noa@example.com')],
          ),
        )))!;

    expect(reply.to.map((a) => a.email), ['dana@example.com']);
    expect(reply.cc.map((a) => a.email), ['noa@example.com']);
  });

  group('once the server has it', () {
    testWidgets('a folder refresh that fails does not fail the send',
        (tester) async {
      // The message had gone. Reported as a failed send, Send came back on,
      // and a second tap sent it twice.
      final engine = _Engine();
      final c = over(engine);
      final ref = await refOver(tester, c);
      await tester.runAsync(() => c.read(foldersProvider.future));
      engine.foldersFail = true;

      await tester.runAsync(() => sendDraft(ref, draft));

      expect(engine.sent, hasLength(1));
    });

    testWidgets('what it answered shows so at once, in every list',
        (tester) async {
      // The engine marks the original in the cache as well as on the
      // server. The lists showing it read it again: its own folder's, and
      // the unified Inbox, which holds the same message in a list of its own.
      final c = over(SampleMailEngine());
      final ref = await refOver(tester, c);
      await tester.runAsync(() => c.read(foldersProvider.future));
      const inboxId = 'acct-personal:INBOX';
      Future<List<MailMessage>> list(String id) async =>
          (await tester.runAsync(() => c.read(messagesProvider(id).future)))!;
      final original = (await list(inboxId)).firstWhere((m) => !m.isAnswered);
      await list(kUnifiedInboxId);

      await tester.runAsync(() => sendDraft(
            ref,
            Draft(
              accountId: 'acct-personal',
              kind: ComposeKind.reply,
              to: [original.from],
              subject: 'Re: ${original.subject}',
              htmlBody: '<p>Yes.</p>',
              originalMessageId: original.id,
            ),
          ));

      for (final id in [inboxId, kUnifiedInboxId]) {
        final shown = (await list(id)).firstWhere((m) => m.id == original.id);
        expect(shown.isAnswered, isTrue, reason: id);
      }
    });

    testWidgets('nor the save, which says where the copy went',
        (tester) async {
      // Without where it went, the next save left a second copy in Drafts.
      final engine = _Engine();
      final c = over(engine);
      final ref = await refOver(tester, c);
      await tester.runAsync(() => c.read(foldersProvider.future));
      engine.foldersFail = true;

      final saved = (await tester.runAsync(() => saveDraft(ref, draft)))!;

      expect(saved.savedAs, isNotNull);
    });
  });
}

MailMessage _message({
  required String id,
  List<MailAddress> to = const [],
  List<MailAddress> cc = const [],
}) =>
    MailMessage(
      id: id,
      accountId: 'acct-personal',
      folderId: id.substring(0, id.lastIndexOf('#')),
      uid: int.parse(id.substring(id.lastIndexOf('#') + 1)),
      subject: 'Numbers',
      from: const MailAddress(email: 'dana@example.com', name: 'Dana'),
      to: to,
      cc: cc,
      date: DateTime(2026, 9, 20),
      preview: 'The figures',
    );

/// The sample engine with a body of the test's choosing, a record of what
/// it sent, and a folder listing that can be made to fail.
class _Engine extends SampleMailEngine {
  MailBody body = const MailBody(text: 'The figures');
  bool foldersFail = false;
  final sent = <Draft>[];

  @override
  Future<MailBody> loadMessageBody(String messageId) async => body;

  @override
  Future<String> rawMessage(String messageId) async =>
      throw StateError('not kept');

  @override
  Future<void> sendDraft(Draft draft) async => sent.add(draft);

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    if (foldersFail) throw StateError('the listing broke');
    return super.loadFolders(accountId);
  }
}
