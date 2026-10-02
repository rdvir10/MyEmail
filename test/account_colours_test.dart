import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/account_colours.dart';

/// WCAG contrast between two colours, the measure Android's notification
/// code holds the small icon's colour to (4.5 to 1).
double _contrast(double a, double b) =>
    (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);

double _luminance(int argb) => Color(argb).computeLuminance();

/// A light shade's surface of tone 90 (L* 90). The phone's measured about
/// tone 93; the darker one is the harder test.
final _lightShade = ((90 + 16) / 116) * ((90 + 16) / 116) * ((90 + 16) / 116);

/// The 24 the palette held before 2.75.1.
const _before = [
  0xFF003966, 0xFF0F6CBD, 0xFF4F9FE0, 0xFF5B5FC7, 0xFF00B7C3, 0xFF00838F,
  0xFF00B294, 0xFF107C41, 0xFF13A10E, 0xFF498205, 0xFFC19C00, 0xFFFFB900,
  0xFFF7630C, 0xFFCA5010, 0xFF8E562E, 0xFFE81123, 0xFFB3261E, 0xFFEA005E,
  0xFFE3008C, 0xFFB4009E, 0xFF8764B8, 0xFF5C2E91, 0xFF69797E, 0xFF393939,
];

void main() {
  group('the palette', () {
    test('has 24 colours, each once', () {
      expect(accountPalette, hasLength(24));
      expect(accountPalette.toSet(), hasLength(24));
    });

    test('each stands out 4.5 to 1 on a light shade, so Android leaves it',
        () {
      // Mint was 2.2 to 1, and the shade drew Gmail's notifications a dark
      // green the app never showed.
      const keptAsTheyWere = {0xFF0F6CBD, 0xFF5B5FC7, 0xFF107C41};
      for (final colour in accountPalette) {
        final contrast = _contrast(_luminance(colour), _lightShade);
        expect(
          contrast,
          greaterThanOrEqualTo(keptAsTheyWere.contains(colour) ? 4.0 : 4.5),
          reason: '0x${colour.toRadixString(16)} is ${contrast.toStringAsFixed(2)} '
              'to 1, so Android would redraw it',
        );
      }
    });

    test('new accounts are given eight of it, all different', () {
      expect(newAccountColours, hasLength(8));
      expect(newAccountColours.toSet(), hasLength(8));
      expect(accountPalette, containsAll(newAccountColours));
    });
  });

  group('a colour stored before 2.75.1', () {
    test('every one becomes a colour the palette has now', () {
      for (final colour in _before) {
        expect(accountPalette, contains(currentAccountColour(colour)),
            reason: '0x${colour.toRadixString(16)}');
      }
    });

    test('mint becomes the green the shade drew it in', () {
      expect(currentAccountColour(0xFF00B294), 0xFF007258);
    });

    test('the ones Android drew as they were stay as they were', () {
      for (final colour in [0xFF003966, 0xFF0F6CBD, 0xFFB4009E, 0xFF393939]) {
        expect(currentAccountColour(colour), colour);
      }
    });
  });

  test('a colour of the palette now, or from outside it, is left alone', () {
    for (final colour in accountPalette) {
      expect(currentAccountColour(colour), colour);
    }
    expect(currentAccountColour(0xFF123456), 0xFF123456);
  });
}
