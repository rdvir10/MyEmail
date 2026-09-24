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

    test("a change of From replaces this message's signature only", () {
      // A quoted message sent from here has a signature div of its own,
      // which is the sender's and stays.
      expect(doc, contains('window.mailtreeSetSignature = function'));
      expect(doc, contains("querySelector('body > .mailtree-signature')"));
    });
  });
}
