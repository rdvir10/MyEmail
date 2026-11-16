import 'dart:io' show zlib;
import 'dart:typed_data';

/// How many pixels square a badge is made, unless asked otherwise.
const badgeSize = 160;

/// The app's own mark, the dart from the launcher icon, on a circle of the
/// account's colour, as a PNG: the picture on the right of a mail
/// notification.
///
/// The colour says whose mailbox the message came to before anything is
/// read, and the dart says it is this app's, the way the icon on the home
/// screen does. Ron asked for the app's icon in the account's colour: it
/// used to be the sender's initial on the circle, and a letter that changes
/// with every sender made the colour harder to read as the account's. That
/// picture is the one place Android lets the colour show: a coloured
/// background is kept for music players and ongoing tasks, and a mail
/// notification cannot have one.
///
/// Worked out here, point by point, and written as a PNG by hand, with
/// nothing asked of the phone's graphics. It used to be painted with
/// dart:ui and read back as an image. Every mail notification is posted
/// from an isolate with no screen, and arithmetic is the same in every
/// isolate, on every phone. (This was changed while looking for why Ron's
/// tablet showed no picture, 2026-11-16. That turned out to be the
/// notifications plugin taking the picture away, not the painting; whether
/// the painting ever failed is not known.)
///
/// [badgeSize] pixels square: a shade shows it at 32 dp, 61 pixels on the
/// tablet and no more than 128 on the sharpest phone. It was 256, which
/// was four times the work and the bytes for nothing seen.
///
/// Null only if something here is wrong: a notification without its badge
/// is a small loss where one that never arrives is not.
Future<Uint8List?> drawAccountBadge(
  int colorValue, {
  int size = badgeSize,
}) async {
  try {
    return _png(_paint(colorValue, size, _dart), size);
  } catch (_) {
    return null;
  }
}

/// A calendar on a circle of the account's colour, as a PNG: the picture
/// on the right of a calendar notification, a meeting's reminder or mail
/// about a meeting.
///
/// On a Pixel the row's own small icon is the calendar already, in a ring
/// of the account's colour. A Samsung draws the app's launcher icon there
/// whatever the notification asks for, so on Ron's tablet a reminder had
/// neither a calendar nor the account's colour (seen 2026-11-16). This
/// picture is the one place both can be said on every phone.
///
/// Null as [drawAccountBadge] is.
Future<Uint8List?> drawCalendarBadge(
  int colorValue, {
  int size = badgeSize,
}) async {
  try {
    return _png(_paint(colorValue, size, _calendar(colorValue)), size);
  } catch (_) {
    return null;
  }
}

/// A shape in one colour, on the launcher icon's 108-unit square: whether
/// the point ([x], [y]) is inside it.
typedef _Shape = ({int colour, bool Function(double x, double y) holds});

/// The launcher icon's dart: the body in white and the underside of the
/// fold a shade darker, which is what stops it reading as a flat
/// arrowhead. The same paths as ic_launcher_foreground.xml.
final List<_Shape> _dart = [
  (
    colour: 0xFFFFFFFF,
    holds: _polygon(
        const [(27.1, 52.9), (80.9, 30.1), (60.0, 80.9), (52.1, 62.2)]),
  ),
  (
    colour: 0xFFF0D6C2,
    holds: _polygon(const [(52.1, 62.2), (80.9, 30.1), (60.0, 80.9)]),
  ),
];

/// A calendar's page in white: two rings over its top edge, a line of the
/// circle's colour under its heading, and one day marked, as Material's
/// "event" icon marks one. Later shapes lie over earlier ones.
List<_Shape> _calendar(int colorValue) => [
      (colour: 0xFFFFFFFF, holds: _box(39, 25, 45, 39, 3)),
      (colour: 0xFFFFFFFF, holds: _box(63, 25, 69, 39, 3)),
      (colour: 0xFFFFFFFF, holds: _box(29, 32, 79, 82, 6)),
      (colour: colorValue, holds: _box(29, 44, 79, 48, 0)),
      (colour: colorValue, holds: _box(57, 59, 71, 73, 2)),
    ];

/// A box from ([l], [t]) to ([r], [b]) with corners rounded by [round].
bool Function(double, double) _box(
  double l,
  double t,
  double r,
  double b,
  double round,
) =>
    (x, y) {
      if (x < l || x >= r || y < t || y >= b) return false;
      // Inside the cross the corners leave; in a corner, inside its arc.
      final cx = x < l + round ? l + round : (x > r - round ? r - round : x);
      final cy = y < t + round ? t + round : (y > b - round ? b - round : y);
      final dx = x - cx, dy = y - cy;
      return dx * dx + dy * dy <= round * round;
    };

/// The shape whose corners are [points], in order.
bool Function(double, double) _polygon(List<(double, double)> points) =>
    (x, y) {
      var inside = false;
      for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
        final (xi, yi) = points[i];
        final (xj, yj) = points[j];
        if ((yi > y) != (yj > y) &&
            x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
          inside = !inside;
        }
      }
      return inside;
    };

/// How many points across and down each pixel is tried at, for an edge
/// that is not a staircase.
const _fine = 4;

/// The circle of [colorValue] with [shapes] on it, [size] pixels square,
/// as red, green, blue and how solid, a byte each, row by row. Clear
/// outside the circle, so the notification shows through.
Uint8List _paint(int colorValue, int size, List<_Shape> shapes) {
  final out = Uint8List(size * size * 4);
  final unit = 108 / size;
  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var red = 0, green = 0, blue = 0, covered = 0;
      for (var sy = 0; sy < _fine; sy++) {
        final y = (py + (sy + 0.5) / _fine) * unit;
        for (var sx = 0; sx < _fine; sx++) {
          final x = (px + (sx + 0.5) / _fine) * unit;
          final dx = x - 54, dy = y - 54;
          if (dx * dx + dy * dy > 54 * 54) continue;
          var colour = colorValue;
          for (final shape in shapes) {
            if (shape.holds(x, y)) colour = shape.colour;
          }
          red += (colour >> 16) & 0xff;
          green += (colour >> 8) & 0xff;
          blue += colour & 0xff;
          covered++;
        }
      }
      if (covered == 0) continue;
      final at = (py * size + px) * 4;
      out[at] = (red / covered).round();
      out[at + 1] = (green / covered).round();
      out[at + 2] = (blue / covered).round();
      out[at + 3] = (255 * covered / (_fine * _fine)).round();
    }
  }
  return out;
}

/// [rgba], [size] pixels square, as a PNG file: its eight bytes, a header,
/// the rows packed, and an end, each part with its length before it and
/// its check after.
Uint8List _png(Uint8List rgba, int size) {
  final rows = Uint8List((size * 4 + 1) * size);
  for (var y = 0; y < size; y++) {
    final at = y * (size * 4 + 1);
    // A row as it is, with nothing taken from the row before: byte 0.
    rows.setRange(at + 1, at + 1 + size * 4, rgba, y * size * 4);
  }
  final header = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8) // eight bits to a colour
    ..setUint8(9, 6); // red, green, blue and how solid
  final file = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void part(String name, List<int> data) {
    final body = [...name.codeUnits, ...data];
    file
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, _check(body))).buffer.asUint8List());
  }

  part('IHDR', header.buffer.asUint8List());
  part('IDAT', zlib.encode(rows));
  part('IEND', const []);
  return file.toBytes();
}

/// The check a PNG keeps after each of its parts (CRC-32).
int _check(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _checks[(crc ^ b) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final List<int> _checks = [
  for (var n = 0; n < 256; n++)
    () {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    }(),
];
