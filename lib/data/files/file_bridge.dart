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

/// What another app shared to this one, or asked to be written: files,
/// text, a subject, and who it is to.
class SharedContent {
  const SharedContent({
    this.files = const [],
    this.text,
    this.subject,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.skipped = 0,
  });

  final List<IncomingFile> files;
  final String? text;
  final String? subject;

  /// Who it is to, as the other app wrote them: an address each, or
  /// several with commas between, with or without a name in front. A
  /// calendar's "Email guests" hands them over with the share, and an
  /// address tapped in a browser comes as a mailto: link.
  final List<String> to;
  final List<String> cc;
  final List<String> bcc;

  /// Files that were shared and could not be read: see [skippedFiles].
  final int skipped;

  bool get hasRecipients => to.isNotEmpty || cc.isNotEmpty || bcc.isNotEmpty;

  bool get isEmpty =>
      files.isEmpty &&
      (text == null || text!.trim().isEmpty) &&
      subject == null &&
      !hasRecipients;

  static SharedContent? fromMap(Object? value) {
    if (value is! Map) return null;
    final files = <IncomingFile>[
      for (final item in (value['files'] as List? ?? const []))
        ?IncomingFile.fromMap(item),
    ];
    final mailto = value['mailto'];
    final link = mailto is String ? MailtoLink.parse(mailto) : null;
    String? given(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    List<String> addresses(Object? v) => [
          for (final a in v is List ? v : const [])
            if (a is String && a.trim().isNotEmpty) a.trim(),
        ];
    final content = SharedContent(
      files: files,
      // What the other app put beside the link is what it meant, where it
      // put anything: Android's own words for it over the link's.
      text: given(value['text']) ?? given(link?.body),
      subject: given(value['subject']) ?? given(link?.subject),
      to: [...?link?.to, ...addresses(value['to'])],
      cc: [...?link?.cc, ...addresses(value['cc'])],
      bcc: [...?link?.bcc, ...addresses(value['bcc'])],
      skipped: skippedFiles(value),
    );
    // A share of nothing but files that could not be read is still worth
    // hearing about: it is the only way to say so.
    return content.isEmpty && content.skipped == 0 ? null : content;
  }
}

/// A mailto: link, read as RFC 6068 has it: addresses before the `?`, then
/// headers. Read by hand rather than as a [Uri]'s query, which takes `+`
/// for a space; in a mailto: link it is a `+`, as in ron+work@example.com.
class MailtoLink {
  const MailtoLink({
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject,
    this.body,
  });

  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String? subject;
  final String? body;

  /// Null for anything that is not a mailto: link. Headers other than
  /// these are left out: none of them is for a new message to take.
  static MailtoLink? parse(String link) {
    if (!link.toLowerCase().startsWith('mailto:')) return null;
    final rest = link.substring('mailto:'.length);
    final ask = rest.indexOf('?');
    final path = ask < 0 ? rest : rest.substring(0, ask);
    final to = <String>[if (path.trim().isNotEmpty) _decode(path).trim()];
    final cc = <String>[];
    final bcc = <String>[];
    String? subject;
    String? body;
    if (ask >= 0) {
      for (final field in rest.substring(ask + 1).split('&')) {
        final equals = field.indexOf('=');
        if (equals <= 0) continue;
        final value = _decode(field.substring(equals + 1));
        switch (_decode(field.substring(0, equals)).toLowerCase()) {
          case 'to' when value.trim().isNotEmpty:
            to.add(value.trim());
          case 'cc' when value.trim().isNotEmpty:
            cc.add(value.trim());
          case 'bcc' when value.trim().isNotEmpty:
            bcc.add(value.trim());
          case 'subject':
            subject = value;
          case 'body':
            // Lines end in CRLF on the wire, and in a newline here.
            body = value.replaceAll('\r\n', '\n');
        }
      }
    }
    return MailtoLink(to: to, cc: cc, bcc: bcc, subject: subject, body: body);
  }

  /// Percent-decoded, or as it came where the encoding is broken: a link
  /// written by hand is still worth what can be read of it. A stray `%` is
  /// an ArgumentError and bytes that are not UTF-8 a FormatException; let
  /// through, either one lost the whole link, and the share it came with.
  static String _decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    } on FormatException {
      return s;
    }
  }
}

/// How many files Android was handed and could not copy in: refused, too
/// big for the disk, or gone before they could be read. Said out loud,
/// because a share or a drop that quietly left one out looks as if it
/// worked.
int skippedFiles(Map<Object?, Object?> payload) {
  final skipped = payload['skipped'];
  return skipped is int && skipped > 0 ? skipped : 0;
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
/// One file in a drag out of the app.
class DragFile {
  const DragFile({required this.path, required this.name, this.mimeType});

  final String path;
  final String name;
  final String? mimeType;
}

/// What landed on the app: the files, and where they came from.
class DroppedFiles {
  const DroppedFiles(
    this.files, {
    this.label,
    this.text,
    this.at = Offset.zero,
    this.skipped = 0,
  });

  final List<IncomingFile> files;

  /// Files in the drop that could not be read: see [skippedFiles].
  final int skipped;

  /// The drag's label, which this app sets on its own drags so a copy of
  /// it can tell a message of its own from a file from outside.
  final String? label;

  /// Text that rode along with the files, if any.
  final String? text;

  /// Where it landed, in physical pixels of the window.
  final Offset at;
}

/// The app Android opens a sort of file in without asking.
class DefaultApp {
  const DefaultApp({
    required this.packageName,
    required this.label,
    this.only = false,
  });

  final String packageName;

  /// Its name as the launcher shows it.
  final String label;

  /// The only app installed that opens it, chosen by nobody.
  final bool only;
}

abstract class FileBridge {
  /// Hand the file to whatever app opens that sort of thing.
  Future<void> open(String path, {String? mimeType});

  /// Every app that opens this sort of file, to choose one from this once.
  Future<void> openWith(String path, {String? mimeType});

  /// The app a file called [name] opens in without asking, or null where
  /// Android asks which.
  Future<DefaultApp?> defaultAppFor(String name, {String? mimeType});

  /// Android's page for [app]'s defaults, where an "Always" is undone. No
  /// app may change another's default itself.
  Future<void> showDefaultsOf(DefaultApp app);

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

  /// Begin dragging several files, with a label and a line of text along
  /// for the ride. True if the drag started.
  Future<bool> startDragFiles(
    List<DragFile> files, {
    String? label,
    String? text,
  });

  /// Called when files are dropped onto the app from somewhere else.
  void onDropped(void Function(DroppedFiles) handler);

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
          final args = call.arguments;
          final items = args is Map ? args['files'] as List? : args as List?;
          final files = <IncomingFile>[
            for (final item in items ?? const []) ?IncomingFile.fromMap(item),
          ];
          final dropped = DroppedFiles(
            files,
            label: args is Map ? args['label'] as String? : null,
            text: args is Map ? args['text'] as String? : null,
            at: args is Map
                ? Offset(
                    (args['x'] as num?)?.toDouble() ?? 0,
                    (args['y'] as num?)?.toDouble() ?? 0,
                  )
                : Offset.zero,
            skipped: args is Map ? skippedFiles(args) : 0,
          );
          if (files.isNotEmpty || dropped.text != null || dropped.skipped > 0) {
            _onDropped?.call(dropped);
          }
        case 'shared':
          final content = SharedContent.fromMap(call.arguments);
          if (content != null) _onShared?.call(content);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('mailtree/files');

  void Function(DroppedFiles)? _onDropped;
  void Function(SharedContent)? _onShared;

  @override
  void onDropped(void Function(DroppedFiles) handler) => _onDropped = handler;

  @override
  void onShared(void Function(SharedContent) handler) => _onShared = handler;

  @override
  Future<SharedContent?> takeShare() async =>
      SharedContent.fromMap(await _channel.invokeMethod<Object?>('takeShare'));

  @override
  Future<void> open(String path, {String? mimeType}) =>
      _channel.invokeMethod<void>('open', {'path': path, 'mime': mimeType});

  @override
  Future<void> openWith(String path, {String? mimeType}) => _channel
      .invokeMethod<void>('openWith', {'path': path, 'mime': mimeType});

  @override
  Future<DefaultApp?> defaultAppFor(String name, {String? mimeType}) async {
    final found = await _channel.invokeMethod<Object?>(
      'defaultApp',
      {'name': name, 'mime': mimeType},
    );
    if (found is! Map) return null;
    final packageName = found['package'];
    if (packageName is! String) return null;
    return DefaultApp(
      packageName: packageName,
      label: '${found['label'] ?? packageName}',
      only: found['only'] == true,
    );
  }

  @override
  Future<void> showDefaultsOf(DefaultApp app) => _channel
      .invokeMethod<void>('showDefaults', {'package': app.packageName});

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

  @override
  Future<bool> startDragFiles(
    List<DragFile> files, {
    String? label,
    String? text,
  }) async =>
      await _channel.invokeMethod<bool>('startDragMany', {
        'paths': [for (final f in files) f.path],
        'mimes': [for (final f in files) f.mimeType],
        'names': [for (final f in files) f.name],
        'label': label,
        'text': text,
      }) ??
      false;
}

/// Everywhere that is not a phone: the browser preview, and every test.
class FakeFileBridge implements FileBridge {
  final List<String> opened = [];
  final List<String> shared = [];
  final List<String> copied = [];
  final List<String> dragged = [];
  List<IncomingFile> onClipboard = const [];
  void Function(DroppedFiles)? handler;

  /// Every drag of several files, as the lists handed over.
  final List<List<DragFile>> draggedFiles = [];
  String? draggedLabel;
  String? draggedText;

  @override
  Future<void> open(String path, {String? mimeType}) async => opened.add(path);

  /// Opened with a choice of app; see [openWith].
  final List<String> chosenFor = [];
  final List<String> defaultsShown = [];

  /// What [defaultAppFor] answers.
  DefaultApp? defaultApp;

  @override
  Future<void> openWith(String path, {String? mimeType}) async =>
      chosenFor.add(path);

  @override
  Future<DefaultApp?> defaultAppFor(String name, {String? mimeType}) async =>
      defaultApp;

  @override
  Future<void> showDefaultsOf(DefaultApp app) async =>
      defaultsShown.add(app.packageName);

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
  Future<bool> startDragFiles(
    List<DragFile> files, {
    String? label,
    String? text,
  }) async {
    draggedFiles.add(files);
    draggedLabel = label;
    draggedText = text;
    return true;
  }

  @override
  void onDropped(void Function(DroppedFiles) handler) => this.handler = handler;

  /// Pretend something was dropped on the app.
  void drop(
    List<IncomingFile> files, {
    String? label,
    String? text,
    Offset at = Offset.zero,
    int skipped = 0,
  }) =>
      handler?.call(DroppedFiles(
        files,
        label: label,
        text: text,
        at: at,
        skipped: skipped,
      ));

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
