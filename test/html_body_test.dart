import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:myemail/data/ai/date_finder.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/found_dates.dart' show DateGrain;
import 'package:myemail/state/date_providers.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';
import 'package:myemail/ui/messages/date_format.dart' show formatDay;
import 'package:myemail/domain/html_safety.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/html_body_view.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'fakes/fake_webview.dart';

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

    test('scaled down to a narrow view, never up to a wide one', () {
      // On a tablet's pane a 600-pixel signature table scaled the whole
      // message up to twice its size.
      expect(wrapHtmlForDisplay(kohlsLike, viewWidth: 390),
          contains('content="width=640"'));
      final wide = wrapHtmlForDisplay(kohlsLike, viewWidth: 1300);
      expect(wide, contains('width=device-width'));
      expect(wide, isNot(contains('content="width=640"')));
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

    // Taken out in one pass, the tag inside joined the halves around it into
    // a working one: a refresh to the sender's page a few seconds after the
    // message opened, or a viewport of the message's own. Read here as the
    // WebView reads it, by a parser.
    test('a meta or base rebuilt from the halves around one taken out is '
        'gone too', () {
      for (final html in [
        '<me<meta>ta http-equiv="refresh" '
            'content="5;url=https://phish.example/login"><p>Hi</p>',
        '<html><body><ME<META>TA HTTP-EQUIV=refresh '
            'CONTENT="0;url=https://t/"><p>Hi</p></body></html>',
        '<<meta>meta http-equiv="refresh" content="0;url=https://t/"><p>Hi</p>',
        '<me<me<meta>ta>ta http-equiv="refresh" '
            'content="0;url=https://t/"><p>Hi</p>',
        '<me<meta>ta name="viewport" content="width=200"><p>Hi</p>',
        '<ba<base>se href="https://evil.example/"><p>Hi</p>',
      ]) {
        final page = html_parser.parse(wrapHtmlForDisplay(html));
        expect(
          page.querySelectorAll('meta').where((m) =>
              m.attributes['http-equiv']?.toLowerCase() == 'refresh'),
          isEmpty,
          reason: html,
        );
        expect(page.querySelectorAll('meta[name="viewport"]'), hasLength(1),
            reason: 'the app\'s own, alone: $html');
        expect(page.querySelectorAll('base'), isEmpty, reason: html);
        expect(page.querySelector('p')?.text, 'Hi', reason: html);
      }
    });

    // Two ways past the pattern that the WebView still read as a tag. One
    // left open at the very end was closed by the `>` of the `</body>` the
    // page puts after it. And a style in the head ends where the WebView
    // ends it, at `</style/>` or `</style x>` as well, so what came after
    // was a tag in the page, carried there as a sheet's text.
    test('a meta or base left open at the end, or after a style the WebView '
        'has ended, is gone too', () {
      const refresh =
          '<meta http-equiv="refresh" content="0;url=https://phish.example/"';
      for (final html in [
        '<p>Hi</p>$refresh',
        '<p>Hi</p>$refresh ',
        '<html><body><p>Hi</p>$refresh</body></html>',
        '<html><body><p>Hi</p>$refresh',
        '<p>Hi</p><base href="https://evil.example/"',
        '<html><head><style>p{}</style/>$refresh></style></head>'
            '<body><p>Hi</p></body></html>',
        '<html><head><style>p{}</style x>$refresh></style></head>'
            '<body><p>Hi</p></body></html>',
        '<html><head><STYLE>p{}</STYLE\t>$refresh></style></head>'
            '<body><p>Hi</p></body></html>',
        '<html><head><style>p{}</style/><base href="https://evil.example/">'
            '</style></head><body><p>Hi</p></body></html>',
        '<html><head><style>p{}</style/>$refresh</style></head>'
            '<body><p>Hi</p></body></html>',
      ]) {
        final page = html_parser.parse(wrapHtmlForDisplay(html));
        expect(
          page.querySelectorAll('meta').where((m) =>
              m.attributes['http-equiv']?.toLowerCase() == 'refresh'),
          isEmpty,
          reason: html,
        );
        expect(page.querySelectorAll('meta[name="viewport"]'), hasLength(1),
            reason: 'the app\'s own, alone: $html');
        expect(page.querySelectorAll('base'), isEmpty, reason: html);
        expect(page.querySelector('p')?.text, 'Hi', reason: html);
      }
    });

    test('a sheet from the head ends where the WebView ends it', () {
      final page = html_parser.parse(wrapHtmlForDisplay(
        '<html><head><style>p{color:red}</style/><p>Not a sheet</p></style>'
        '</head><body><p>Hi</p></body></html>',
      ));
      expect(page.head!.querySelectorAll('style').last.text, 'p{color:red}');
      expect(page.body!.text, 'Hi');
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

  // Handed to Android, a mailto: link in a message went to another mail
  // app; with this one the default, tapped in a message's own window, it
  // would start a second copy of the whole app inside the window.
  group('a mailto: link tapped in a message', () {
    final message = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'Numbers for Thursday',
      preview: '',
      from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
      to: const [MailAddress(email: 'personal@example.com')],
      date: DateTime(2026, 10, 12, 9, 30),
      isRead: true,
    );

    Future<FakeWebViewPlatform> pump(WidgetTester tester) async {
      final web = FakeWebViewPlatform.install();
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        messageBodyProvider(message.id).overrideWith((ref) async =>
            const MailBody(
              text: 'Write to the site office.',
              html: '<p>Write to <a href="mailto:office@example.com">the '
                  'site office</a>.</p>',
            )),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: ReadingPane(message: message, onPopOut: () {})),
        ),
      ));
      await tester.pumpAndSettle();
      return web;
    }

    testWidgets('is a new message here, from the account the message came '
        'to, to whoever the link names', (tester) async {
      final web = await pump(tester);

      await tester.tap(find.byType(WebViewWidget));
      final decision = await web.navigationHandler!(const NavigationRequest(
        url: 'mailto:office@example.com?cc=sam@example.com,Office@Example.com'
            '&subject=Site%20visit&body=Thursday%20at%202%3F',
        isMainFrame: true,
      ));
      // Past the moment a new message waits before it would show a spinner.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(decision, NavigationDecision.prevent);
      final draft =
          tester.widget<ComposeScreen>(find.byType(ComposeScreen)).draft;
      expect(draft.accountId, 'acct-personal');
      expect(draft.to.map((a) => a.email), ['office@example.com']);
      expect(draft.cc.map((a) => a.email), ['sam@example.com'],
          reason: 'the address in To once, not again in Cc');
      expect(draft.subject, 'Site visit');
      expect(draft.htmlBody, contains('Thursday at 2?'));
    });

    testWidgets('that nobody tapped for opens nothing', (tester) async {
      final web = await pump(tester);

      await web.navigationHandler!(const NavigationRequest(
        url: 'mailto:office@example.com',
        isMainFrame: true,
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsNothing);
    });
  });

  group('dark mode', () {
    test('a message that sets no colours follows the app into dark', () {
      final out = wrapHtmlForDisplay(
        '<p>Just some words.</p>',
        brightness: Brightness.dark,
      );
      expect(out, contains('background:#111318'));
      expect(out, contains('color-scheme:dark'));
    });

    test('a message that styles itself goes dark with the app too', () {
      // It used to stay on a white sheet in the middle of a dark app.
      const styled = '<html><body bgcolor="#ffffff">'
          '<div style="color:#000">Black on their own white</div>'
          '</body></html>';
      final out = wrapHtmlForDisplay(styled, brightness: Brightness.dark);
      expect(out, contains('color-scheme:dark'));
      expect(out, contains('<body style="background:#111318">'));
      expect(out, contains('style="color:#e1e2e9"'));
    });

    test('the light theme is never darkened, whatever the message says', () {
      expect(
        wrapHtmlForDisplay('<p>Plain</p>', brightness: Brightness.light),
        contains('background:#fff'),
      );
      expect(
        wrapHtmlForDisplay('<p style="color:#000;background:#fff">x</p>'),
        contains('<p style="color:#000;background:#fff">'),
      );
    });

    test("a message's own dark design follows the app, not Android", () {
      const html = '<html><head><style>'
          '@media (prefers-color-scheme: dark){p{color:#eee}}'
          '</style></head><body><p>x</p></body></html>';
      expect(wrapHtmlForDisplay(html, brightness: Brightness.dark),
          contains('@media (color)'));
      expect(wrapHtmlForDisplay(html), contains('@media (monochrome)'));
    });

    test("the dark page is the app's own surface and text", () {
      final scheme = buildTheme(Brightness.dark).colorScheme;
      expect(darkPageColour, scheme.surface);
      expect(darkTextColour, scheme.onSurface);
    });
  });

  // Calendar ideas #23: a day and time in a message is underlined, and a
  // tap on it is a meeting then.
  group('a date in a message', () {
    final message = MailMessage(
      id: 'acct-personal:INBOX#2',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 2,
      subject: 'Site visit',
      preview: '',
      from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
      to: const [MailAddress(email: 'personal@example.com')],
      date: DateTime.now(),
      isRead: true,
    );
    final soon = DateTime.now().add(const Duration(days: 3));
    final when = DateTime(soon.year, soon.month, soon.day, 15);

    testWidgets('is underlined, and a tap on it opens a meeting then',
        (tester) async {
      final web = FakeWebViewPlatform.install();
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        messageBodyProvider(message.id).overrideWith((ref) async =>
            const MailBody(
              text: 'Shall we meet Friday at 3pm by the gate?',
              html: '<p>Shall we meet Friday at 3pm by the gate?</p>',
            )),
        dateFinderProvider.overrideWithValue(FakeDateFinder({
          'Friday at 3pm': (at: when, grain: DateGrain.hour),
        })),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: ReadingPane(message: message, onPopOut: () {})),
        ),
      ));
      await tester.pumpAndSettle();
      expect(web.loadedHtml.last, contains('myemail-date:'));

      final link = RegExp(r'href="(myemail-date:[^"]+)"')
          .firstMatch(web.loadedHtml.last)![1]!;
      await tester.tap(find.byType(WebViewWidget));
      final decision = await web.navigationHandler!(NavigationRequest(
        url: link,
        isMainFrame: true,
      ));
      await tester.pumpAndSettle();
      expect(decision, NavigationDecision.prevent);
      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.text('Site visit'), findsWidgets, reason: 'its subject');
      expect(find.text(formatDay(when)), findsNWidgets(2));
    });

    testWidgets('is left alone where Settings, Calendar says not to look',
        (tester) async {
      final web = FakeWebViewPlatform.install();
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ui = MemoryUiStateStore();
      await ui.writeString(UiStateKeys.calendarPrefs, '{"datesInMail": false}');
      final finder = FakeDateFinder({
        'Friday at 3pm': (at: when, grain: DateGrain.hour),
      });
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        messageBodyProvider(message.id).overrideWith((ref) async =>
            const MailBody(
              text: 'Shall we meet Friday at 3pm?',
              html: '<p>Shall we meet Friday at 3pm?</p>',
            )),
        dateFinderProvider.overrideWithValue(finder),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: ReadingPane(message: message, onPopOut: () {})),
        ),
      ));
      await tester.pumpAndSettle();
      expect(web.loadedHtml.last, isNot(contains('myemail-date:')));
      expect(finder.asked, isEmpty, reason: 'not even read');
    });
  });
}
