import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/window_handoff.dart';

/// Opens a second window of the app.
///
/// On Android a window is a new task holding a new copy of the activity,
/// launched adjacent so it lands beside this one in split screen or as
/// its own window under DeX. The new copy starts with a route naming a
/// file that holds what it is to show; it reads the file and deletes it.
/// A file rather than the intent itself because a draft with attachments
/// can be bigger than an intent is allowed to be.
abstract class WindowOpener {
  /// Whether this platform can have two windows at all.
  Future<bool> available();

  Future<void> open(WindowRequest request);
}

/// The route a second window starts on: `/window?file=<path>`.
const windowRoutePrefix = '/window';

/// What a window was started to show, from its initial route, or null
/// when the route is not a window's. The file is consumed: a window that
/// is restarted by the system after a crash gets nothing to show and
/// falls back to being the ordinary app, which beats a stale draft that
/// was sent an hour ago coming back.
Future<WindowRequest?> windowRequestFromRoute(String route) async {
  if (!route.startsWith(windowRoutePrefix)) return null;
  final path = Uri.parse(route).queryParameters['file'];
  if (path == null) return null;
  final file = File(path);
  try {
    final text = await file.readAsString();
    await file.delete();
    return WindowRequest.decode(text);
  } catch (e) {
    debugPrint('[myemail] could not read the window handoff: $e');
    return null;
  }
}

class AndroidWindowOpener implements WindowOpener {
  const AndroidWindowOpener();

  static const _channel = MethodChannel('mailtree/windows');

  @override
  Future<bool> available() async =>
      await _channel.invokeMethod<bool>('available') ?? false;

  @override
  Future<void> open(WindowRequest request) async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}windows',
    );
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      '${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await file.writeAsString(request.encode(), flush: true);
    final route = Uri(
      path: windowRoutePrefix,
      queryParameters: {'file': file.path},
    ).toString();
    await _channel.invokeMethod<void>('open', {'route': route});
  }
}

/// Records what would have been opened. Tests, and the browser preview.
class FakeWindowOpener implements WindowOpener {
  FakeWindowOpener({this.supported = true});

  final bool supported;
  final List<WindowRequest> opened = [];

  @override
  Future<bool> available() async => supported;

  @override
  Future<void> open(WindowRequest request) async => opened.add(request);
}
