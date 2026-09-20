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

/// What another app shared to this one.
class SharedContent {
  const SharedContent({
    this.files = const [],
    this.text,
    this.subject,
  });

  final List<IncomingFile> files;
  final String? text;
  final String? subject;

  bool get isEmpty =>
      files.isEmpty && (text == null || text!.trim().isEmpty);

  static SharedContent? fromMap(Object? value) {
    if (value is! Map) return null;
    final files = <IncomingFile>[
      for (final item in (value['files'] as List? ?? const []))
        ?IncomingFile.fromMap(item),
    ];
    final text = value['text'];
    final subject = value['subject'];
    final content = SharedContent(
      files: files,
      text: text is String && text.trim().isNotEmpty ? text : null,
      subject: subject is String && subject.trim().isNotEmpty ? subject : null,
    );
    return content.isEmpty ? null : content;
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

  /// What the app was opened to receive from a share sheet, if anything.
  /// Read once; the next call is null.
  Future<SharedContent?> takeShare();

  /// Called when something is shared to the app while it is running.
  void onShared(void Function(SharedContent) handler);
}

class AndroidFileBridge implements FileBridge {
  AndroidFileBridge() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dropped':
          final files = <IncomingFile>[
            for (final item in (call.arguments as List? ?? const []))
              ?IncomingFile.fromMap(item),
          ];
          if (files.isNotEmpty) _onDropped?.call(files);
        case 'shared':
          final content = SharedContent.fromMap(call.arguments);
          if (content != null) _onShared?.call(content);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('mailtree/files');

  void Function(List<IncomingFile>)? _onDropped;
  void Function(SharedContent)? _onShared;

  @override
  void onDropped(void Function(List<IncomingFile>) handler) =>
      _onDropped = handler;

  @override
  void onShared(void Function(SharedContent) handler) => _onShared = handler;

  @override
  Future<SharedContent?> takeShare() async =>
      SharedContent.fromMap(await _channel.invokeMethod<Object?>('takeShare'));

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

  /// What the app was "opened with", for a test of a cold-start share.
  SharedContent? openedWith;
  void Function(SharedContent)? shareHandler;

  @override
  Future<SharedContent?> takeShare() async {
    final content = openedWith;
    openedWith = null;
    return content;
  }

  @override
  void onShared(void Function(SharedContent) handler) =>
      shareHandler = handler;

  /// Pretend something was shared to the running app.
  void receiveShare(SharedContent content) => shareHandler?.call(content);
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
