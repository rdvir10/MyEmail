import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/draft.dart' show SendFailed;
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/read_marker.dart';
import 'package:myemail/state/unsubscribe.dart' show openedHeadersProvider;
import 'package:myemail/ui/messages/read_receipt_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_imap_transport.dart';
import 'fakes/fake_webview.dart';

/// Read receipts asked for of us: the bar that offers one, and the receipt
/// itself (RFC 8098), sent from the account the message came to.
void main() {
  group('the receipt', () {
    late FakeImapTransport server;
    late _Recording sender;
    late CachedImapEngine engine;

    setUp(() {
      server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
      sender = _Recording();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
        senderFactory: (_, _) => sender,
      );
    });

    test('is a report to whoever asked, naming the message, and the request '
        'is marked answered on the server', () async {
      final account = await engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      final uid = server.folder('INBOX').deliver(subject: 'Plans').uid;
      server.headers[uid] = {
        'disposition-notification-to': 'Dana <dana@example.com>',
        'message-id': '<m1@example.com>',
        'subject': 'Plans',
        'from': 'Dana <dana@example.com>',
      };
      final id = '${account.id}:INBOX#$uid';

      expect(engine.answersReadReceipts(account.id), isTrue);
      expect((await engine.openedHeaders(id)).receiptTo,
          'Dana <dana@example.com>');

      await engine.sendReadReceipt(id);

      final receipt = sender.sent.single;
      expect(receipt.to!.single.email, 'dana@example.com');
      expect(receipt.decodeSubject(), 'Read: Plans');
      final text = receipt.renderMessage();
      expect(text, contains('multipart/report'));
      expect(text, contains('Original-Message-ID: <m1@example.com>'));
      expect(text, contains('Final-Recipient: rfc822;me@example.com'));
      expect(server.calls, contains('UID STORE INBOX $uid +\$MDNSent'));
    });

    test('goes to the one address asked for, never to a list of them',
        () async {
      final account = await engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      final uid = server.folder('INBOX').deliver(subject: 'Plans').uid;
      server.headers[uid] = {
        'disposition-notification-to': 'dana@example.com, boss@hadco.example',
        'message-id': '<m1@example.com>',
        'subject': 'Plans',
        'from': 'Dana <dana@example.com>',
      };
      final id = '${account.id}:INBOX#$uid';

      await expectLater(engine.sendReadReceipt(id), throwsA(isA<SendFailed>()));
      expect(sender.sent, isEmpty);
      expect(server.calls, isNot(contains('UID STORE INBOX $uid +\$MDNSent')));
    });

    test('not on a Microsoft account, until Exchange is known not to send '
        'one itself', () {
      final outlook = CachedImapEngine(
        accountStore: MemoryAccountStore(const [
          Account(
            id: 'ms',
            displayName: 'Work',
            emailAddress: 'me@hadco.example',
            provider: MailProvider.outlook,
            authMethod: AuthMethod.oauth,
            colorValue: 0xFF0F6CBD,
          ),
        ]),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
      );
      expect(outlook.answersReadReceipts('ms'), isFalse);
    });
  });

  group('the bar', () {
    final message = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'Plans',
      from: const MailAddress(email: 'dana@example.com', name: 'Dana'),
      to: const [MailAddress(email: 'personal@example.com')],
      date: DateTime(2026, 10, 1),
      preview: '',
      messageId: 'm1@example.com',
    );

    Future<SampleMailEngine> pump(
      WidgetTester tester, {
      ReceiptAnswer answer = ReceiptAnswer.ask,
      String receiptTo = 'dana@example.com',
    }) async {
      final engine = SampleMailEngine()
        ..receiptRequests[message.id] = receiptTo;
      final store = MemoryUiStateStore()
        ..writeString(
          UiStateKeys.display,
          jsonEncode(DisplaySettings(receipts: answer).toJson()),
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailEngineProvider.overrideWithValue(engine),
            uiStateStoreProvider.overrideWithValue(store),
          ],
          child: MaterialApp(
            home: Scaffold(body: ReadReceiptBar(message: message)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return engine;
    }

    testWidgets('asks, and Send receipt sends one, once', (tester) async {
      final engine = await pump(tester);
      expect(find.text('Dana asked to be told you read this.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('send-receipt')));
      await tester.pumpAndSettle();
      expect(engine.receiptsSent, [message.id]);
      expect(find.text('Dana asked to be told you read this.'), findsNothing);
    });

    testWidgets("Don't send marks it answered and sends nothing",
        (tester) async {
      final engine = await pump(tester);
      await tester.tap(find.text("Don't send"));
      await tester.pumpAndSettle();
      expect(engine.receiptsSent, isEmpty);
      expect(engine.receiptsDeclined, [message.id]);
      expect(find.text('Dana asked to be told you read this.'), findsNothing);
    });

    testWidgets('set to always, it goes once the message is opened, unasked',
        (tester) async {
      final engine = await pump(tester, answer: ReceiptAnswer.always);
      expect(engine.receiptsSent, isEmpty, reason: 'not opened yet');

      ProviderScope.containerOf(tester.element(find.byType(ReadReceiptBar)))
          .read(readMarkerProvider)
          .opened(message.id);
      await tester.pumpAndSettle();
      expect(find.text('Dana asked to be told you read this.'), findsNothing);
      expect(engine.receiptsSent, [message.id]);
    });

    testWidgets('one asked for elsewhere says where, and never goes unasked',
        (tester) async {
      final engine = await pump(
        tester,
        answer: ReceiptAnswer.always,
        receiptTo: 'Boss <boss@hadco.example>',
      );
      expect(engine.receiptsSent, isEmpty);
      expect(
        find.text('Dana asked for a receipt to be sent to boss@hadco.example.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('send-receipt')));
      await tester.pumpAndSettle();
      expect(engine.receiptsSent, [message.id]);
    });

    testWidgets('one asked for to several addresses is not offered',
        (tester) async {
      for (final answer in [ReceiptAnswer.ask, ReceiptAnswer.always]) {
        final engine = await pump(
          tester,
          answer: answer,
          receiptTo: 'dana@example.com, boss@hadco.example',
        );
        expect(find.byKey(const ValueKey('send-receipt')), findsNothing);
        expect(engine.receiptsSent, isEmpty, reason: answer.name);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('set to never, nothing at all', (tester) async {
      final engine = await pump(tester, answer: ReceiptAnswer.never);
      expect(find.text('Dana asked to be told you read this.'), findsNothing);
      expect(engine.receiptsSent, isEmpty);
    });
  });

  group('on the tablet', _landing);
}

/// Set to always on the tablet, where a folder opens on a message by itself
/// and a delete lands on the next: neither is Ron opening it.
void _landing() {
  setUpAll(FakeWebViewPlatform.install);

  testWidgets('set to always, not for a message the app landed on, until it '
      'is opened', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = SampleMailEngine();
    final store = MemoryUiStateStore()
      ..writeString(
        UiStateKeys.display,
        jsonEncode(
          const DisplaySettings(receipts: ReceiptAnswer.always).toJson(),
        ),
      );
    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(engine),
        uiStateStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // The folder opened on its newest message, which turns out to ask.
    final landed = c.read(selectedMessageProvider)!;
    engine.receiptRequests[landed.id] = landed.from.email;
    c.invalidate(openedHeadersProvider(landed.id));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(engine.receiptsSent, isEmpty);

    await tester.tap(find.byKey(ValueKey('tile:${landed.id}')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(engine.receiptsSent, [landed.id]);
  });
}

class _Recording extends SmtpSender {
  _Recording()
      : super(
          host: 'smtp.example',
          user: '',
          credentials: const PasswordCredentials(''),
        );

  final sent = <em.MimeMessage>[];

  @override
  Future<void> send(em.MimeMessage message) async => sent.add(message);
}
