import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/signature.dart';

import 'fakes/fake_imap_transport.dart';

/// Answering mail from the notification shade.
///
/// The point of these buttons is that nothing has to be opened: the reply is
/// typed into the notification and goes from there, and a delete is a delete.
/// So the work happens with no app, no widgets and no providers, and what it
/// produces has to be the same message the compose screen would have sent.
void main() {
  late FakeImapTransport server;
  late MemoryAccountStore accounts;
  late MemoryCacheStore cache;
  late CachedImapEngine engine;
  late _RecordingSender sender;

  setUp(() {
    server = FakeImapTransport();
    accounts = MemoryAccountStore();
    cache = MemoryCacheStore();
    sender = _RecordingSender();
    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: MemoryCredentialStore(),
      cache: cache,
      transportFactory: (_, _) => server,
      // Without this the send path opens a real socket with a made-up
      // password. A unit test must not touch the network.
      senderFactory: (_, _) => sender,
    );
  });

  Future<(Account, MailMessage)> arrival({
    String from = 'dana@example.com',
    List<String> alsoTo = const [],
  }) async {
    server
      ..folder('INBOX', role: FolderRole.inbox)
      ..folder('[Gmail]/Sent Mail', role: FolderRole.sent)
      ..folder('[Gmail]/Drafts', role: FolderRole.drafts)
      ..folder('[Gmail]/Trash', role: FolderRole.deleted);
    server.folder('INBOX').deliver(
          subject: 'Thursday',
          from: from,
          body: 'Can you make ten?',
        );
    final account = await engine.addAccount(
      displayName: 'Ron',
      emailAddress: 'me@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    );
    final inbox = await engine.loadMessages('${account.id}:INBOX');
    var message = inbox.single;
    if (alsoTo.isNotEmpty) {
      // The fake addresses everything to the account; a reply-all needs
      // somebody else on it.
      message = MailMessage(
        id: message.id,
        accountId: message.accountId,
        folderId: message.folderId,
        uid: message.uid,
        subject: message.subject,
        preview: message.preview,
        from: message.from,
        to: [
          ...message.to,
          for (final e in alsoTo) MailAddress(email: e),
        ],
        date: message.date,
        isRead: message.isRead,
      );
      await cache.upsertMessages(account.id, 'INBOX', [
        CachedMessage(
          uid: message.uid,
          subject: message.subject,
          from: message.from,
          to: message.to,
          date: message.date,
          isRead: message.isRead,
          isFlagged: message.isFlagged,
          hasAttachments: message.hasAttachments,
        ),
      ]);
    }
    return (account, message);
  }

  NotificationActions actionsFor(Account account, {Signature? signature}) =>
      NotificationActions(
        engine: engine,
        accounts: [account],
        signatures: {?signature?.accountId: ?signature},
      );

  group('replying', () {
    test('sends what was typed, quoting what it answers', () async {
      final (account, message) = await arrival();

      final outcome = await actionsFor(account).perform(
        NotificationActions.replyId,
        message.id,
        'Ten works.',
      );

      expect(outcome, ActionOutcome.sent);
      expect(sender.sent, hasLength(1));
      final sent = sender.sent.single;
      expect(sent, contains('Ten works.'));
      expect(sent, contains('Re: Thursday'));
      expect(sent, contains('dana@example.com'));
      expect(sent, contains('Can you make ten?'),
          reason: 'the original is quoted, as it would be from the app');
    });

    test('marks the message read, because answered mail is read', () async {
      final (account, message) = await arrival();
      expect(message.isRead, isFalse);

      await actionsFor(account)
          .perform(NotificationActions.replyId, message.id, 'Yes');

      expect((await engine.cachedMessage(message.id))!.isRead, isTrue);
    });

    test('reply-all keeps the others and leaves the account off', () async {
      final (account, message) =
          await arrival(alsoTo: ['barry@example.com']);

      await actionsFor(account).perform(
        NotificationActions.replyAllId,
        message.id,
        'Ten works.',
      );

      final sent = sender.sent.single;
      expect(sent, contains('barry@example.com'));
      expect(RegExp('me@example.com').allMatches(sent).length, lessThan(2),
          reason: 'the sender is not also a recipient of their own reply');
    });

    test('a plain reply leaves the others off', () async {
      final (account, message) =
          await arrival(alsoTo: ['barry@example.com']);

      await actionsFor(account)
          .perform(NotificationActions.replyId, message.id, 'Ten works.');

      expect(sender.sent.single, isNot(contains('barry@example.com')));
    });

    test('the signature goes on where the account asks for one', () async {
      final (account, message) = await arrival();

      await actionsFor(
        account,
        signature: Signature(
          accountId: account.id,
          html: '<p>Ron Dvir, Hadco</p>',
          onReply: true,
        ),
      ).perform(NotificationActions.replyId, message.id, 'Ten works.');

      expect(sender.sent.single, contains('Ron Dvir, Hadco'));
    });

    test('and stays off where it does not', () async {
      final (account, message) = await arrival();

      await actionsFor(
        account,
        signature: Signature(
          accountId: account.id,
          html: '<p>Ron Dvir, Hadco</p>',
          onReply: false,
        ),
      ).perform(NotificationActions.replyId, message.id, 'Ten works.');

      expect(sender.sent.single, isNot(contains('Ron Dvir, Hadco')));
    });

    test('an empty box sends nothing at all', () async {
      final (account, message) = await arrival();

      final outcome = await actionsFor(account)
          .perform(NotificationActions.replyId, message.id, '   ');

      expect(outcome, ActionOutcome.nothingTyped);
      expect(sender.sent, isEmpty);
    });

    test('what cannot be sent is kept as a draft, never dropped', () async {
      // Typed into a notification and the network was not there. There is no
      // window left holding the words, so they go to Drafts.
      final (account, message) = await arrival();
      sender.refuse = true;

      final outcome = await actionsFor(account)
          .perform(NotificationActions.replyId, message.id, 'Ten works.');

      expect(outcome, ActionOutcome.savedAsDraft);
      expect(outcome.message, contains('Drafts'));
    });

    test('a message already gone says so rather than failing quietly',
        () async {
      final (account, _) = await arrival();

      final outcome = await actionsFor(account).perform(
        NotificationActions.replyId,
        '${account.id}:INBOX#9999',
        'Ten works.',
      );

      expect(outcome, ActionOutcome.gone);
      expect(sender.sent, isEmpty);
    });
  });

  group('deleting', () {
    test('puts the message in Trash', () async {
      final (account, message) = await arrival();

      final outcome = await actionsFor(account)
          .perform(NotificationActions.deleteId, message.id, null);

      expect(outcome, ActionOutcome.deleted);
      expect(server.folder('INBOX').messages, isEmpty);
      expect(server.folder('[Gmail]/Trash').messages, hasLength(1));
    });

    test('offline, the message stays and the press waits, quietly', () async {
      final (account, message) = await arrival();
      server.offline = true;

      final outcome = await actionsFor(account)
          .perform(NotificationActions.deleteId, message.id, null);

      expect(outcome, ActionOutcome.offline);
      expect(outcome.worthRetrying, isTrue);
      expect(server.folder('INBOX').messages, hasLength(1));
      expect(outcome.message, isNull, reason: 'it will be done later');
    });

    test('a failure leaves the message where it was and says so', () async {
      final (account, message) = await arrival();
      server.failWith = StateError('the server said no');

      final outcome = await actionsFor(account)
          .perform(NotificationActions.deleteId, message.id, null);

      expect(outcome, ActionOutcome.failed);
      expect(server.folder('INBOX').messages, hasLength(1));
      expect(outcome.message, isNotNull);
    });
  });

  group('what the shade says back', () {
    test('a reply that went and a delete that worked say nothing', () {
      // The notification going away is the confirmation. A row saying "Sent"
      // is one more thing to dismiss.
      expect(ActionOutcome.sent.message, isNull);
      expect(ActionOutcome.deleted.message, isNull);
      expect(ActionOutcome.nothingTyped.message, isNull);
    });

    test('only the cases worth doing something about speak up', () {
      expect(ActionOutcome.savedAsDraft.message, isNotNull);
      expect(ActionOutcome.gone.message, isNotNull);
      expect(ActionOutcome.failed.message, isNotNull);
    });
  });

  test('a button the app does not know is ignored', () async {
    final (account, message) = await arrival();

    expect(
      await actionsFor(account).perform('something.else', message.id, 'hi'),
      ActionOutcome.unknown,
    );
    expect(NotificationActions.isKnown('something.else'), isFalse);
    expect(NotificationActions.isKnown(NotificationActions.replyId), isTrue);
  });
}

/// Keeps what it was asked to send instead of opening a socket, and
/// refuses on request, so the "could not send" path can be walked.
class _RecordingSender extends SmtpSender {
  _RecordingSender()
      : super(
          host: 'smtp.example',
          user: '',
          credentials: const PasswordCredentials(''),
        );

  final List<String> sent = [];
  bool refuse = false;

  @override
  Future<void> send(em.MimeMessage message) async {
    if (refuse) throw const SendFailed('no network');
    sent.add(message.renderMessage());
  }
}
