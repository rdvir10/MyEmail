import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/account_badge.dart';

/// The circle on the right of a mail notification: the app's dart on the
/// account's colour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final png = await drawAccountBadge(colour, size: size);
    final rgba = await pixels(png!);

    // Inside the circle, clear of the dart.
    expect(at(rgba, size ~/ 2, 3), colour);
    // Outside it, in a corner: nothing, so the notification shows through.
    expect(at(rgba, 0, 0) >>> 24, 0);
  });

  test('with the dart drawn on it, in white with its fold', () async {
    final png = await drawAccountBadge(colour, size: size);
    final rgba = await pixels(png!);

    // The middle of the dart's body, and the middle of the fold, at this
    // size: well inside each shape, clear of any anti-aliased edge.
    expect(at(rgba, 32, 29), 0xFFFFFFFF);
    expect(at(rgba, 38, 34), isNot(colour));
    expect(at(rgba, 38, 34), isNot(0xFFFFFFFF));
  });

  test('is one picture per colour, whoever sent the mail', () async {
    // Nothing of the sender goes in: the same colour is the same badge.
    final a = await drawAccountBadge(colour, size: size);
    final b = await drawAccountBadge(colour, size: size);
    expect(a, b);
  });
}
