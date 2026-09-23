import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/smtp_sender.dart';

/// The envelope: who the server is asked to deliver to, and what it says.
///
/// Driven through enough_mail's real client against a server on loopback,
/// because what went wrong was how the client read the replies.
void main() {
  late _FakeSmtpServer server;
  late em.SmtpClient client;

  setUp(() async {
    server = await _FakeSmtpServer.start();
    client = em.SmtpClient('test');
    await client.connectToServer('127.0.0.1', server.port, isSecure: false);
  });

  tearDown(() async {
    await client.disconnect();
    await server.close();
  });

  EnvelopeCommand envelope(List<String> recipients) => EnvelopeCommand(
        text: 'Subject: Hi\r\n\r\nHello',
        from: 'ron@example.com',
        recipients: recipients,
      );

  test('a refused recipient that is not last stops the send', () async {
    // A mistyped Bcc between two good addresses: the server's refusal used
    // to be read past, and the message went to the other two as "sent".
    server.refuse('bob@example');

    await expectLater(
      client
          .sendCommand(envelope(
              ['alice@example.com', 'bob@example', 'carol@example.com']))
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<RecipientsRefused>()
          .having((e) => e.refused.keys, 'refused', ['bob@example'])
          .having((e) => e.message, 'message', contains('bob@example'))),
    );
    expect(server.commands, isNot(contains('DATA')),
        reason: 'nobody gets a copy until the list is right');
  });

  test('every refused recipient is named', () async {
    server
      ..refuse('bob@example')
      ..refuse('carol@example');

    await expectLater(
      client
          .sendCommand(envelope(
              ['bob@example', 'alice@example.com', 'carol@example']))
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<RecipientsRefused>().having(
          (e) => e.refused.keys, 'refused', ['bob@example', 'carol@example'])),
    );
  });

  test('a refused sender is reported in the server\'s words', () async {
    // Gmail refuses MAIL FROM once the day's sending limit is reached. That
    // used to surface as the "MAIL first" of the RCPT after it.
    server.refuseSender = '550 5.4.5 Daily user sending limit exceeded.';

    await expectLater(
      client
          .sendCommand(envelope(['alice@example.com']))
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<em.SmtpException>().having(
          (e) => e.message, 'message', contains('sending limit'))),
    );
    expect(server.commands.where((c) => c.startsWith('RCPT')), isEmpty);
  });

  test('when everyone is taken, the message is handed over', () async {
    final response = await client
        .sendCommand(envelope(['alice@example.com', 'carol@example.com']))
        .timeout(const Duration(seconds: 10));

    expect(response.isOkStatus, isTrue);
    expect(server.commands, [
      'MAIL FROM:<ron@example.com>',
      'RCPT TO:<alice@example.com>',
      'RCPT TO:<carol@example.com>',
      'DATA',
    ]);
    expect(server.received, 'Subject: Hi\r\n\r\nHello');
  });
}

/// Just enough SMTP for one envelope, refusing the addresses it is told to.
class _FakeSmtpServer {
  _FakeSmtpServer._(this._socket) {
    _socket.listen(_serve);
  }

  static Future<_FakeSmtpServer> start() async => _FakeSmtpServer._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      );

  final ServerSocket _socket;
  final _refused = <String>{};
  final commands = <String>[];
  String? refuseSender;
  String? received;

  int get port => _socket.port;

  void refuse(String address) => _refused.add(address);

  void _serve(Socket client) {
    client.write('220 fake ready\r\n');
    List<String>? data;
    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (data != null) {
        if (line == '.') {
          received = data!.join('\r\n');
          data = null;
          client.write('250 2.0.0 OK queued\r\n');
        } else {
          data!.add(line);
        }
        return;
      }
      commands.add(line);
      if (line.startsWith('MAIL FROM')) {
        client.write('${refuseSender ?? '250 2.1.0 OK'}\r\n');
      } else if (line.startsWith('RCPT TO:<')) {
        final address = line.substring(9, line.length - 1);
        client.write(_refused.contains(address)
            ? '553 5.1.3 The recipient address <$address> is not valid\r\n'
            : '250 2.1.5 OK\r\n');
      } else if (line == 'DATA') {
        data = [];
        client.write('354 Go ahead\r\n');
      } else if (line == 'QUIT') {
        client.write('221 bye\r\n');
      } else {
        client.write('502 5.5.1 Unrecognized command\r\n');
      }
    });
  }

  Future<void> close() => _socket.close();
}
