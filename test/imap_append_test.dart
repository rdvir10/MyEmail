import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/enough_mail_transport.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/mail_credentials.dart';

/// Filing a message from another account into a Gmail folder: the APPEND
/// the app writes itself, asked of a small server on this machine through
/// the real transport.
void main() {
  group('the APPEND line', () {
    test('carries the folder, the flags and when it arrived', () {
      expect(
        appendCommand(
          'Receipts',
          flags: [r'\Seen', r'\Flagged'],
          arrived: DateTime.utc(2026, 3, 4, 5, 6, 7),
          length: 120,
        ),
        r'APPEND "Receipts" (\Seen \Flagged) "04-Mar-2026 05:06:07 +0000" {120}',
      );
    });

    test('with no flags and no date, neither is there', () {
      expect(
        appendCommand('Work/2026', flags: const [], length: 9),
        'APPEND "Work/2026" {9}',
      );
    });

    test('the time is put in UTC', () {
      final local = DateTime.utc(2026, 12, 31, 23, 30).toLocal();
      expect(imapDateTime(local), '31-Dec-2026 23:30:00 +0000');
    });
  });

  group('over the wire', () {
    late _AppendServer server;

    setUp(() async => server = await _AppendServer.start());
    tearDown(() => server.close());

    EnoughMailTransport transport() {
      final t = EnoughMailTransport(
        host: '127.0.0.1',
        port: server.port,
        user: 'ron@example.com',
        credentials: const PasswordCredentials('app-password'),
        useTls: false,
        commandLimit: const Duration(seconds: 5),
        transferLimit: const Duration(seconds: 5),
      );
      addTearDown(t.close);
      return t;
    }

    test('the message goes byte for byte, 8-bit Hebrew and all', () async {
      // windows-1255 "shalom", as Thunderbird sends it: bytes above 0x7F
      // that are not UTF-8. Written as UTF-8 each would arrive as two.
      final bytes = Uint8List.fromList([
        ...ascii.encode('Subject: hi\r\n'
            'Content-Type: text/plain; charset=windows-1255\r\n'
            'Content-Transfer-Encoding: 8bit\r\n\r\n'),
        0xF9, 0xEC, 0xE5, 0xED, 0x0D, 0x0A,
      ]);
      final raw = String.fromCharCodes(bytes);

      final uid = await transport().fileMessage(
        'Receipts',
        raw,
        seen: true,
        flagged: true,
        arrived: DateTime.utc(2026, 3, 4, 5, 6, 7),
      );

      expect(server.appends.single,
          'APPEND "Receipts" (\\Seen \\Flagged) '
          '"04-Mar-2026 05:06:07 +0000" {${bytes.length}}');
      expect(server.literals.single, bytes);
      expect(uid, 42, reason: "the UID the server's APPENDUID gave it");
    });

    test('a server that gives no UID gives none', () async {
      server.appendUid = false;

      const raw = 'Subject: hi\r\n\r\nHello';
      final uid = await transport().fileMessage('Receipts', raw, seen: false);

      expect(server.appends.single, 'APPEND "Receipts" {${raw.length}}');
      expect(uid, isNull);
    });
  });
}

/// Just enough IMAP to log in, list two folders and take an APPEND, read
/// as bytes so a literal can be checked to the byte.
class _AppendServer {
  _AppendServer._(this._socket);

  final ServerSocket _socket;
  final _clients = <Socket>[];

  /// Every APPEND line, as sent, without its literal.
  final appends = <String>[];

  /// Every APPEND's literal, as the bytes that came.
  final literals = <Uint8List>[];

  /// Whether an APPEND is answered with APPENDUID, as Gmail's is.
  bool appendUid = true;

  int get port => _socket.port;

  static Future<_AppendServer> start() async {
    final server = _AppendServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._socket.listen(server._serve);
    return server;
  }

  void _serve(Socket client) {
    _clients.add(client);
    client.write('* OK [CAPABILITY IMAP4rev1 UIDPLUS] fake ready\r\n');
    final pending = BytesBuilder();
    String? appendTag;
    var literalLeft = 0;

    void line(String text) {
      final space = text.indexOf(' ');
      if (space < 0) return;
      final tag = text.substring(0, space);
      final command = text.substring(space + 1);
      final verb = command.toUpperCase();
      if (verb.startsWith('APPEND')) {
        appends.add(command);
        final size = RegExp(r'\{(\d+)\}$').firstMatch(command)!;
        literalLeft = int.parse(size.group(1)!);
        appendTag = tag;
        client.write('+ go ahead\r\n');
      } else if (verb.startsWith('LOGIN') || verb.startsWith('AUTHENTICATE')) {
        client.write('$tag OK [CAPABILITY IMAP4rev1 UIDPLUS] signed in\r\n');
      } else if (verb.startsWith('CAPABILITY')) {
        client.write('* CAPABILITY IMAP4rev1 UIDPLUS\r\n$tag OK done\r\n');
      } else if (verb.startsWith('LIST')) {
        client.write('* LIST (\\HasNoChildren) "/" INBOX\r\n'
            '* LIST (\\HasNoChildren) "/" Receipts\r\n'
            '$tag OK LIST done\r\n');
      } else if (verb.startsWith('LOGOUT')) {
        client.write('* BYE\r\n$tag OK bye\r\n');
        client.destroy();
      } else {
        client.write('$tag OK\r\n');
      }
    }

    client.listen((chunk) {
      pending.add(chunk);
      var buffer = pending.takeBytes();
      while (true) {
        if (literalLeft > 0) {
          if (buffer.length < literalLeft) break;
          literals.add(Uint8List.fromList(buffer.sublist(0, literalLeft)));
          buffer = buffer.sublist(literalLeft);
          literalLeft = 0;
          continue;
        }
        final end = _indexOfCrlf(buffer);
        if (end < 0) break;
        final text = latin1.decode(buffer.sublist(0, end));
        buffer = buffer.sublist(end + 2);
        final tag = appendTag;
        if (tag != null) {
          // The line end after the literal closes the APPEND.
          appendTag = null;
          client.write(appendUid
              ? '$tag OK [APPENDUID 1 42] APPEND done\r\n'
              : '$tag OK APPEND done\r\n');
          continue;
        }
        line(text);
      }
      pending.add(buffer);
    }, onError: (_) {}, cancelOnError: true);
  }

  static int _indexOfCrlf(List<int> bytes) {
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10) return i;
    }
    return -1;
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _socket.close();
  }
}
