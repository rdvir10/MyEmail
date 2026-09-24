import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/html_safety.dart';
import 'package:myemail/ui/messages/html_body_view.dart';

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

    test('a link is not something to show', () {
      // The bar came up on a plain note with a link in its signature, and
      // Show images changed nothing.
      expect(
        htmlHasRemoteContent('<p>Thanks</p><a href="https://example.com">Me</a>'),
        isFalse,
      );
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

  group('mail built to a fixed width', () {
    // Marketing mail — the Kohl's and Targets of the world — is tables of a
    // fixed pixel width with fixed columns inside them. Squeezed into a
    // phone the columns collapse into each other and it arrives looking
    // broken, so it is laid out at its own width and scaled to fit instead.
    const kohlsLike = '<table width="640" cellpadding="0"><tr>'
        '<td width="320"><img src="https://x/left.png" width="320"></td>'
        '<td width="320"><img src="https://x/right.png" width="320"></td>'
        '</tr></table>';

    test('the declared width is found', () {
      expect(declaredLayoutWidth(kohlsLike), 640);
    });

    test('a style in pixels counts too', () {
      expect(
        declaredLayoutWidth('<div style="width:600px">Hello</div>'),
        600,
      );
    });

    test('percentages are not a fixed width', () {
      // A table at 100% is already asking to fit.
      expect(declaredLayoutWidth('<table width="100%"><tr></tr></table>'),
          isNull);
    });

    test('ordinary mail states no width at all', () {
      expect(declaredLayoutWidth('<p>Can you send the invoice?</p>'), isNull);
    });

    test('a narrow width is left to the screen', () {
      // Forcing a viewport this narrow would blow the message up to fill the
      // phone, which is worse than the wrapping it was trying to avoid.
      expect(declaredLayoutWidth('<table width="320"></table>'), isNull);
    });

    test('a silly width is a stray number, not a layout', () {
      expect(declaredLayoutWidth('<img width="9000" src="x">'), isNull);
    });

    test('the viewport follows the message', () {
      final out = wrapHtmlForDisplay(kohlsLike);

      expect(out, contains('content="width=640"'));
      expect(out, isNot(contains('width=device-width')));
    });

    test('and the tables are not capped underneath it', () {
      // max-width on the tables is what collapses a fixed layout.
      expect(wrapHtmlForDisplay(kohlsLike), isNot(contains('table{max-width')));
      expect(
        wrapHtmlForDisplay('<p>Ordinary</p>'),
        contains('table{max-width:100%}'),
      );
    });

    test('a message in a full document is measured by its body', () {
      // Not by a stylesheet in the head written for a desktop browser.
      final out = wrapHtmlForDisplay(
        '<html><head><style>.wide{width:1200px}</style></head>'
        '<body><table width="600"></table></body></html>',
      );

      expect(out, contains('content="width=600"'));
    });
  });

  group('blocked images', () {
    test('keep a box so the layout stays standing', () {
      // An <img> with nothing to load collapses to nothing, and a message
      // built out of images turns into a heap of links.
      expect(
        wrapHtmlForDisplay('<p>Hi</p>'),
        contains('img[data-blocked-src]'),
      );
    });
  });

  group('pictures named by Content-ID', () {
    // A WebView has nothing to load for cid:, so each was a broken image.
    const pictures = {'image001.png@01da': 'data:image/png;base64,AAA'};

    test('are put in place however the link is written', () {
      for (final (html, out) in [
        (
          '<img src="cid:image001.png@01DA">',
          '<img src="data:image/png;base64,AAA">',
        ),
        (
          "<img SRC='CID:image001.png%4001DA'>",
          "<img SRC='data:image/png;base64,AAA'>",
        ),
        (
          '<img src=cid:image001.png@01DA width=10>',
          '<img src=data:image/png;base64,AAA width=10>',
        ),
        (
          '<td background="cid:image001.png@01DA">',
          '<td background="data:image/png;base64,AAA">',
        ),
        (
          '<div style="background:url(cid:image001.png@01DA)">',
          '<div style="background:url(data:image/png;base64,AAA)">',
        ),
      ]) {
        expect(withInlinePictures(html, pictures), out, reason: html);
      }
    });

    test('one not fetched keeps its link, and the placeholder box', () {
      const html = '<img src="cid:other@x">';
      expect(withInlinePictures(html, pictures), html);
      expect(wrapHtmlForDisplay(html), contains('img[src^="cid:" i]'));
    });

    test('text that only mentions one is left alone', () {
      const html = '<p>cid:image001.png@01DA</p>';
      expect(withInlinePictures(html, pictures), html);
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

    test('keeps the body of a full document and the styles in its head', () {
      // Only the inside of <body> was kept, so a message styled from its
      // head came out as bare text.
      const full = '<html><head><title>x</title><style>p{color:red}</style>'
          '<style media="screen">.m{margin:0}</style>'
          '</head><body class="m"><p>Body</p></body></html>';
      final out = wrapHtmlForDisplay(full);
      expect(out, contains('<body class="m"><p>Body</p></body>'));
      expect(out, isNot(contains('<title>')));
      expect('<html'.allMatches(out).length, 1, reason: 'no nested html');
      expect(out, contains('<style>p{color:red}</style>'));
      expect(out, contains('<style media="screen">.m{margin:0}</style>'));
      // After the defaults, so the sender's rules win.
      expect(
        out.indexOf('p{color:red}'),
        greaterThan(out.indexOf('blockquote{')),
      );
    });

    test("the body's own colours, style and direction come along", () {
      // Dropped with the tag: a right-to-left message came out left to
      // right, and a coloured one on white.
      const full = '<html><body bgcolor="#f0f0f0" text=#333 '
          "style='margin:0;font-family:\"Segoe UI\"' dir=\"rtl\" lang=\"he\">"
          '<p>x</p></body></html>';
      final out = wrapHtmlForDisplay(full);
      expect(
        out,
        contains('<body style="background:#f0f0f0;color:#333;'
            'margin:0;font-family:&quot;Segoe UI&quot;" dir="rtl" lang="he">'
            '<p>x</p></body>'),
      );
    });

    test("the body's attributes cannot break out of the tag", () {
      const full = "<html><body bgcolor='red\" onload=\"x' dir=\"rtl;x\">"
          '<p>x</p></body></html>';
      final out = wrapHtmlForDisplay(full);
      expect(out, contains('<body style="background:red onloadx" dir="rtlx">'));
    });

    test('an html tag without a body still renders its content', () {
      final out = wrapHtmlForDisplay('<html><head></head><p>Loose</p></html>');
      expect(out, contains('<p>Loose</p>'));
      expect('<html'.allMatches(out).length, 1);
    });

    // A refresh works with JavaScript off, wherever it sits, and opened the
    // sender's page the moment the message was opened.
    test('a meta refresh or base in the message is gone', () {
      for (final html in [
        '<meta http-equiv="refresh" content="0;url=https://t.example/">'
            '<p>Hi</p>',
        '<html><body><META HTTP-EQUIV=refresh CONTENT="0;url=https://t/">'
            '<p>Hi</p></body></html>',
        '<p>Hi</p><base href="https://evil.example/">',
      ]) {
        final out = wrapHtmlForDisplay(html);
        expect(out, isNot(contains('t.example')), reason: html);
        expect(out.toLowerCase(), isNot(contains('refresh')), reason: html);
        expect(out, isNot(contains('<base')), reason: html);
        expect(out, contains('<p>Hi</p>'), reason: html);
      }
    });

    String policyOf(String page) =>
        RegExp(r'Content-Security-Policy" content="([^"]*)"')
            .firstMatch(page)!
            .group(1)!;

    // The rewriting that hides pictures reads text, and a message can name a
    // remote resource in more ways than a pattern covers. With pictures
    // hidden the page itself may fetch nothing.
    test('with pictures hidden, the page may fetch nothing at all', () {
      final policy = policyOf(wrapHtmlForDisplay(
          '<svg><image href="https://t/p.gif"/></svg>'
          '<object data="https://t/x"></object>'));
      expect(policy, contains("default-src 'none'"));
      expect(policy, isNot(contains('*')));
      expect(policy, isNot(contains('http')));
    });

    test('with pictures shown, still no frames, plugins or form posts', () {
      // A login form posted in place, or a link aimed at an iframe, showed
      // the sender's page inside the pane under the app's header.
      final policy =
          policyOf(wrapHtmlForDisplay('<p>Hi</p>', remoteAllowed: true));
      expect(policy, contains('img-src *'));
      expect(policy, contains("frame-src 'none'"));
      expect(policy, contains("object-src 'none'"));
      expect(policy, contains("form-action 'none'"));
    });

    test('the policy comes before anything the message brings', () {
      final page = wrapHtmlForDisplay('<p>Hi</p>');
      expect(page.indexOf('Content-Security-Policy'),
          lessThan(page.indexOf('<p>Hi</p>')));
    });
  });

  group('paneNavigation', () {
    final now = DateTime(2026, 9, 23, 12);

    PaneNavigation decide(String url,
            {bool loading = false, DateTime? touchedAt}) =>
        paneNavigation(url, loading: loading, touchedAt: touchedAt, now: now);

    test('a link tapped just now opens outside the app', () {
      expect(
        decide('https://example.com/',
            touchedAt: now.subtract(const Duration(milliseconds: 300))),
        PaneNavigation.openOutside,
      );
    });

    test('a navigation nobody tapped for is dropped', () {
      expect(decide('https://t.example/'), PaneNavigation.drop);
      expect(
        decide('https://t.example/',
            touchedAt: now.subtract(const Duration(seconds: 30))),
        PaneNavigation.drop,
      );
    });

    test('a data: page only while the message itself is loading', () {
      expect(decide('data:text/html,x', loading: true), PaneNavigation.load);
      expect(
        decide('data:text/html,x', touchedAt: now),
        PaneNavigation.drop,
        reason: 'a tapped data: link must not replace the message',
      );
    });

    test('about:blank is always the WebView\'s own', () {
      expect(decide('about:blank'), PaneNavigation.load);
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
