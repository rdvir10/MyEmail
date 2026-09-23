import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/imap/enough_mail_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/mail_message.dart';

/// What happens to Gmail when the network goes away in the middle of
/// something. The real IMAP client never fails a command whose connection
/// drops and never gives up on one that is not answered, so one bad moment
/// used to stop an account's sync for good. These run the real transport
/// against a small IMAP server on this machine.
void main() {
  group('IMAP', () {
    late _FakeImapServer server;

    setUp(() async => server = await _FakeImapServer.start());
    tearDown(() => server.close());

    EnoughMailTransport transport({
      Duration limit = const Duration(seconds: 2),
    }) =>
        EnoughMailTransport(
          host: '127.0.0.1',
          port: server.port,
          user: 'ron@example.com',
          credentials: const PasswordCredentials('app-password'),
          useTls: false,
          commandLimit: limit,
        );

    test('answers as a normal server when nothing goes wrong', () async {
      final t = transport();
      final folders = await t.listFolders();
      expect(folders.map((f) => f.path), ['INBOX']);
      await t.close();
    });

    test('a connection dropped mid-command fails it, and the next call '
        'reconnects', () async {
      // A limit far longer than the test waits: only noticing the loss
      // itself can end the command in time.
      final t = transport(limit: const Duration(minutes: 1));
      server.onList = _Reply.drop;

      await expectLater(t.listFolders(), throwsA(isA<ConnectionFailed>()))
          .timeout(const Duration(seconds: 10));

      server.onList = _Reply.answer;
      final folders =
          await t.listFolders().timeout(const Duration(seconds: 10));
      expect(folders.map((f) => f.path), ['INBOX']);
      expect(server.connections, 2);
      await t.close();
    });

    test('a server that stops answering is given up on at the limit, and '
        'the account keeps working', () async {
      final t = transport();
      server.onList = _Reply.silence;

      final watch = Stopwatch()..start();
      await expectLater(t.listFolders(), throwsA(isA<ConnectionFailed>()))
          .timeout(const Duration(seconds: 20));
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));

      server.onList = _Reply.answer;
      final folders =
          await t.listFolders().timeout(const Duration(seconds: 20));
      expect(folders.map((f) => f.path), ['INBOX']);
      await t.close();
    });
  });

  group('SMTP', () {
    test('a send that cannot connect says so, rather than hanging', () async {
      // A port with nothing listening: refused at once, which used to leave
      // the goodbye waiting forever on a socket that was never made.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final sender = SmtpSender(
        host: '127.0.0.1',
        port: port,
        user: 'ron@example.com',
        credentials: const PasswordCredentials('app-password'),
      );
      final message = buildMimeMessage(
        draft: const Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          to: [MailAddress(email: 'dana@example.com')],
          subject: 'Hi',
          htmlBody: '<p>Hi</p>',
        ),
        account: const Account(
          id: 'a',
          displayName: 'Ron',
          emailAddress: 'ron@example.com',
          provider: MailProvider.gmail,
          authMethod: AuthMethod.appPassword,
          colorValue: 0xFF0F6CBD,
        ),
      );

      await expectLater(
        sender.send(message),
        throwsA(isA<ConnectionFailed>()),
      ).timeout(const Duration(seconds: 15));
    });
  });
}

enum _Reply { answer, drop, silence }

/// Just enough IMAP for a sign-in and a folder list, with a choice of how
/// to answer the list.
class _FakeImapServer {
  _FakeImapServer._(this._socket);

  final ServerSocket _socket;
  final _clients = <Socket>[];
  int connections = 0;
  _Reply onList = _Reply.answer;

  int get port => _socket.port;

  static Future<_FakeImapServer> start() async {
    final server = _FakeImapServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._socket.listen(server._serve);
    return server;
  }

  void _serve(Socket client) {
    connections++;
    _clients.add(client);
    client.write('* OK [CAPABILITY IMAP4rev1 IDLE] fake ready\r\n');
    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final space = line.indexOf(' ');
      if (space < 0) return;
      final tag = line.substring(0, space);
      final command = line.substring(space + 1).toUpperCase();
      if (command.startsWith('LOGIN') || command.startsWith('AUTHENTICATE')) {
        client.write('$tag OK [CAPABILITY IMAP4rev1 IDLE] signed in\r\n');
      } else if (command.startsWith('CAPABILITY')) {
        client.write('* CAPABILITY IMAP4rev1 IDLE\r\n$tag OK done\r\n');
      } else if (command.startsWith('LIST')) {
        switch (onList) {
          case _Reply.answer:
            client.write('* LIST (\\HasNoChildren) "/" INBOX\r\n'
                '* STATUS INBOX (MESSAGES 3 UNSEEN 1)\r\n'
                '$tag OK LIST done\r\n');
          case _Reply.drop:
            client.destroy();
          case _Reply.silence:
            break;
        }
      } else if (command.startsWith('LOGOUT')) {
        client.write('* BYE\r\n$tag OK bye\r\n');
        client.destroy();
      } else {
        client.write('$tag OK\r\n');
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _socket.close();
  }
}
