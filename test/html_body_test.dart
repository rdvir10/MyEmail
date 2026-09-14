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
      expect(htmlHasRemoteContent('<style>@import "https://x/f.css";</style>'),
          isTrue);
    });

    test('ignores inline and relative content', () {
      expect(htmlHasRemoteContent('<p>Hello</p>'), isFalse);
      expect(htmlHasRemoteContent('<img src="data:image/png;base64,AAAA">'),
          isFalse);
      expect(htmlHasRemoteContent('<img src="cid:part1">'), isFalse);
    });
  });

  group('stripRemoteContent', () {
    test('neutralises remote image sources but keeps the tag', () {
      final out = stripRemoteContent(
          '<img alt="a" src="https://t.example/p.gif" width=1>');
      expect(out, contains('data-blocked-src="https://t.example/p.gif"'));
      expect(out, isNot(contains(' src=')));
      expect(out, contains('alt="a"'));
    });

    test('handles srcset, poster, background and protocol-relative urls', () {
      final out = stripRemoteContent(
          '<img srcset="//c/a.png 1x" poster=http://v/p.jpg background="https://b/x">');
      expect(out, contains('data-blocked-srcset="//c/a.png 1x"'));
      expect(out, contains('data-blocked-poster=http://v/p.jpg'));
      expect(out, contains('data-blocked-background="https://b/x"'));
    });

    test('leaves inline, cid and relative sources alone', () {
      const html = '<img src="data:image/png;base64,AA"><img src="cid:x">'
          '<img src="/local.png">';
      expect(stripRemoteContent(html), html);
    });

    test('keeps anchors clickable', () {
      const html = '<a href="https://example.com/x">link</a>';
      expect(stripRemoteContent(html), html);
    });

    test('removes remote stylesheets, css urls and imports', () {
      const html = '<link rel="stylesheet" href="https://x/s.css">'
          '<div style="background:url(https://x/b.png)">t</div>'
          "<style>@import url('//x/f.css'); p{color:red}</style>";
      final out = stripRemoteContent(html);
      expect(out, isNot(contains('<link')));
      expect(out, contains('background:none'));
      expect(out, isNot(contains('@import')));
      expect(out, contains('p{color:red}'));
    });

    test('is idempotent and a no-op on clean html', () {
      const clean = '<p>Hi <b>there</b></p>';
      expect(stripRemoteContent(clean), clean);
      const dirty = '<img src="https://t/x.png">';
      final once = stripRemoteContent(dirty);
      expect(stripRemoteContent(once), once);
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
