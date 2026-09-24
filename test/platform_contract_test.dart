import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/print/message_printer.dart';
import 'package:myemail/data/updates/apk_installer.dart';
import 'package:myemail/data/widget/widget_setup_channel.dart';
import 'package:myemail/data/windows/window_opener.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mailbox_counts.dart';
import 'package:myemail/domain/window_handoff.dart';

/// The names the two halves of the app agree on, checked from both sides.
///
/// Every channel method, argument key and home-screen widget key is a string
/// written once in Dart and again in Kotlin. Every other test replaces the
/// Android half with a fake, so a key renamed on one side left a widget
/// saying "unset", or Open, Share or Add to calendar doing nothing on the
/// phone, with every test still passing.
///
/// This reads the Kotlin as text: what each channel handles, which argument
/// it reads for each method and as what type, and what it sends back into
/// Dart. The Dart half is then run for real against those.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final kotlin = _Kotlin.read(
    Directory('android/app/src/main/kotlin/com/rdvir/mailtree'),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('the Kotlin was found and read', () {
    // Everything below passes vacuously on a Kotlin tree it cannot read.
    expect(kotlin.handled.keys, containsAll([
      'mailtree/calendar',
      'mailtree/contacts',
      'mailtree/files',
      'mailtree/print',
      'mailtree/installer',
      'mailtree/widget',
      'mailtree/windows',
    ]));
    expect(kotlin.handled['mailtree/files']!['open'], contains('path'));
    expect(kotlin.fileKeys, containsAll(['path', 'name', 'mime', 'size']));
    expect(kotlin.droppedKeys,
        containsAll(['files', 'skipped', 'label', 'text', 'x', 'y']));
    expect(kotlin.sharedKeys, containsAll(['files', 'skipped', 'text', 'subject']));
  });

  group('what Dart asks of Android', () {
    final calls = <(String, MethodCall)>[];
    late Directory temp;

    setUp(() {
      calls.clear();
      temp = Directory.systemTemp.createTempSync('myemail-contract-');
      for (final channel in kotlin.handled.keys) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
          calls.add((channel, call));
          return switch (call.method) {
            'paste' || 'search' || 'placedWidgets' => <Object?>[],
            'takeShare' => null,
            _ => true,
          };
        });
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => temp.path,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      for (final channel in kotlin.handled.keys) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), null);
      }
      temp.deleteSync(recursive: true);
    });

    test('every call is one Android answers, with what it reads', () async {
      const calendar = AndroidDeviceCalendar();
      await calendar.available();
      await calendar.insertEvent(
        title: 'Review',
        description: 'Quarterly',
        location: 'Room 4',
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 1, 10),
        allDay: false,
      );
      await calendar.insertEvent(title: 'Only a title');

      const contacts = AndroidDeviceContacts();
      await contacts.hasPermission();
      await contacts.requestPermission();
      await contacts.search('dana', limit: 5);

      final files = AndroidFileBridge();
      await files.open('/f/a.pdf', mimeType: 'application/pdf');
      await files.share('/f/a.pdf', mimeType: 'application/pdf');
      await files.copyToClipboard('/f/a.pdf', mimeType: null, name: 'a.pdf');
      await files.pasteFiles();
      await files.startDrag('/f/a.pdf', mimeType: 'application/pdf', name: 'a');
      await files.startDragFiles(
        const [
          DragFile(path: '/f/a.pdf', name: 'a.pdf', mimeType: 'application/pdf'),
          DragFile(path: '/f/b', name: 'b'),
        ],
        label: 'myemail:messages',
        text: 'a:INBOX#1',
      );
      await files.takeShare();

      await const AndroidMessagePrinter().print(title: 'Hi', html: '<p>Hi</p>');

      final installer = AndroidApkInstaller();
      await installer.install('/f/update.apk');
      await installer.canInstall();
      await installer.openInstallPermissionSettings();

      await placedWidgetIds();

      final windows = AndroidWindowOpener();
      await windows.available();
      await windows.inMultiWindow();
      await windows.open(const ComposeWindow(
        Draft(accountId: 'a', kind: ComposeKind.newMessage),
      ));

      expect(calls, isNotEmpty);
      for (final (channel, call) in calls) {
        final where = '$channel ${call.method}';
        final reads = kotlin.handled[channel]![call.method];
        expect(reads, isNotNull, reason: '$where: Android has no such method');
        final args = call.arguments;
        final sent = args is Map ? args.cast<String, Object?>() : const {};
        for (final MapEntry(:key, :value) in sent.entries) {
          final read = reads![key];
          expect(read, isNotNull, reason: '$where: Android never reads "$key"');
          expect(
            _fits(value, read!.type),
            isTrue,
            reason: '$where: "$key" is sent as ${value.runtimeType} '
                '($value) and read as ${read.type}',
          );
        }
        for (final MapEntry(:key, :value) in reads!.entries) {
          if (!value.required) continue;
          expect(sent[key], isNotNull,
              reason: '$where: Android needs "$key" and it is not sent');
        }
      }
      // Each method Dart has, asked at least once above.
      expect(
        {for (final (c, call) in calls) '$c ${call.method}'},
        containsAll([
          'mailtree/calendar insert',
          'mailtree/files startDragMany',
          'mailtree/installer install',
          'mailtree/widget placedWidgets',
          'mailtree/windows open',
        ]),
      );
    });
  });

  group('what Android tells Dart', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    Future<void> fromAndroid(String channel, String method, Object? args) =>
        messenger.handlePlatformMessage(
          channel,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );

    test('Android only calls methods Dart listens for', () {
      final dart = {
        'mailtree/files': {'dropped', 'shared'},
        'mailtree/widget': {'configure'},
      };
      for (final MapEntry(key: channel, value: methods)
          in kotlin.invoked.entries) {
        expect(dart[channel], containsAll(methods), reason: channel);
      }
      expect(kotlin.invoked['mailtree/files'], {'dropped', 'shared'});
      expect(kotlin.invoked['mailtree/widget'], {'configure'});
    });

    // Each payload built from the keys the Kotlin puts in it, so a key
    // renamed there arrives here as nothing.
    Map<String, Object?> file() => {
          for (final key in kotlin.fileKeys)
            key: switch (key) {
              'size' => 2048,
              'mime' => 'application/pdf',
              _ => '/f/report.pdf',
            },
        };

    test('a drop arrives whole', () async {
      final bridge = AndroidFileBridge();
      DroppedFiles? dropped;
      bridge.onDropped((d) => dropped = d);

      await fromAndroid('mailtree/files', 'dropped', {
        for (final key in kotlin.droppedKeys)
          key: switch (key) {
            'files' => [file()],
            'x' || 'y' => 12.5,
            'skipped' => 1,
            _ => 'from $key',
          },
      });

      expect(dropped!.files.single.path, '/f/report.pdf');
      expect(dropped!.skipped, 1);
      expect(dropped!.files.single.sizeBytes, 2048);
      expect(dropped!.files.single.mimeType, 'application/pdf');
      expect(dropped!.label, 'from label');
      expect(dropped!.text, 'from text');
      expect(dropped!.at, const Offset(12.5, 12.5));
    });

    test('a share arrives whole', () async {
      final bridge = AndroidFileBridge();
      SharedContent? shared;
      bridge.onShared((s) => shared = s);

      await fromAndroid('mailtree/files', 'shared', {
        for (final key in kotlin.sharedKeys)
          key: switch (key) {
            'files' => [file()],
            'skipped' => 1,
            _ => 'from $key',
          },
      });

      expect(shared!.files.single.path, '/f/report.pdf');
      expect(shared!.skipped, 1);
      expect(shared!.text, 'from text');
      expect(shared!.subject, 'from subject');
    });

    test('a widget being placed is set up', () async {
      String? configured;
      listenForWidgetSetup((id) => configured = id);

      // Kotlin sends the id as a string.
      await fromAndroid('mailtree/widget', 'configure', '42');

      expect(configured, '42');
    });
  });

  group('the home-screen widget', () {
    final dart = File('lib/data/widget/mailbox_widgets.dart').readAsStringSync();
    final kt = File(
      'android/app/src/main/kotlin/com/rdvir/mailtree/'
      'MailboxCountWidgetProvider.kt',
    ).readAsStringSync();

    // Keys with their variable part taken out: widget.*.folder.
    Map<String, String> written() => {
          for (final m in RegExp(
            r"surface\.put(String|Int)\(\s*'(widget|count)\.\$\{[^}]+\}\.(\w+)'",
          ).allMatches(dart))
            '${m[2]}.*.${m[3]}': m[1] == 'Int' ? 'number' : 'string',
        };

    Map<String, String> read() {
      final found = <String, String>{
        for (final m in RegExp(
          r'(getString|number)\(\s*(?:widgetData,\s*)?"(widget|count)\.\$\w+\.(\w+)"',
        ).allMatches(kt))
          '${m[2]}.*.${m[3]}': m[1] == 'number' ? 'number' : 'string',
      };
      // Unread or total is picked in one expression and the key handed to
      // number() after, so those two are found by name alone.
      for (final m in RegExp(r'"count\.\$\w+\.(\w+)"').allMatches(kt)) {
        found.putIfAbsent('count.*.${m[1]}', () => 'number');
      }
      return found;
    }

    test('everything Android reads, Dart writes, as the same kind', () {
      final w = written();
      final r = read();
      expect(r, isNotEmpty);
      expect(r.keys, containsAll(['widget.*.folder', 'count.*.new']));
      for (final MapEntry(:key, :value) in r.entries) {
        expect(w[key], isNotNull, reason: 'Android reads $key; nothing writes it');
        expect(w[key], value, reason: key);
      }
    });

    test('the mode Android looks for is one Dart writes', () {
      final modes = RegExp(r'\.mode", null\) == "(\w+)"')
          .allMatches(kt)
          .map((m) => m[1]!)
          .toSet();
      expect(modes, isNotEmpty);
      expect(
        WidgetCount.values.map((c) => c.name),
        containsAll(modes),
      );
    });
  });
}

/// Whether a value Dart sends can be read as [type] by `call.argument<T>`.
bool _fits(Object? value, String type) {
  final t = type.replaceAll(' ', '');
  if (value == null) return true;
  if (value is bool) return t == 'Boolean';
  if (value is String) return t == 'String';
  if (value is int) {
    // An int past 32 bits arrives as a Long, which an Int read cannot take.
    final wide = value > 0x7fffffff || value < -0x80000000;
    return t == 'Number' || t == 'Long' || (t == 'Int' && !wide);
  }
  if (value is double) return t == 'Number' || t == 'Double';
  if (value is List) {
    final element = RegExp(r'^List<(.+)>$').firstMatch(t)?[1];
    if (element == null) return false;
    return value.every((e) =>
        e == null ? element.endsWith('?') : _fits(e, element.replaceAll('?', '')));
  }
  return false;
}

class _Read {
  const _Read(this.type, {required this.required});
  final String type;
  final bool required;
}

/// What the Kotlin half says, read from its source.
class _Kotlin {
  /// Channel, then method, then the arguments that method reads.
  final handled = <String, Map<String, Map<String, _Read>>>{};

  /// Channel, then the methods Kotlin calls on the Dart side.
  final invoked = <String, Set<String>>{};

  /// The keys of a file handed to Dart, of a drop and of a share.
  Set<String> fileKeys = {};
  Set<String> droppedKeys = {};
  Set<String> sharedKeys = {};

  static _Kotlin read(Directory dir) {
    final k = _Kotlin();
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.endsWith('.kt')) k._readFile(f.readAsStringSync());
    }
    return k;
  }

  void _readFile(String src) {
    // Names that stand for a channel: `const val CHANNEL = "mailtree/..."`.
    final names = <String, String>{
      for (final m in RegExp(r'val\s+(\w+)\s*=\s*"(mailtree/[\w-]+)"')
          .allMatches(src))
        m[1]!: m[2]!,
    };
    String? channelIn(String text) {
      final literal = RegExp(r'"(mailtree/[\w-]+)"').firstMatch(text);
      if (literal != null) return literal[1];
      for (final MapEntry(:key, :value) in names.entries) {
        if (RegExp('\\b$key\\b').hasMatch(text)) return value;
      }
      return null;
    }

    // Which variable holds which channel, for the calls into Dart.
    final holders = <String, String>{};
    for (final m in RegExp(r'(\w+)\s*=\s*MethodChannel\(([^)]*)\)')
        .allMatches(src)) {
      final channel = channelIn(m[2]!);
      if (channel != null) holders[m[1]!] = channel;
    }

    // One handler per MethodChannel(...): it runs to the next one.
    final starts = [
      for (final m in RegExp(r'MethodChannel\(').allMatches(src)) m.start,
    ];
    for (final (i, start) in starts.indexed) {
      final end = i + 1 < starts.length ? starts[i + 1] : src.length;
      final channel = channelIn(src.substring(start, (start + 200).clamp(0, end)));
      if (channel == null) continue;
      final body = src.substring(start, end);
      final methods = handled.putIfAbsent(channel, () => {});
      final cases = RegExp(r'"(\w+)"\s*->').allMatches(body).toList();
      for (final (j, c) in cases.indexed) {
        final to = j + 1 < cases.length ? cases[j + 1].start : body.length;
        final reads = methods.putIfAbsent(c[1]!, () => {});
        for (final a in RegExp(r'call\.argument<(.+?)>\("(\w+)"\)(!!)?')
            .allMatches(body.substring(c.end, to))) {
          reads[a[2]!] = _Read(a[1]!, required: a[3] != null);
        }
      }
    }

    for (final m in RegExp(r'(\w+)\??\.invokeMethod\(\s*"(\w+)"').allMatches(src)) {
      final channel = holders[m[1]!] ??
          (names.length == 1 ? names.values.single : null);
      if (channel != null) invoked.putIfAbsent(channel, () => {}).add(m[2]!);
    }

    Set<String> keysAfter(RegExp marker) {
      final at = marker.firstMatch(src);
      if (at == null) return {};
      final block = src.substring(at.end, (at.end + 600).clamp(0, src.length));
      final close = _closingParen(block);
      return {
        for (final m in RegExp(r'"(\w+)"\s+to\b').allMatches(block.substring(0, close)))
          m[1]!,
      };
    }

    if (src.contains('class FilesBridge')) {
      droppedKeys = keysAfter(RegExp(r'invokeMethod\(\s*"dropped",\s*mapOf\('));
      sharedKeys = keysAfter(RegExp(r'val share = mapOf\('));
      fileKeys = keysAfter(RegExp(r'mapOf\((?=\s*"path" to)'));
    }
  }

  /// Where the bracket opened just before [text] closes.
  static int _closingParen(String text) {
    var depth = 1;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '(') depth++;
      if (text[i] == ')' && --depth == 0) return i;
    }
    return text.length;
  }
}
