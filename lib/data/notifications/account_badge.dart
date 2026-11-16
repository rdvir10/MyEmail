import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
/// Null when it cannot be drawn, including when drawing takes too long. This
/// runs in the background isolate as well as the app's, with no screen to
/// draw on, and a notification without its badge is a small loss where one
/// that never arrives is not.
Future<Uint8List?> drawAccountBadge(int colorValue, {int size = 256}) async {
  try {
    return await _draw(colorValue, size, _paintDart)
        .timeout(const Duration(seconds: 2));
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
/// Null when it cannot be drawn, as [drawAccountBadge].
Future<Uint8List?> drawCalendarBadge(int colorValue, {int size = 256}) async {
  try {
    return await _draw(colorValue, size, _paintCalendar)
        .timeout(const Duration(seconds: 2));
  } catch (_) {
    return null;
  }
}

/// The launcher icon's dart, on its 108-unit canvas: the body in white and
/// the underside of the fold a shade darker, which is what stops it reading
/// as a flat arrowhead. The same paths as ic_launcher_foreground.xml.
const _dart = [
  (0xFFFFFFFF, [(27.1, 52.9), (80.9, 30.1), (60.0, 80.9), (52.1, 62.2)]),
  (0xFFF0D6C2, [(52.1, 62.2), (80.9, 30.1), (60.0, 80.9)]),
];

/// What goes on the circle: drawn on [canvas], on the launcher icon's
/// 108-unit square, [scale] pixels to a unit, over [colorValue].
typedef _Mark = void Function(ui.Canvas canvas, double scale, int colorValue);

Future<Uint8List?> _draw(int colorValue, int size, _Mark mark) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final radius = size / 2;
  canvas.drawCircle(
    ui.Offset(radius, radius),
    radius,
    ui.Paint()
      ..isAntiAlias = true
      ..color = ui.Color(colorValue),
  );

  mark(canvas, size / 108, colorValue);

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// A calendar's page in white: two rings over its top edge, a line of the
/// circle's colour under its heading, and one day marked, as Material's
/// "event" icon marks one. Plain shapes, with no font to load: this is
/// drawn where there may be no screen.
void _paintCalendar(ui.Canvas canvas, double scale, int colorValue) {
  ui.RRect box(double l, double t, double r, double b, double round) =>
      ui.RRect.fromLTRBR(l * scale, t * scale, r * scale, b * scale,
          ui.Radius.circular(round * scale));
  final white = ui.Paint()
    ..isAntiAlias = true
    ..color = const ui.Color(0xFFFFFFFF);
  final colour = ui.Paint()
    ..isAntiAlias = true
    ..color = ui.Color(colorValue);
  // The rings, then the page over their feet.
  canvas.drawRRect(box(39, 25, 45, 39, 3), white);
  canvas.drawRRect(box(63, 25, 69, 39, 3), white);
  canvas.drawRRect(box(29, 32, 79, 82, 6), white);
  // The heading's line, and the day.
  canvas.drawRect(
      ui.Rect.fromLTRB(29 * scale, 44 * scale, 79 * scale, 48 * scale), colour);
  canvas.drawRRect(box(57, 59, 71, 73, 2), colour);
}

void _paintDart(ui.Canvas canvas, double scale, int colorValue) {
  for (final (colour, points) in _dart) {
    final path = ui.Path();
    for (final (i, (x, y)) in points.indexed) {
      if (i == 0) {
        path.moveTo(x * scale, y * scale);
      } else {
        path.lineTo(x * scale, y * scale);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      ui.Paint()
        ..isAntiAlias = true
        ..color = ui.Color(colour),
    );
  }
}
