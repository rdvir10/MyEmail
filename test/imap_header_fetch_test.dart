import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/enough_mail_transport.dart';
import 'package:myemail/domain/mail_credentials.dart';

/// What a list row is read from over IMAP, asked of a small server on this
/// machine through the real transport.
void main() {
  late _HeaderServer server;

  setUp(() async => server = await _HeaderServer.start());
  tearDown(() => server.close());

  EnoughMailTransport transport() {
    final t = EnoughMailTransport(
      host: '127.0.0.1',
      port: server.port,
      user: 'ron@example.com',
      credentials: const PasswordCredentials('app-password'),
      useTls: false,
      commandLimit: const Duration(seconds: 5),
    );
    addTearDown(t.close);
    return t;
  }

  test('a header fetch asks when each message arrived, and keeps it',
      () async {
    // The Date header is the sender's word, and missing here. INTERNALDATE
    // is when the server took the message in: what a message with no
    // usable Date is dated by, and what the widget counts new mail by.
    final t = transport();

    final headers = await t.fetchHeadersBySequence('INBOX', 1, 1);

    expect(server.fetches.single, contains('INTERNALDATE'));
    final h = headers.single;
    expect(h.uid, 7);
    expect(h.arrived!.toUtc(), DateTime.utc(2019, 10, 25, 14, 35, 31));
    expect(h.date.toUtc(), DateTime.utc(2019, 10, 25, 14, 35, 31));
  });

  test('a reply and a forward made elsewhere come with the header', () async {
    // \Answered is IMAP's own flag, and $Forwarded the keyword every mail
    // app that marks a forward uses: another app, or this one on another
    // device.
    server.flags = r'\Seen \Answered $Forwarded';
    final t = transport();

    final h = (await t.fetchHeadersBySequence('INBOX', 1, 1)).single;

    expect(h.isAnswered, isTrue);
    expect(h.isForwarded, isTrue);
  });

  test('and with the flags a sync reads again', () async {
    // What a folder already cached is brought up to date with.
    server.flags = r'\Seen $Forwarded';
    final t = transport();

    final flags = (await t.fetchFlags('INBOX', 7, 7)).single;

    expect(flags.isAnswered, isFalse);
    expect(flags.isForwarded, isTrue);
  });

  test(r'a reply marks the original \Answered, a forward $Forwarded',
      () async {
    final t = transport();

    await t.markAnswered('INBOX', 7);
    await t.markAnswered('INBOX', 7, toAll: true);
    await t.markForwarded('INBOX', 7);

    expect(server.stores, [
      r'UID STORE 7 +FLAGS.SILENT (\Answered)',
      r'UID STORE 7 +FLAGS.SILENT (\Answered)',
      r'UID STORE 7 +FLAGS.SILENT ($Forwarded)',
    ]);
    expect(t.keepsBothMarks, isTrue);
  });
}

class _HeaderServer {
  _HeaderServer._(this._socket);

  final ServerSocket _socket;
  final _clients = <Socket>[];

  /// Every FETCH command, as sent.
  final fetches = <String>[];

  /// Every STORE command, as sent.
  final stores = <String>[];

  /// The message's FLAGS, as the server sends them.
  String flags = '';

  int get port => _socket.port;

  static Future<_HeaderServer> start() async {
    final server = _HeaderServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._socket.listen(server._serve);
    return server;
  }

  void _serve(Socket client) {
    _clients.add(client);
    client.write('* OK [CAPABILITY IMAP4rev1] fake ready\r\n');
    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final space = line.indexOf(' ');
      if (space < 0) return;
      final tag = line.substring(0, space);
      final command = line.substring(space + 1);
      final verb = command.toUpperCase();
      if (verb.startsWith('LOGIN') || verb.startsWith('AUTHENTICATE')) {
        client.write('$tag OK [CAPABILITY IMAP4rev1] signed in\r\n');
      } else if (verb.startsWith('CAPABILITY')) {
        client.write('* CAPABILITY IMAP4rev1\r\n$tag OK done\r\n');
      } else if (verb.startsWith('LIST')) {
        client.write('* LIST (\\HasNoChildren) "/" INBOX\r\n'
            '* STATUS INBOX (MESSAGES 1 UNSEEN 1)\r\n'
            '$tag OK LIST done\r\n');
      } else if (verb.startsWith('SELECT') || verb.startsWith('EXAMINE')) {
        client.write('* 1 EXISTS\r\n'
            '* OK [UIDVALIDITY 1] valid\r\n'
            '* OK [UIDNEXT 8] next\r\n'
            '$tag OK [READ-WRITE] selected\r\n');
      } else if (verb.startsWith('FETCH') || verb.startsWith('UID FETCH')) {
        fetches.add(command);
        client.write('* 1 FETCH (UID 7 FLAGS ($flags) '
            'INTERNALDATE "25-Oct-2019 16:35:31 +0200" '
            'ENVELOPE (NIL "Hello" (("Dana" NIL "dana" "example.com")) '
            'NIL NIL NIL NIL NIL NIL "<m-1@example.com>") '
            'BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL '
            '"7BIT" 5 1))\r\n'
            '$tag OK FETCH done\r\n');
      } else if (verb.startsWith('STORE') || verb.startsWith('UID STORE')) {
        stores.add(command);
        client.write('$tag OK STORE done\r\n');
      } else if (verb.startsWith('LOGOUT')) {
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
