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

  /// Whether this window shares the screen right now: split screen, a
  /// pop-up, a DeX window.
  Future<bool> inMultiWindow();

  /// True once the window exists. False when the system did not open
  /// one — One UI, asked from a full-screen app, has been seen to answer
  /// with its Recents picker instead — so the caller keeps what it was
  /// about to hand over.
  Future<bool> open(WindowRequest request);
}

/// The route a second window starts on: `/window?file=<path>`.
const windowRoutePrefix = '/window';

/// What a window was started to show, from its initial route, or null
/// when the route is not a window's. The file is consumed: a window that
/// is restarted by the system after a crash gets nothing to show and
/// falls back to being the ordinary app, which beats a stale draft that
/// was sent an hour ago coming back.
///
/// Only a file [AndroidWindowOpener.open] could have written is touched:
/// one named by a timestamp, directly inside [handoffDir] (the app's own
/// windows folder when not given). The path used to be taken as it came,
/// and the file read and deleted before it was checked to be a window at
/// all, so a route naming any file the app can reach deleted it — the
/// stored sign-ins among them. And it is only deleted once it has been
/// read as a window, so a file that is not one is left alone.
Future<WindowRequest?> windowRequestFromRoute(
  String route, {
  Directory? handoffDir,
}) async {
  if (!route.startsWith(windowRoutePrefix)) return null;
  final path = Uri.parse(route).queryParameters['file'];
  if (path == null) return null;
  final dir = handoffDir ?? await windowHandoffDirectory();
  if (!isWindowHandoffFile(path, dir)) {
    debugPrint('[myemail] ignored a window route outside the windows folder');
    return null;
  }
  final file = File(path);
  try {
    final request = WindowRequest.decode(await file.readAsString());
    await file.delete();
    return request;
  } catch (e) {
    debugPrint('[myemail] could not read the window handoff: $e');
    return null;
  }
}

/// Where window hand-offs are written and the only place they are read from.
Future<Directory> windowHandoffDirectory() async => Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}windows',
    );

/// Whether [path] is a hand-off file directly inside [dir]: a timestamp and
/// `.json`, with no way out of the folder in between.
bool isWindowHandoffFile(String path, Directory dir) {
  final file = File(path);
  final name = file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments.last;
  return RegExp(r'^\d+\.json$').hasMatch(name) && file.parent.path == dir.path;
}

class AndroidWindowOpener implements WindowOpener {
  const AndroidWindowOpener();

  static const _channel = MethodChannel('mailtree/windows');

  @override
  Future<bool> available() async =>
      await _channel.invokeMethod<bool>('available') ?? false;

  @override
  Future<bool> inMultiWindow() async =>
      await _channel.invokeMethod<bool>('inMultiWindow') ?? false;

  @override
  Future<bool> open(WindowRequest request) async {
    final dir = await windowHandoffDirectory();
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
    final opened =
        await _channel.invokeMethod<bool>('open', {'route': route}) ?? false;
    if (!opened) {
      // Nothing will read it.
      try {
        await file.delete();
      } catch (_) {}
    }
    return opened;
  }
}

/// Records what would have been opened. Tests, and the browser preview.
class FakeWindowOpener implements WindowOpener {
  FakeWindowOpener({this.supported = true, this.opens = true});

  final bool supported;

  /// What the system answers: false stands for a launch it swallowed.
  final bool opens;
  final List<WindowRequest> opened = [];

  /// Whether the window is pretending to share the screen.
  bool multiWindow = false;

  @override
  Future<bool> available() async => supported;

  @override
  Future<bool> inMultiWindow() async => multiWindow;

  @override
  Future<bool> open(WindowRequest request) async {
    opened.add(request);
    return opens;
  }
}
