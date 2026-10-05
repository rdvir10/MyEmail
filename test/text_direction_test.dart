import 'dart:ui' show TextDirection;

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/quote_builder.dart';
import 'package:myemail/data/compose/reply_draft.dart';
import 'package:myemail/domain/text_direction.dart';
import 'package:myemail/ui/compose/open_compose.dart';

/// Which way what is written reads: Hebrew from the right, English from the
/// left, by the first letter.
void main() {
  group('firstStrongDirection', () {
    test('a Hebrew or Arabic line reads right-to-left', () {
      expect(firstStrongDirection('שלום עולם'), TextDirection.rtl);
      expect(firstStrongDirection('مرحبا'), TextDirection.rtl);
    });

    test('an English line reads left-to-right', () {
      expect(firstStrongDirection('Hello'), TextDirection.ltr);
    });

    test('by the first letter, whatever digits or marks come before it', () {
      expect(firstStrongDirection('3 הצעות מחיר'), TextDirection.rtl);
      expect(firstStrongDirection('(שלום)'), TextDirection.rtl);
      expect(firstStrongDirection('- Hello שלום'), TextDirection.ltr);
    });

    test('with no letter to go by, it says nothing', () {
      expect(firstStrongDirection(''), isNull);
      expect(firstStrongDirection('123 - 456'), isNull);
    });

    test('an HTML paragraph says rtl, and an English one says nothing', () {
      expect(dirAttribute('שלום'), ' dir="rtl"');
      expect(dirAttribute('Hello'), '');
      expect(dirAttribute('42'), '');
    });
  });

  group('plain text made into HTML', () {
    test('a quoted plain-text original keeps each line its direction', () {
      expect(
        quotedOriginal(text: 'שלום\nHello'),
        '<p dir="rtl">שלום</p><p>Hello</p>',
      );
    });

    test('a reply from the notification says which way it reads', () {
      expect(
        asParagraphs('תודה רבה\n\nThanks'),
        '<div dir="rtl">תודה רבה</div><div><br></div><div>Thanks</div>',
      );
    });

    test('shared text does too, read from the words and not an entity', () {
      // Escaped first, "<שלום>" began with the letters of "&lt;".
      expect(textAsHtml('<שלום>'), '<p dir="rtl">&lt;שלום&gt;</p>');
      expect(textAsHtml('שלום\n\nHello'), '<p dir="rtl">שלום</p><p>Hello</p>');
    });
  });
}
