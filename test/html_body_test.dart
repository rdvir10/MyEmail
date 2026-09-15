import 'package:flutter/material.dart';
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

  group('dark mode', () {
    test('a message that sets no colours follows the app into dark', () {
      final out = wrapHtmlForDisplay(
        '<p>Just some words.</p>',
        brightness: Brightness.dark,
      );
      expect(out, contains('background:#1c1b1f'));
      expect(out, contains('color-scheme:dark'));
    });

    test('a message that styles itself keeps the light sheet it was written for',
        () {
      // Darkening underneath a sender who set their own black text makes it
      // invisible, and there is no way to know which declarations to keep.
      const styled = '<div style="color:#000">Black on their own white</div>';
      final out = wrapHtmlForDisplay(styled, brightness: Brightness.dark);
      expect(out, contains('background:#fff'));
      expect(out, isNot(contains('color-scheme:dark')));
    });

    test('the light theme is never darkened, whatever the message says', () {
      expect(
        wrapHtmlForDisplay('<p>Plain</p>', brightness: Brightness.light),
        contains('background:#fff'),
      );
    });

    test('every way a message declares a colour counts', () {
      for (final html in [
        '<td bgcolor="#ffffff">x</td>',
        '<p style="color:#111">x</p>',
        '<div style="background-color:#fff">x</div>',
        '<div style="background:#eee">x</div>',
        '<font color="red">x</font>',
        '<style>p{color:#333}</style><p>x</p>',
      ]) {
        expect(messageBringsItsOwnColours(html), isTrue, reason: html);
      }
    });

    test('a hyphenated property is not mistaken for a colour declaration', () {
      // `border-color` and `outline-color` are not the text colour, and
      // treating them as one would keep ordinary messages on a light sheet.
      expect(
        messageBringsItsOwnColours('<p style="border-color:red">x</p>'),
        isFalse,
      );
      expect(messageBringsItsOwnColours('<p>plain text</p>'), isFalse);
      expect(messageBringsItsOwnColours('<b>bold</b> and <i>italic</i>'), isFalse);
    });

    test('readsAsDark needs both a dark app and an unstyled message', () {
      expect(readsAsDark('<p>x</p>', Brightness.dark), isTrue);
      expect(readsAsDark('<p>x</p>', Brightness.light), isFalse);
      expect(
        readsAsDark('<p style="color:#000">x</p>', Brightness.dark),
        isFalse,
      );
    });
  });
}
