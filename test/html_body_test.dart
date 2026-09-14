import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/ui/messages/html_body_view.dart';

void main() {
  group('htmlHasRemoteContent', () {
    test('spots remote images, stylesheets and CSS urls', () {
      expect(htmlHasRemoteContent('<img src="https://t.example/p.gif">'), isTrue);
      expect(htmlHasRemoteContent("<img src='http://x/y.png'>"), isTrue);
      expect(htmlHasRemoteContent('<img src="//cdn.example/a.png">'), isTrue);
      expect(
        htmlHasRemoteContent('<link rel=stylesheet href="https://x/s.css">'),
        isTrue,
      );
      expect(htmlHasRemoteContent('<div style="background:url(https://x/b.png)">'),
          isTrue);
    });

    test('ignores inline and relative content', () {
      expect(htmlHasRemoteContent('<p>Hello</p>'), isFalse);
      expect(htmlHasRemoteContent('<img src="data:image/png;base64,AAAA">'),
          isFalse);
      expect(htmlHasRemoteContent('<img src="cid:part1">'), isFalse);
    });
  });

  group('wrapHtmlForDisplay', () {
    test('wraps a fragment in a document with viewport and defaults', () {
      final out = wrapHtmlForDisplay('<p>Hi</p>');
      expect(out, startsWith('<!doctype html>'));
      expect(out, contains('name="viewport"'));
      expect(out, contains('img{max-width:100%'));
      expect(out, contains('<body><p>Hi</p></body>'));
    });

    test('keeps only the body of a full document', () {
      const full = '<html><head><title>x</title><style>p{color:red}</style>'
          '</head><body class="m"><p>Body</p></body></html>';
      final out = wrapHtmlForDisplay(full);
      expect(out, contains('<body><p>Body</p></body>'));
      expect(out, isNot(contains('<title>')));
      expect('<html'.allMatches(out).length, 1, reason: 'no nested html');
    });

    test('an html tag without a body still renders its content', () {
      final out = wrapHtmlForDisplay('<html><head></head><p>Loose</p></html>');
      expect(out, contains('<p>Loose</p>'));
      expect('<html'.allMatches(out).length, 1);
    });
  });
}
