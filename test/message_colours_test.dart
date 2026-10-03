import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/message_colours.dart';

/// A message's own colours in the dark theme: turned by what they paint,
/// and nothing that is not a colour touched.
void main() {
  const page = 0x111318, text = 0xe1e2e9;
  String dark(String html) =>
      darkenMessageColours(html, page: page, text: text);

  /// The one colour in [html], as dark mode leaves it.
  String colourIn(String html) =>
      RegExp(r'#[0-9a-f]{6}').firstMatch(dark(html))![0]!;

  /// How bright a #rrggbb is to the eye, 0 for black to 1 for white.
  double luminance(String hex) {
    double channel(int at) {
      final c = int.parse(hex.substring(at, at + 2), radix: 16) / 255;
      return c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
  }

  int red(String hex) => int.parse(hex.substring(1, 3), radix: 16);
  int blue(String hex) => int.parse(hex.substring(5, 7), radix: 16);

  group('turned by what they paint', () {
    test('a white background is the page, black text is the text', () {
      expect(dark('<td bgcolor="#ffffff">'), '<td bgcolor="#111318">');
      expect(dark('<p style="color:#000000">'), '<p style="color:#e1e2e9">');
    });

    test('a light background darkens and keeps its hue', () {
      final turned = colourIn('<div style="background:#ddeeff">');
      expect(luminance(turned), lessThan(0.05));
      expect(blue(turned), greaterThan(red(turned)), reason: 'still blue');
    });

    test('a highlight stays a highlight', () {
      // Turned over like a white page, yellow landed on the page's own
      // darkness and disappeared.
      final turned = colourIn('<span style="background:yellow">');
      expect(luminance(turned), greaterThan(3 * luminance('#111318')));
      expect(luminance(turned), lessThan(0.2), reason: 'but dark');
      expect(red(turned), greaterThan(blue(turned) + 40), reason: 'yellow');
    });

    test('a blue banner stays blue, darker, and its white text is untouched',
        () {
      // The header row of the time-off table that started this.
      final out = dark('<td style="background:#1f9bde;color:#fff">');
      final banner = RegExp(r'background:(#[0-9a-f]{6})').firstMatch(out)![1]!;
      expect(luminance(banner), lessThan(luminance('#1f9bde')));
      expect(blue(banner), greaterThan(red(banner)));
      expect(out, contains('color:#fff'));
    });

    test('dark text is lifted until it reads on the page', () {
      for (final colour in ['#0000ff', '#333333', '#006400', 'navy']) {
        final turned = colourIn('<span style="color:$colour">');
        expect(luminance(turned), greaterThan(0.2), reason: colour);
      }
      expect(blue(colourIn('<a style="color:#0563c1">')),
          greaterThan(red(colourIn('<a style="color:#0563c1">'))),
          reason: 'a link stays blue');
    });

    test('what already suits a dark page is left as the sender chose', () {
      for (final html in [
        '<div style="background:#000000">',
        '<div style="background:#1f3a5f">',
        '<span style="color:#ffffff">',
        '<span style="color:#ffcc00">',
      ]) {
        expect(dark(html), html);
      }
    });

    test('lines turn over: a pale rule stays faint, a black one shows', () {
      final pale = colourIn('<td style="border:1px solid #cccccc">');
      expect(luminance(pale), lessThan(0.05));
      expect(luminance(pale), greaterThan(luminance('#111318')));
      final black = colourIn('<td style="border-bottom:2px solid black">');
      expect(luminance(black), greaterThan(0.5));
    });
  });

  group('every way a colour is written', () {
    test('as hex, a name, rgb() or hsl(), in any case', () {
      for (final white in [
        '#fff',
        '#FFFFFF',
        '#ffff',
        'white',
        'WHITE',
        'rgb(255,255,255)',
        'rgb(255 255 255)',
        'rgb(100%, 100%, 100%)',
        'hsl(0, 0%, 100%)',
        'hsl(0deg 0% 100%)',
        'window',
      ]) {
        expect(dark('<div style="background:$white">'),
            '<div style="background:#111318">',
            reason: white);
      }
    });

    test("Outlook's windowtext is black text", () {
      expect(dark('<span style="color:windowtext">'),
          '<span style="color:#e1e2e9">');
    });

    test('transparency is kept', () {
      expect(dark('<div style="background:rgba(255,255,255,.5)">'),
          '<div style="background:rgba(17,19,24,0.5)">');
      expect(dark('<div style="background:#ffffff80">'),
          '<div style="background:rgba(17,19,24,0.502)">');
    });

    test('in every place a message puts one', () {
      expect(dark('<font color=black>'), '<font color=#e1e2e9>');
      expect(dark("<body text='#000' link=\"#000\">"),
          "<body text='#e1e2e9' link=\"#e1e2e9\">");
      expect(
        dark('<style>td{background-color:#fff;color:#000}</style>'),
        '<style>td{background-color:#111318;color:#e1e2e9}</style>',
      );
      expect(dark("<p style='color:#000'>"), "<p style='color:#e1e2e9'>");
      expect(colourIn('<table bordercolor="#000000">'), isNot('#000000'));
    });
  });

  group('left as written', () {
    test('pictures, and the words in their addresses', () {
      expect(dark('<div style="background:url(white.png) #fff">'),
          '<div style="background:url(white.png) #111318">');
      for (final html in [
        '<div style="background:url(\'https://x.example/#fff.png\')">',
        '<div style="background-image:url(x.png)">',
        '<img src="data:image/png;base64,AAAA" alt="white">',
      ]) {
        expect(dark(html), html);
      }
    });

    test('what is not a colour, or not a colour property', () {
      for (final html in [
        '<p style="color:inherit">',
        '<p style="color:transparent">',
        '<p style="color:currentColor">',
        '<p style="color:var(--brand)">',
        '<p style="color:#12345">',
        '<table style="border-collapse:collapse">',
        // Outlook's own, which nothing but Outlook reads.
        '<td style="mso-border-alt:solid #000 .5pt">',
        '<style>.color:hover{x:1}</style>',
      ]) {
        expect(dark(html), html);
      }
    });

    test('the text of the message', () {
      const html = '<p>Colours: #fff, black, and color:#000.</p>';
      expect(dark(html), html);
    });
  });

  group('both ways, for the editor', () {
    String mark(String html, {required bool dark}) =>
        markDarkColours(html, page: page, text: text, dark: dark);

    test('light: the original in place, the dark one beside it', () {
      expect(mark('<p style="color:#000">', dark: false),
          '<p data-mt-colours data-mt-dark-style="color:#e1e2e9" '
          'style="color:#000">');
    });

    test('dark: the dark one in place, the original put aside', () {
      expect(mark('<td bgcolor=white>', dark: true),
          '<td data-mt-colours data-mt-dark-bgcolor="#111318" '
          'data-mt-light-bgcolor="white" bgcolor=#111318>');
    });

    test("a style sheet's text, escaped to sit in an attribute", () {
      expect(
        mark('<style>p{color:#000;font-family:"A&B"}</style>', dark: false),
        '<style data-mt-colours data-mt-dark-css='
        '"p{color:#e1e2e9;font-family:&quot;A&amp;B&quot;}">'
        'p{color:#000;font-family:"A&B"}</style>',
      );
    });

    test('a double quote inside single ones', () {
      expect(mark("<p style='color:#000;font-family:\"A\"'>", dark: false),
          contains('data-mt-dark-style="color:#e1e2e9;font-family:&quot;A&quot;"'));
    });

    test('nothing to turn, nothing marked', () {
      for (final html in [
        '<p style="color:#fff">',
        '<p>',
        '<style>p{margin:0}</style>',
        '<img src="data:image/png;base64,AAAA">',
      ]) {
        expect(mark(html, dark: true), html);
      }
    });
  });

  group('prefers-color-scheme, answered by the app', () {
    const styles = '<style>@media (prefers-color-scheme: dark){p{x:1}}'
        '@media (prefers-color-scheme:light){p{y:1}}</style>';

    test('a dark app shows the dark design and not the light one', () {
      expect(
        answerColourSchemeQueries(styles, dark: true),
        '<style>@media (color){p{x:1}}@media (monochrome){p{y:1}}</style>',
      );
    });

    test('a light app the other way round', () {
      expect(
        answerColourSchemeQueries(styles, dark: false),
        '<style>@media (monochrome){p{x:1}}@media (color){p{y:1}}</style>',
      );
    });

    test("a picture's dark-mode source too", () {
      expect(
        answerColourSchemeQueries(
          '<source srcset="a.png" media="(prefers-color-scheme: dark)">',
          dark: false,
        ),
        '<source srcset="a.png" media="(monochrome)">',
      );
    });

    test('but not words in the message', () {
      const html = '<p>prefers-color-scheme: dark</p>';
      expect(answerColourSchemeQueries(html, dark: true), html);
    });
  });
}
