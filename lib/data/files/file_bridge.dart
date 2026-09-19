import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter/services.dart';

/// A file that arrived from outside the app, dropped or pasted.
class IncomingFile {
  const IncomingFile({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String path;
  final String name;
  final String mimeType;
  final int sizeBytes;

  static IncomingFile? fromMap(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    if (path is! String || path.isEmpty) return null;
    return IncomingFile(
      path: path,
      name: '${value['name'] ?? 'file'}',
      mimeType: '${value['mime'] ?? 'application/octet-stream'}',
      sizeBytes: value['size'] is int
          ? value['size'] as int
          : int.tryParse('${value['size']}') ?? 0,
    );
  }
}

/// Files leaving and entering the app.
///
/// Every one of these is the same Android idea underneath — a content URI
/// another app is granted permission to read — which is why they live
/// together rather than next to the feature that uses each one.
///
/// A port, so the reading pane and the compose screen can be tested without
/// a phone: [AndroidFileBridge] talks to the platform, [FakeFileBridge]
/// records.
abstract class FileBridge {
  /// Hand the file to whatever app opens that sort of thing.
  Future<void> open(String path, {String? mimeType});

  /// The share sheet.
  Future<void> share(String path, {String? mimeType});

  /// Put the file itself on the clipboard, so it pastes into Files or Drive
  /// as a file rather than as its name.
  Future<void> copyToClipboard(
    String path, {
    String? mimeType,
    required String name,
  });

  /// Whatever files are on the clipboard, copied into this app.
  Future<List<IncomingFile>> pasteFiles();

  /// Begin dragging the file out of the app. True if the drag started.
  Future<bool> startDrag(
    String path, {
    String? mimeType,
    required String name,
  });

  /// Called when files are dropped onto the app from somewhere else.
  void onDropped(void Function(List<IncomingFile>) handler);
}

class AndroidFileBridge implements FileBridge {
  AndroidFileBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'dropped') return null;
      final files = <IncomingFile>[
        for (final item in (call.arguments as List? ?? const []))
          ?IncomingFile.fromMap(item),
      ];
      if (files.isNotEmpty) _onDropped?.call(files);
      return null;
    });
  }

  static const _channel = MethodChannel('mailtree/files');

  void Function(List<IncomingFile>)? _onDropped;

  @override
  void onDropped(void Function(List<IncomingFile>) handler) =>
      _onDropped = handler;

  @override
  Future<void> open(String path, {String? mimeType}) =>
      _channel.invokeMethod<void>('open', {'path': path, 'mime': mimeType});

  @override
  Future<void> share(String path, {String? mimeType}) =>
      _channel.invokeMethod<void>('share', {'path': path, 'mime': mimeType});

  @override
  Future<void> copyToClipboard(
    String path, {
    String? mimeType,
    required String name,
  }) =>
      _channel.invokeMethod<void>(
        'copy',
        {'path': path, 'mime': mimeType, 'name': name},
      );

  @override
  Future<List<IncomingFile>> pasteFiles() async {
    final items = await _channel.invokeListMethod<Object?>('paste');
    return [
      for (final item in items ?? const []) ?IncomingFile.fromMap(item),
    ];
  }

  @override
  Future<bool> startDrag(
    String path, {
    String? mimeType,
    required String name,
  }) async =>
      await _channel.invokeMethod<bool>(
        'startDrag',
        {'path': path, 'mime': mimeType, 'name': name},
      ) ??
      false;
}

/// Everywhere that is not a phone: the browser preview, and every test.
class FakeFileBridge implements FileBridge {
  final List<String> opened = [];
  final List<String> shared = [];
  final List<String> copied = [];
  final List<String> dragged = [];
  List<IncomingFile> onClipboard = const [];
  void Function(List<IncomingFile>)? handler;

  @override
  Future<void> open(String path, {String? mimeType}) async => opened.add(path);

  @override
  Future<void> share(String path, {String? mimeType}) async =>
      shared.add(path);

  @override
  Future<void> copyToClipboard(
    String path, {
    String? mimeType,
    required String name,
  }) async =>
      copied.add(path);

  @override
  Future<List<IncomingFile>> pasteFiles() async => onClipboard;

  @override
  Future<bool> startDrag(
    String path, {
    String? mimeType,
    required String name,
  }) async {
    dragged.add(path);
    return true;
  }

  @override
  void onDropped(void Function(List<IncomingFile>) handler) =>
      this.handler = handler;

  /// Pretend something was dropped on the app.
  void drop(List<IncomingFile> files) => handler?.call(files);
}

FileBridge platformFileBridge() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return FakeFileBridge();
  }
  try {
    return AndroidFileBridge();
  } catch (e) {
    debugPrint('[myemail] no file bridge: $e');
    return FakeFileBridge();
  }
}
