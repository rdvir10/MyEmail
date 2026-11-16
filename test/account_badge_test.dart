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

  // The picture at the side of a calendar notification: on Ron's tablet
  // the row's own icon is the app's, whatever the notification asks for,
  // and a reminder showed neither a calendar nor its account's colour
  // (2026-11-16).
  group('a calendar on the same circle, for a calendar notification', () {
    test("is a circle of the account's colour, clear outside it", () async {
      final rgba = await pixels((await drawCalendarBadge(colour, size: size))!);
      expect(at(rgba, size ~/ 2, 3), colour);
      expect(at(rgba, 0, 0) >>> 24, 0);
    });

    test('with a white page, two rings over it, a line under its heading '
        'and one day marked, both in the colour', () async {
      final rgba = await pixels((await drawCalendarBadge(colour, size: size))!);
      // The page's body, to the left of the marked day; its heading.
      expect(at(rgba, 24, 38), 0xFFFFFFFF);
      expect(at(rgba, 32, 22), 0xFFFFFFFF);
      // A ring, above the page.
      expect(at(rgba, 24, 16), 0xFFFFFFFF);
      // Between the rings above the page: the circle.
      expect(at(rgba, 32, 16), colour);
      // The line under the heading, and the marked day.
      expect(at(rgba, 32, 27), colour);
      expect(at(rgba, 38, 39), colour);
    });

    test('is not the dart, and is one picture per colour', () async {
      final calendar = await drawCalendarBadge(colour, size: size);
      expect(calendar, isNot(await drawAccountBadge(colour, size: size)));
      expect(calendar, await drawCalendarBadge(colour, size: size));
      expect(calendar,
          isNot(await drawCalendarBadge(0xFF0F6CBD, size: size)));
    });
  });
}
