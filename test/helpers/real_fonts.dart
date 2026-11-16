import 'dart:io';

import 'package:flutter/services.dart';

/// Roboto, the face Android draws the app in, for tests that measure
/// words: whether a title fits, a time wraps, a line is cut. Flutter's test
/// font gives every letter a square of its own, a good deal wider than
/// Roboto's, so a test of what fits on a phone needs the real one. Read
/// from the Flutter SDK running the test, which keeps it with Material's
/// icons.
Future<void> loadRoboto() async {
  final fonts = _materialFonts();
  final roboto = FontLoader('Roboto');
  for (final face in [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-italic.ttf',
    'roboto-light.ttf',
  ]) {
    final file = File('${fonts.path}${Platform.pathSeparator}$face');
    roboto.addFont(Future.value(
        ByteData.sublistView(Uint8List.fromList(file.readAsBytesSync()))));
  }
  await roboto.load();
}

/// The SDK's material_fonts folder: beside the engine the test runs on
/// (`bin/cache/artifacts/engine/<platform>/flutter_tester`), or under
/// FLUTTER_ROOT.
Directory _materialFonts() {
  final tried = <String>[];
  var dir = File(Platform.resolvedExecutable).parent;
  for (var up = 0; up < 4; up++) {
    final here = Directory('${dir.path}${Platform.pathSeparator}material_fonts');
    tried.add(here.path);
    if (here.existsSync()) return here;
    dir = dir.parent;
  }
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final here = Directory([root, 'bin', 'cache', 'artifacts', 'material_fonts']
        .join(Platform.pathSeparator));
    tried.add(here.path);
    if (here.existsSync()) return here;
  }
  throw StateError('Roboto not found in the Flutter SDK; looked in $tried');
}
