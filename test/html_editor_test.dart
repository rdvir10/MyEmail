import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/compose/html_editor.dart';

/// The compose editor runs JavaScript for its bridge, so what a quoted
/// message can do inside it is closed off by rules that do not need a
/// WebView to check.
void main() {
  group('navigation', () {
    test('only the document\'s own load, before it has finished', () {
      expect(editorAllowsNavigation('about:blank', loaded: false), isTrue);
      expect(editorAllowsNavigation('data:text/html,x', loaded: false), isTrue);
    });

    // A meta refresh or tapped link to a data: page used to replace the
    // editor with the sender's page, which could then post 'send'.
    test('nothing at all once it has loaded', () {
      for (final url in [
        'data:text/html;base64,PHNjcmlwdD4=',
        'about:blank',
        'https://example.com/',
        'javascript:alert(1)',
      ]) {
        expect(editorAllowsNavigation(url, loaded: true), isFalse, reason: url);
      }
    });

    test('never a web page, even while loading', () {
      expect(editorAllowsNavigation('https://example.com/', loaded: false),
          isFalse);
    });
  });

  group('the document', () {
    final doc = editorDocument('<p>Hi</p>', dark: false, nonce: 'n0nce');

    test('only its own script may run, and nothing is fetched', () {
      final csp = RegExp(r'Content-Security-Policy" content="([^"]*)"')
          .firstMatch(doc)
          ?.group(1);
      expect(csp, isNotNull);
      expect(csp, contains("default-src 'none'"));
      expect(csp, contains("script-src 'nonce-n0nce'"));
      expect(csp, isNot(contains('unsafe-eval')));
      expect(csp, isNot(contains("script-src 'unsafe-inline'")));
      expect(csp, isNot(contains('https:')));
    });

    test('the policy comes before anything the message brings', () {
      expect(doc.indexOf('Content-Security-Policy'),
          lessThan(doc.indexOf('<p>Hi</p>')));
    });

    test('the bridge script carries the nonce', () {
      expect(doc, contains('<script nonce="n0nce">'));
      expect(RegExp(r'<script(?! nonce="n0nce")').hasMatch(doc), isFalse);
    });

    test('each paragraph written takes the direction of its first letter, '
        'and the quote is left as it came', () {
      // As the JavaScript receives it: an escape a Dart string would have
      // swallowed arrives as the letter alone, and the pattern matches
      // nothing.
      expect(doc, contains(r'var LETTER = /\p{L}/u;'));
      expect(doc,
          contains(r'var RTL = /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/;'));
      expect(doc, contains("if (top.classList.contains('mailtree-quote')) continue;"));
      expect(doc, contains("body.addEventListener('input', orientAll);"));
    });

    test("what is sent has every paragraph's direction brought up to date",
        () {
      expect(
        RegExp(r'window\.mailtreeGetHtml = function \(\) \{\s*orientAll\(\);')
            .hasMatch(doc),
        isTrue,
      );
    });

    test('what is sent carries no script, though the page puts its own in '
        'the body', () {
      // Written after </body>, which a browser reads as more of the body:
      // every message went out with the editor's code in it.
      expect(doc.indexOf('<script nonce='), greaterThan(doc.indexOf('</body>')));
      final getHtml = doc.substring(
        doc.indexOf('window.mailtreeGetHtml = function'),
        doc.indexOf('window.mailtreeSetTheme'),
      );
      expect(getHtml, contains("copy.querySelectorAll('script')"));
      expect(getHtml, contains('return copy.innerHTML;'));
      expect(getHtml, isNot(contains('return document.body.innerHTML')));
    });

    test('the script works on the real body, whatever the message names', () {
      // Behind the sanitiser, which takes a picture's name off. A named
      // picture is a property of the document ahead of its own, so
      // <img name="body"> made document.body that picture: the editor read
      // back nothing, and an empty message was sent.
      final script = doc.substring(doc.indexOf('<script nonce='));
      expect(script,
          contains("Object.getOwnPropertyDescriptor(Document.prototype, 'body')"));
      expect(script, isNot(contains('document.body')));
    });

    test('in the dark the quote goes dark too, and is sent as it came', () {
      const quote = '<div class="mailtree-quote">'
          '<p style="color:#000">Black on white</p></div>';
      final dark = editorDocument(quote, dark: true, nonce: 'n0nce');
      // It used to sit on a light sheet of its own in a dark editor.
      expect(dark, isNot(contains('--quote-bg')));
      expect(dark, contains('data-mt-light-style="color:#000"'));
      expect(dark, contains('style="color:#e1e2e9">Black on white'));

      final light = editorDocument(quote, dark: false, nonce: 'n0nce');
      expect(light, contains('style="color:#000">Black on white'));

      final getHtml = dark.substring(
        dark.indexOf('window.mailtreeGetHtml = function'),
        dark.indexOf('window.mailtreeSetTheme'),
      );
      expect(getHtml, contains('paintColours(copy, false);'),
          reason: 'the colours as they came');
      expect(getHtml, contains('unmark(copy);'), reason: 'and no marks');
      expect(
        RegExp(r'window\.mailtreeSetTheme = function \(name\) \{[^}]*'
                r"paintColours\(body, name === 'dark'\);")
            .hasMatch(dark),
        isTrue,
        reason: 'a theme change repaints the quote in place',
      );
    });

    test('a new signature turns with the theme, and goes out as written', () {
      // Marked on the way in, and painted where it lands.
      expect(bothWays('<p style="color:#000">Ron</p>', dark: false),
          contains('data-mt-dark-style="color:#e1e2e9"'));
      final setSignature = doc.substring(
        doc.indexOf('window.mailtreeSetSignature = function'),
        doc.indexOf('window.mailtreeFocus'),
      );
      expect(setSignature, contains('paintColours(sig,'));
    });

    test("a change of From replaces this message's signature only", () {
      // A quoted message sent from here has a signature div of its own,
      // which is the sender's and stays.
      expect(doc, contains('window.mailtreeSetSignature = function'));
      expect(doc, contains("querySelector('body > .mailtree-signature')"));
    });

    // Tab in the body moves between the message's fields, as it does above
    // it, and the compose screen says where to.
    test('Tab is told to the screen, never typed or left to the browser', () {
      final keys = doc.substring(
        doc.indexOf("document.addEventListener('keydown'"),
        doc.indexOf('function keepCaretVisible'),
      );
      final tab = keys.substring(keys.indexOf("e.key === 'Tab'"));
      expect(tab, contains('e.preventDefault();'));
      expect(tab, contains("e.shiftKey ? 'backTab' : 'tab'"));
    });

    test('coming back to the body puts the caret where it was', () {
      final focus = doc.substring(doc.indexOf('window.mailtreeFocus = function'));
      expect(focus.substring(0, focus.indexOf('};')),
          contains('sel.addRange(lastCaret)'));
      expect(doc, contains('lastCaret = sel.getRangeAt(0).cloneRange()'));
    });
  });
}
