import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/compose_providers.dart';
import 'package:myemail/state/providers.dart';

/// Resend This Message: a message from Sent opened as a new one, to the
/// same people, with its text and files.
void main() {
  final sent = MailMessage(
    id: 'acct-personal:[Gmail]/Sent Mail#4',
    accountId: 'acct-personal',
    folderId: 'acct-personal:[Gmail]/Sent Mail',
    uid: 4,
    subject: 'Quote for the deck',
    from: const MailAddress(email: 'personal@example.com'),
    to: const [MailAddress(email: 'dana@example.com', name: 'Dana')],
    cc: const [MailAddress(email: 'sam@example.com')],
    date: DateTime(2026, 10, 20),
    preview: 'Attached is the quote.',
    hasAttachments: true,
  );

  testWidgets('to the same people, Bcc included, with its files, importance '
      'and receipt request, and nothing marked or replaced', (tester) async {
    late Draft draft;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mailEngineProvider.overrideWithValue(_Stored())],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async =>
                  draft = await draftForResend(ref: ref, message: sent),
              child: const Text('resend'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('resend'));
    await tester.pumpAndSettle();

    expect(draft.kind, ComposeKind.newMessage);
    expect(draft.subject, 'Quote for the deck');
    expect(draft.to.single.email, 'dana@example.com');
    expect(draft.cc.single.email, 'sam@example.com');
    expect(draft.bcc.single.email, 'boss@example.com');
    expect(draft.attachments.single.fileName, 'quote.pdf');
    expect(draft.importance, Importance.high);
    expect(draft.requestReadReceipt, isTrue);
    expect(draft.savedAs, isNull, reason: 'the copy in Sent stays');
    expect(draft.originalMessageId, isNull);
    expect(draft.htmlBody, contains('Attached is the quote.'));
  });
}

/// The sample engine, holding the sent message as the server would.
class _Stored extends SampleMailEngine {
  static const _account = Account(
    id: 'acct-personal',
    displayName: 'Personal',
    emailAddress: 'personal@example.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0xFF0F6CBD,
  );

  @override
  Future<MailBody> loadMessageBody(String messageId) async => const MailBody(
        text: 'Attached is the quote.',
        html: '<p>Attached is the quote.</p>',
      );

  @override
  Future<String> rawMessage(String messageId) async => buildMimeMessage(
        draft: Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.newMessage,
          to: const [MailAddress(email: 'dana@example.com', name: 'Dana')],
          cc: const [MailAddress(email: 'sam@example.com')],
          bcc: const [MailAddress(email: 'boss@example.com')],
          subject: 'Quote for the deck',
          htmlBody: '<p>Attached is the quote.</p>',
          importance: Importance.high,
          requestReadReceipt: true,
          attachments: [
            DraftAttachment(
              fileName: 'quote.pdf',
              mimeType: 'application/pdf',
              bytes: Uint8List.fromList(List.filled(32, 7)),
            ),
          ],
        ),
        account: _account,
      ).renderMessage();
}
