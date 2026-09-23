import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/sender_badge.dart';

/// The circle on the right of a mail notification: the sender's initial on
/// the account's colour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the letter', () {
    test("is the sender's first letter, in capitals", () {
      expect(senderInitial('dana Levi'), 'D');
    });

    test('skips the quotes and brackets a name arrives in', () {
      expect(senderInitial('"Dana Levi"'), 'D');
      expect(senderInitial('(Hadco) Accounts'), 'H');
    });

    test('an address with no name gives its own first letter', () {
      expect(senderInitial('noreply@example.com'), 'N');
    });

    test('is not only Latin', () {
      expect(senderInitial('רון'), 'ר');
    });

    test('nothing to go on is a question mark, not a blank', () {
      expect(senderInitial(''), '?');
      expect(senderInitial('  "" '), '?');
    });
  });

  group('the picture', () {
    const colour = 0xFF107C41;
    const size = 64;

    Future<ByteData> pixels(Uint8List png) async {
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      addTearDown(image.dispose);
      expect(image.width, size);
      expect(image.height, size);
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }

    int at(ByteData rgba, int x, int y) {
      final i = (y * size + x) * 4;
      final r = rgba.getUint8(i), g = rgba.getUint8(i + 1);
      final b = rgba.getUint8(i + 2), a = rgba.getUint8(i + 3);
      return a << 24 | r << 16 | g << 8 | b;
    }

    test("is a circle of the account's colour", () async {
      final png = await drawSenderBadge('D', colour, size: size);
      final rgba = await pixels(png!);

      // Inside the circle, clear of the letter.
      expect(at(rgba, size ~/ 2, 3), colour);
      // Outside it, in a corner: nothing, so the notification shows through.
      expect(at(rgba, 0, 0) >>> 24, 0);
    });

    test('with the letter drawn on it', () async {
      final png = await drawSenderBadge('D', colour, size: size);
      final rgba = await pixels(png!);

      expect(at(rgba, size ~/ 2, size ~/ 2), isNot(colour));
    });
  });
}
