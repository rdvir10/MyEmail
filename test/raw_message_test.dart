import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/compose/mime_parts.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/draft.dart';

/// A message as it arrived, kept byte for byte on its way to an `.eml`: a
/// forward as attachment, a copy, a drag into Files.
void main() {
  // Hebrew in 8-bit, the way Thunderbird sends it: bytes past 0x7F that are
  // UTF-8, with no transfer encoding over them. Encoded again as UTF-8,
  // each became two and the recipient saw mojibake.
  final wire = Uint8List.fromList([
    ...ascii.encode(
      'From: dana@example.com\r\n'
      'Subject: hi\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: multipart/mixed; boundary="b"\r\n'
      '\r\n'
      '--b\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Transfer-Encoding: 8bit\r\n'
      '\r\n',
    ),
    ...utf8.encode('שלום'),
    ...ascii.encode(
      '\r\n--b\r\n'
      'Content-Type: text/plain; charset=utf-8; name="note.txt"\r\n'
      'Content-Disposition: attachment; filename="note.txt"\r\n'
      'Content-Transfer-Encoding: 8bit\r\n'
      '\r\n',
    ),
    ...utf8.encode('תודה'),
    ...ascii.encode('\r\n--b--\r\n'),
  ]);

  test('what IMAP hands back goes back to the bytes it came as', () {
    // fetchRaw renders the fetched message, which enough_mail holds as
    // bytes and renders one character per byte.
    final raw = em.MimeMessage.parseFromData(wire).renderMessage();

    expect(rawMessageBytes(raw), wire);
    expect(utf8.encode(raw), isNot(wire), reason: 'what used to be done');
  });

  test("text of the app's own making is taken as UTF-8", () {
    expect(rawMessageBytes('שלום'), utf8.encode('שלום'));
  });

  test('a file inside it comes out with its own bytes', () {
    // How a forward and a reopened draft get their files back.
    final files = attachmentsInMime(latin1.decode(wire));

    expect(files.single.fileName, 'note.txt');
    // Not the line break before the boundary, which is the boundary's.
    expect(files.single.bytes, utf8.encode('תודה'));
  });

  // A forward, and a move into a Microsoft folder, carry the files this
  // way. What the sender wrote for the wire went on as it was written.
  group('a file the sender did not put in base64', () {
    /// The files found in a message with [parts] attached after its text,
    /// each a part's headers, a blank line and its body.
    List<DraftAttachment> filesIn(List<List<int>> parts) =>
        attachmentsInMime(latin1.decode([
          ...ascii.encode(
            'From: dana@example.com\r\n'
            'Subject: Files\r\n'
            'MIME-Version: 1.0\r\n'
            'Content-Type: multipart/mixed; boundary="b"\r\n'
            '\r\n'
            '--b\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n'
            '\r\n'
            'Attached.\r\n',
          ),
          for (final part in parts) ...[
            ...ascii.encode('--b\r\n'),
            ...part,
            // The line break before the boundary is the boundary's.
            ...ascii.encode('\r\n'),
          ],
          ...ascii.encode('--b--\r\n'),
        ]));

    /// A file called [name] as a part: its headers, naming [encoding] if
    /// there is one, and [body] as the wire has it.
    List<int> file(
      String name,
      List<int> body, {
      String type = 'text/plain',
      String? encoding,
    }) =>
        [
          ...ascii.encode(
            'Content-Type: $type; name="$name"\r\n'
            'Content-Disposition: attachment; filename="$name"\r\n',
          ),
          if (encoding != null)
            ...ascii.encode('Content-Transfer-Encoding: $encoding\r\n'),
          ...ascii.encode('\r\n'),
          ...body,
        ];

    test('quoted-printable comes out as the bytes it stands for', () {
      // Hebrew, an = sign, and a line too long for mail broken where the
      // sender's mail app broke it. It went on as =D7=93, =3D and all.
      final files = filesIn([
        file(
          'people.csv',
          ascii.encode(
            'name,note\r\n'
            '=D7=93=D7=A0=D7=94,"a=3Db"\r\n'
            'Caf=C3=A9,a line that=\r\n'
            ' goes on\r\n',
          ),
          type: 'text/csv; charset=utf-8',
          encoding: 'quoted-printable',
        ),
      ]);

      expect(files.single.fileName, 'people.csv');
      expect(
        files.single.bytes,
        utf8.encode('name,note\r\nדנה,"a=b"\r\nCafé,a line that goes on\r\n'),
      );
    });

    test('and where it ends on a soft line break, so does the file', () {
      // How Perl writes one with no line break at its end. The line break
      // the = joins on is the boundary's, and the = was left behind.
      final files = filesIn([
        file('total.txt', ascii.encode('Total: 12='),
            encoding: 'quoted-printable'),
      ]);

      expect(files.single.bytes, ascii.encode('Total: 12'));
    });

    test('an attached email keeps its lines, and is still an email', () {
      // Sent as it is, as RFC 2046 has an attached email sent, and with no
      // encoding named, as most senders write it. It went on as one run-on
      // line with no subject, and the Hebrew in it cut to a byte a letter.
      final older = [
        ...ascii.encode(
          'From: Avi Cohen <avi@example.com>\r\n'
          'Subject: Quote\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          'Content-Transfer-Encoding: 8bit\r\n'
          '\r\n',
        ),
        ...utf8.encode('שלום\r\nLine two\r\n'),
      ];
      final files = filesIn([
        [
          ...ascii.encode(
            'Content-Type: message/rfc822\r\n'
            'Content-Disposition: attachment\r\n'
            '\r\n',
          ),
          ...older,
        ],
      ]);

      // Named nothing by its sender, so called by its subject.
      expect(files.single.fileName, 'Quote.eml');
      expect(files.single.bytes, older);
      final email = em.MimeMessage.parseFromData(files.single.bytes);
      expect(email.decodeSubject(), 'Quote');
      expect(email.decodeTextPlainPart(), contains('שלום\r\nLine two'));
    });

    test('text sent as it is keeps its line breaks', () {
      // 7bit, said or, as RFC 2045 allows, left unsaid. Left unsaid, the
      // file went on as one line.
      final lines = ascii.encode('Cut\r\nDrill\r\n');
      final files = filesIn([
        file('said.txt', lines, encoding: '7bit'),
        file('unsaid.txt', lines),
      ]);

      expect(files.map((f) => f.fileName), ['said.txt', 'unsaid.txt']);
      expect(files.map((f) => f.bytes), [lines, lines]);
    });

    test('a message that is nothing but a file keeps its last line break',
        () {
      // No boundary ends it, so the line break is the file's own.
      final files = attachmentsInMime(
        'From: dana@example.com\r\n'
        'Subject: Steps\r\n'
        'MIME-Version: 1.0\r\n'
        'Content-Type: text/plain; name="steps.txt"\r\n'
        'Content-Disposition: attachment; filename="steps.txt"\r\n'
        'Content-Transfer-Encoding: 7bit\r\n'
        '\r\n'
        'Cut\r\nDrill\r\n',
      );

      expect(files.single.bytes, ascii.encode('Cut\r\nDrill\r\n'));
    });

    test('8-bit bytes that are not UTF-8 come through, and stop nothing',
        () {
      // A Latin-1 é. With no encoding named the file was read as UTF-8,
      // which threw, and the forward went without any of its files.
      final menu = [...ascii.encode('Caf'), 0xE9, ...ascii.encode('\r\n')];
      const latin = 'text/plain; charset=iso-8859-1';
      final files = filesIn([
        file('said.txt', menu, type: latin, encoding: '8bit'),
        file('unsaid.txt', menu, type: latin),
      ]);

      expect(files.map((f) => f.bytes), [menu, menu]);
    });

    test('and one in base64 comes out as it always did', () {
      final pdf = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final wrapped = base64Encode(pdf)
          .replaceAllMapped(RegExp('.{76}'), (m) => '${m[0]}\r\n');
      final files = filesIn([
        file('drawing.pdf', ascii.encode(wrapped),
            type: 'application/pdf', encoding: 'base64'),
      ]);

      expect(files.single.bytes, pdf);
    });
  });

  // Ron's forward of a customer's email (2026-11-23): an email attached to
  // it as "eml.eml", a stream of bytes, went on as just that. On the
  // forward it had a plain file's icon and opened in other mail apps.
  group('an email attached to the one forwarded', () {
    List<DraftAttachment> filesIn(String part) => attachmentsInMime(
          'From: stephanie@example.com\r\n'
          'Subject: 55026734 - Material cut incorrectly\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          'Please see the attached.\r\n'
          '--b\r\n'
          '$part\r\n'
          '--b--\r\n',
        );

    final inner = ascii.encode(
      'From: Precision Machine <shop@example.com>\r\n'
      'Subject: RE: Grain direction on 55026734\r\n'
      'Date: Mon, 23 Nov 2026 07:10:00 -0500\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: text/plain\r\n'
      '\r\n'
      'Cut across the grain.\r\n',
    );

    String base64Part(String headers, List<int> body) =>
        '$headers\r\nContent-Transfer-Encoding: base64\r\n\r\n'
        '${base64Encode(body)}';

    test('called eml.eml as a stream of bytes, it goes as an email, '
        'by its subject', () {
      final files = filesIn(base64Part(
        'Content-Type: application/octet-stream; name="eml.eml"\r\n'
        'Content-Disposition: attachment; filename="eml.eml"',
        inner,
      ));

      expect(files.single.fileName, 'RE_ Grain direction on 55026734.eml');
      expect(files.single.mimeType, 'message/rfc822');
      expect(files.single.openAs, 'message/rfc822');
      expect(files.single.bytes, inner);
    });

    test('a name that says which message it is stays', () {
      final files = filesIn(
        'Content-Type: message/rfc822\r\n'
        'Content-Disposition: attachment; filename="Shop note.eml"\r\n'
        '\r\n'
        '${ascii.decode(inner)}',
      );

      expect(files.single.fileName, 'Shop note.eml');
      expect(files.single.mimeType, 'message/rfc822');
    });

    test('a file called .eml that is no email keeps its name and type', () {
      final files = filesIn(base64Part(
        'Content-Type: application/octet-stream; name="eml.eml"\r\n'
        'Content-Disposition: attachment; filename="eml.eml"',
        [0, 1, 2, 3, 0xFF, 0xFE],
      ));

      expect(files.single.fileName, 'eml.eml');
      expect(files.single.mimeType, 'application/octet-stream');
    });
  });

  // RFC 2231 names, which enough_mail does not read: a forward called such
  // a file "attachment.pdf".
  group('a file named the RFC 2231 way keeps its name on a forward', () {
    List<DraftAttachment> filesIn(String headers) => attachmentsInMime(
          'From: dana@example.com\r\n'
          'Subject: Files\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: application/pdf\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '$headers\r\n'
          '\r\n'
          'JVBERi0xLjQ=\r\n'
          '--b--\r\n',
        );

    test('whole, in Hebrew', () {
      final files = filesIn(
        "Content-Disposition: attachment; filename*=utf-8''%D7%A9%D7%9C%D7%95%D7%9D.pdf",
      );
      expect(files.single.fileName, 'שלום.pdf');
    });

    test('cut into pieces, encoded and not', () {
      final files = filesIn(
        'Content-Disposition: attachment;\r\n'
        " filename*0*=UTF-8''Grain%20direction%20report;\r\n"
        ' filename*1=" for 55026734.pdf"',
      );
      expect(files.single.fileName, 'Grain direction report for 55026734.pdf');
    });

    test("Content-Type's name, in pieces and folded", () {
      expect(
        rfc2231Parameter(
          'application/pdf;\r\n name*0="Long ";\r\n name*1="name.pdf"',
          'name',
        ),
        'Long name.pdf',
      );
    });

    test('nothing named: as before, called by its type', () {
      final files = filesIn('Content-Disposition: attachment');
      expect(files.single.fileName, 'attachment.pdf');
    });

    test('a piece missing stops the name there', () {
      expect(
        rfc2231Parameter(
          "attachment; filename*0=\"Part one\"; filename*2=\" three.pdf\"",
          'filename',
        ),
        'Part one',
      );
    });
  });

  test("Microsoft's copy is kept byte for byte too", () async {
    // Decoded as UTF-8, every 8-bit byte that was not UTF-8 became U+FFFD.
    final sent = Uint8List.fromList([...wire, 0xE9]); // a stray Latin-1 é
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: http_testing.MockClient(
        (request) async => http.Response.bytes(sent, 200),
      ),
    );

    expect(rawMessageBytes(await api.mime('m1')), sent);
  });
}
