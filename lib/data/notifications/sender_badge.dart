import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The letter a notification's badge shows for a sender.
///
/// The first letter or digit rather than the first character: a display
/// name often arrives quoted or bracketed, and a badge reading `"` says
/// nothing. An address with no name gives its own first letter, which is
/// usually the sender's anyway.
String senderInitial(String sender) {
  final match = RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(sender);
  return match == null ? '?' : match[0]!.toUpperCase();
}

/// The sender's initial in white on a circle of the account's colour, as a
/// PNG, for the picture on the right of a mail notification.
///
/// The colour says whose mailbox it came to before anything is read, and
/// the letter says who sent it. That picture is the one place Android lets
/// the colour show: a coloured background is kept for music players and
/// ongoing tasks, and a mail notification cannot have one.
///
/// Null when it cannot be drawn, including when drawing takes too long. This
/// runs in the background isolate as well as the app's, with no screen to
/// draw on, and a notification without its badge is a small loss where one
/// that never arrives is not.
Future<Uint8List?> drawSenderBadge(
  String initial,
  int colorValue, {
  int size = 256,
}) async {
  try {
    return await _draw(initial, colorValue, size)
        .timeout(const Duration(seconds: 2));
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _draw(String initial, int colorValue, int size) async {
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

  final paragraph = (ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: ui.TextAlign.center,
    fontSize: size * 0.5,
    fontWeight: ui.FontWeight.w500,
    maxLines: 1,
  ))
        ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFFFFFFF)))
        ..addText(initial))
      .build()
    ..layout(ui.ParagraphConstraints(width: size.toDouble()));
  canvas.drawParagraph(paragraph, ui.Offset(0, (size - paragraph.height) / 2));

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
