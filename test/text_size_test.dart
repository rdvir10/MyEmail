import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/common/text_size.dart';
import 'package:myemail/ui/compose/html_editor.dart';
import 'package:myemail/ui/messages/html_body_view.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/settings/settings_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Settings, View, Text size: everything the app writes, message bodies
/// and what is being written included, on top of Android's own size.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late MemoryUiStateStore store;
  setUp(() => store = MemoryUiStateStore());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// The app as main.dart builds it: the size is applied above the
  /// navigator.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: (context, child) => AppTextSize(child: child!),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  /// Android's own font size, as the phone would report it.
  void androidFontScale(WidgetTester tester, double scale) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  group('the setting', () {
    test('is kept, and read back', () {
      const settings = DisplaySettings(textSize: TextSize.large);
      expect(DisplaySettings.fromJson(settings.toJson()), settings);
      expect(settings, isNot(const DisplaySettings()),
          reason: 'a change that compares equal would never be noticed');
    });

    test("starts at Android's own size, and survives a value it does not know",
        () {
      expect(const DisplaySettings().textSize, TextSize.standard);
      expect(TextSize.standard.factor, 1.0);
      expect(
        DisplaySettings.fromJson({'textSize': 'enormous'}).textSize,
        TextSize.standard,
      );
    });

    test('a record written by 2.44.0 still reads', () {
      // It carried showRecipientDetails, which is no longer a setting.
      final settings = DisplaySettings.fromJson({
        'density': 'compact',
        'showRecipientDetails': true,
      });
      expect(settings.density, ListDensity.compact);
      expect(settings.textSize, TextSize.standard);
    });
  });

  group('text across the app', () {
    testWidgets("multiplies Android's size, and at Default leaves it alone",
        (tester) async {
      androidFontScale(tester, 1.2);
      late TextScaler scaler;
      final c = await pumpApp(
        tester,
        Builder(builder: (context) {
          scaler = MediaQuery.textScalerOf(context);
          return const Text('x');
        }),
      );
      expect(scaler.scale(10), closeTo(12, 0.001));

      c.read(displayProvider.notifier).setTextSize(TextSize.large);
      await tester.pumpAndSettle();
      expect(scaler.scale(10), closeTo(13.8, 0.001),
          reason: '1.2 from Android, times 1.15');

      c.read(displayProvider.notifier).setTextSize(TextSize.standard);
      await tester.pumpAndSettle();
      expect(scaler.scale(10), closeTo(12, 0.001));
    });

    testWidgets('the View screen offers it, drawn at the size being chosen',
        (tester) async {
      final c = await pumpApp(tester, const SettingsScreen());
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();

      expect(find.text('Text size'), findsOneWidget);
      for (final size in TextSize.values) {
        expect(find.text(size.label), findsOneWidget);
      }
      final before = tester.getSize(find.text('Extra large')).height;

      await tester.tap(find.text('Extra large'));
      await tester.pumpAndSettle();

      expect(c.read(displayProvider).textSize, TextSize.extraLarge);
      expect(tester.getSize(find.text('Extra large')).height,
          closeTo(before * 1.3, 0.5));
      expect(
        jsonDecode(store.readString(UiStateKeys.display)!)['textSize'],
        'extraLarge',
        reason: 'still there tomorrow',
      );
    });

    testWidgets('the hub says so when it is not the default', (tester) async {
      final c = await pumpApp(tester, const SettingsScreen());
      expect(find.textContaining('text,'), findsNothing);

      c.read(displayProvider.notifier).setTextSize(TextSize.large);
      await tester.pumpAndSettle();
      expect(find.textContaining('large text,'), findsOneWidget);
    });
  });

  group('message bodies and what is being written', () {
    late List<int> zooms;
    setUp(() {
      zooms = [];
      debugWebTextZoom = (_, zoom) => zooms.add(zoom);
    });
    tearDown(() => debugWebTextZoom = null);

    test('the zoom is Android’s scale times the setting, in percent', () {
      expect(webTextZoom(androidFontScale: 1.0, factor: 1.0), 100);
      expect(webTextZoom(androidFontScale: 1.3, factor: 1.15), 150);
      expect(webTextZoom(androidFontScale: 1.0, factor: 0.9), 90);
    });

    testWidgets("a body keeps the WebView's own size until the setting moves",
        (tester) async {
      // The WebView starts at Android's size by itself; left alone at
      // Default, a message looks exactly as it did before this setting.
      androidFontScale(tester, 1.2);
      final c = await pumpApp(
        tester,
        const Scaffold(
          body: SizedBox(height: 400, child: HtmlBodyView(html: '<p>Hi</p>')),
        ),
      );
      expect(zooms, isEmpty);

      c.read(displayProvider.notifier).setTextSize(TextSize.large);
      await tester.pumpAndSettle();
      expect(zooms, [138]);

      c.read(displayProvider.notifier).setTextSize(TextSize.standard);
      await tester.pumpAndSettle();
      expect(zooms, [138, 120], reason: "back to Android's own size");
    });

    testWidgets('a body opened at a larger size starts at it', (tester) async {
      store.writeString(
        UiStateKeys.display,
        jsonEncode(const DisplaySettings(textSize: TextSize.small).toJson()),
      );
      await pumpApp(
        tester,
        const Scaffold(
          body: SizedBox(height: 400, child: HtmlBodyView(html: '<p>Hi</p>')),
        ),
      );
      expect(zooms, [90]);
    });

    testWidgets('what is being written is sized the same', (tester) async {
      final editor = HtmlEditorController(initialHtml: '<p></p>');
      addTearDown(editor.dispose);
      final c = await pumpApp(
        tester,
        Scaffold(
          body: SizedBox(height: 400, child: HtmlEditor(controller: editor)),
        ),
      );
      expect(zooms, isEmpty);

      c.read(displayProvider.notifier).setTextSize(TextSize.extraLarge);
      await tester.pumpAndSettle();
      expect(zooms, [130]);
    });
  });

  group('the largest size', () {
    // Android's own size a notch up as well, so this is more than anyone
    // here is likely to use. An overflow anywhere is an error the test
    // framework reports in full, and it fails the test.
    for (final (where, size) in [
      ('a phone', const Size(412, 915)),
      ('a tablet', const Size(1280, 800)),
    ]) {
      testWidgets('fits on $where, list and message', (tester) async {
        androidFontScale(tester, 1.15);
        store.writeString(
          UiStateKeys.display,
          jsonEncode(
            const DisplaySettings(textSize: TextSize.extraLarge).toJson(),
          ),
        );
        await pumpApp(tester, const AppShell(), size: size);
        expect(find.byType(MessageTile), findsWidgets);

        await tester.tap(find.byType(MessageTile).first);
        await tester.pumpAndSettle();
        expect(find.byType(ReadingPane), findsOneWidget);
      });
    }

    void largest(WidgetTester tester) {
      androidFontScale(tester, 1.15);
      store.writeString(
        UiStateKeys.display,
        jsonEncode(
          const DisplaySettings(textSize: TextSize.extraLarge).toJson(),
        ),
      );
    }

    testWidgets('fits on a phone, every Settings screen', (tester) async {
      largest(tester);
      await pumpApp(tester, const SettingsScreen(), size: const Size(412, 915));

      for (final entry in [
        'View',
        'Sync',
        'Notifications',
        'Home screen widgets',
        'Quick Steps',
        'Keyboard shortcuts',
        'Accounts',
        'Signatures',
        'Backup',
        'About',
      ]) {
        // Last: Accounts is a heading as well as the row under it.
        final row = find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.text(entry),
            )
            .last;
        await tester.scrollUntilVisible(row, 200,
            scrollable: find.byType(Scrollable).first);
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        final before = navigator.canPop();
        await tester.tap(row);
        // Long enough for the page to arrive and lay out, which is when an
        // overflow shows. Not until settled: some screens wait on a
        // platform that is not here, behind a spinner that never stops.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(navigator.canPop(), isTrue, reason: '$entry opened something');
        expect(before, isFalse);
        // A page or a sheet alike: whatever is on top goes.
        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('fits on a phone, the folder drawer and a new message',
        (tester) async {
      largest(tester);
      await pumpApp(tester, const AppShell(), size: const Size(412, 915));

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      Navigator.of(tester.element(find.text('Settings').first)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New message'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlEditor), findsOneWidget);
    });
  });
}
