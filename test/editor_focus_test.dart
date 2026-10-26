import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/compose/html_editor.dart';

/// The message editor's page and the fields around it share one cursor.
///
/// On Ron's tablet a tap in the message left the cursor in the field above
/// as well, two cursors that did not look alike, and what the keyboard
/// typed went on into the field (3.6.1): the WebView plugin never passes
/// Android's focus going to the page on to Flutter's. Android is played
/// here by its two channels: the platform views', which tells Flutter the
/// page was focused, and the editor bridge's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bridge = <MethodCall>[];
  int? viewId;

  setUp(() {
    bridge.clear();
    viewId = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views,
        (call) async {
      switch (call.method) {
        case 'create':
          viewId = (call.arguments as Map)['id'] as int;
          // A texture: Android drew it in a layer of Flutter's.
          return 1;
        case 'resize':
          final args = call.arguments as Map;
          return {'width': args['width'], 'height': args['height']};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('mailtree/editor'),
        (call) async {
      bridge.add(call);
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('mailtree/editor'), null);
  });

  /// A field above the page, with the cursor, as Subject is.
  Future<(FocusNode, FocusNode)> pump(WidgetTester tester) async {
    final field = FocusNode();
    final page = FocusNode(skipTraversal: true);
    addTearDown(field.dispose);
    addTearDown(page.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextField(focusNode: field, autofocus: true),
            Expanded(child: EditorPage(webView: 7, focusNode: page)),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(viewId, isNotNull, reason: 'the page was made');
    expect(field.hasFocus, isTrue);
    return (field, page);
  }

  /// Android's focus going to the page: a tap in it, or the bridge.
  Future<void> androidFocusesThePage(WidgetTester tester) async {
    await messenger.handlePlatformMessage(
      SystemChannels.platform_views.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall('viewFocused', viewId)),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  List<String> said(String method) => [
        for (final c in bridge)
          if (c.method == method) '${(c.arguments as Map)['webView']}',
      ];

  testWidgets('a tap in the message takes the cursor from the field, and '
      'the keyboard is the page\'s', (tester) async {
    final (field, page) = await pump(tester);
    tester.testTextInput.log.clear();

    await androidFocusesThePage(tester);

    expect(page.hasFocus, isTrue);
    expect(field.hasFocus, isFalse, reason: 'one cursor, not two');
    final told = tester.testTextInput.log
        .where((c) => c.method == 'TextInput.setPlatformViewClient')
        .toList();
    expect(told, isNotEmpty);
    expect((told.last.arguments as Map)['platformViewId'], viewId);
    expect(said('focus'), ['7'], reason: 'and Android\'s focus with it');
    expect(said('blur'), isEmpty);
  });

  testWidgets('the arrows and the rest are left for the page', (tester) async {
    final (_, page) = await pump(tester);
    await androidFocusesThePage(tester);

    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
    ]) {
      // Not handled here, so Android hands it on to the page.
      expect(await tester.sendKeyEvent(key), isFalse, reason: '$key');
      await tester.pumpAndSettle();
      expect(page.hasFocus, isTrue,
          reason: '$key did not move the focus off the page');
    }
  });

  testWidgets('back in a field, the page lets go of Android\'s focus',
      (tester) async {
    final (field, page) = await pump(tester);
    await androidFocusesThePage(tester);
    expect(said('blur'), isEmpty);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(field.hasFocus, isTrue);
    expect(page.hasFocus, isFalse);
    expect(said('blur'), ['7']);
  });

  testWidgets('a menu in front leaves the page Android\'s focus, and the '
      'keyboard', (tester) async {
    final (_, page) = await pump(tester);
    await androidFocusesThePage(tester);

    final context = tester.element(find.byType(EditorPage));
    final menu = showDialog<void>(
      context: context,
      builder: (dialog) => TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(dialog).pop(),
        child: const Text('Bold'),
      ),
    );
    await tester.pumpAndSettle();
    expect(page.hasFocus, isFalse);
    expect(said('blur'), isEmpty);

    await tester.tap(find.text('Bold'));
    await tester.pumpAndSettle();
    await menu;
    expect(page.hasFocus, isTrue, reason: 'given back as it closed');
    expect(said('blur'), isEmpty);
  });

  testWidgets('given the focus by Flutter, the page asks Android for it too',
      (tester) async {
    final (field, page) = await pump(tester);

    page.requestFocus();
    await tester.pumpAndSettle();

    expect(field.hasFocus, isFalse);
    expect(said('focus'), ['7']);
  });
}
