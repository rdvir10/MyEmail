import 'dart:ui' show TextDirection;

/// The right-to-left scripts: Hebrew, Arabic, Syriac, Thaana, NKo,
/// Samaritan, Mandaic, and the Hebrew and Arabic presentation forms.
final _rightToLeft = RegExp(r'[֐-ࣿיִ-﷿ﹰ-﻿]');

final _letter = RegExp(r'\p{L}', unicode: true);

/// Which way [text] reads, by its first letter, the rule Gmail's and
/// Outlook's editors follow: a Hebrew line is right-to-left, an English one
/// left-to-right, whatever digits or punctuation come before the first
/// letter. Null when there is no letter to go by, an empty line or a
/// number, so the caller can keep what it had.
TextDirection? firstStrongDirection(String text) {
  final letter = _letter.firstMatch(text)?[0];
  if (letter == null) return null;
  return _rightToLeft.hasMatch(letter) ? TextDirection.rtl : TextDirection.ltr;
}

/// ` dir="rtl"` for an HTML paragraph made of [text] when it reads
/// right-to-left, and nothing otherwise: a left-to-right paragraph needs no
/// attribute, and every mail client puts one with it on the right. Given
/// the text before it is escaped, whose entities (`&lt;`) are letters of
/// their own.
String dirAttribute(String text) =>
    firstStrongDirection(text) == TextDirection.rtl ? ' dir="rtl"' : '';
