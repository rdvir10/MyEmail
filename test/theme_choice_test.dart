import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/main.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/about_screen.dart';
import 'package:myemail/ui/settings/settings_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';
import 'help_screen_test.dart' show open;

/// Settings, View, Theme: light, dark, or as Android is.
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

  void useSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Android's own dark theme setting.
  void androidIn(WidgetTester tester, Brightness brightness) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  group('the setting', () {
    test('follows Android until chosen otherwise', () {
      expect(const DisplaySettings().theme, ThemeChoice.system);
      expect(DisplaySettings.fromJson({}).theme, ThemeChoice.system,
          reason: 'a record from before there was a choice');
      expect(DisplaySettings.fromJson({'theme': 'sepia'}).theme,
          ThemeChoice.system);
    });

    test('is kept, and read back', () {
      const settings = DisplaySettings(theme: ThemeChoice.dark);
      expect(DisplaySettings.fromJson(settings.toJson()), settings);
      expect(settings, isNot(const DisplaySettings()),
          reason: 'a change that compares equal would never be noticed');
    });
  });

  testWidgets('the whole app follows it, whatever Android is in',
      (tester) async {
    useSize(tester);
    androidIn(tester, Brightness.dark);
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const MyEmailApp()),
    );
    await tester.pumpAndSettle();
    Brightness shown() =>
        Theme.of(tester.element(find.byType(AppShell))).brightness;

    expect(shown(), Brightness.dark, reason: 'System default is Android');

    c.read(displayProvider.notifier).setTheme(ThemeChoice.light);
    await tester.pumpAndSettle();
    expect(shown(), Brightness.light);

    androidIn(tester, Brightness.light);
    c.read(displayProvider.notifier).setTheme(ThemeChoice.dark);
    await tester.pumpAndSettle();
    expect(shown(), Brightness.dark);
  });

  testWidgets('the View screen offers all three and keeps the choice',
      (tester) async {
    useSize(tester);
    final c = container();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('theme,'), findsNothing,
        reason: 'the hub says nothing of it at System default');

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('Theme'), findsOneWidget);
    for (final choice in ThemeChoice.values) {
      expect(find.text(choice.label), findsOneWidget);
    }

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(c.read(displayProvider).theme, ThemeChoice.dark);
    expect(
      jsonDecode(store.readString(UiStateKeys.display)!)['theme'],
      'dark',
      reason: 'still there tomorrow',
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('Dark theme, reading pane right'),
        findsOneWidget);
  });

  testWidgets("Help opens in the app's theme, not Android's", (tester) async {
    useSize(tester);
    androidIn(tester, Brightness.dark);
    final platform = FakeWebViewPlatform.install();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container(),
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: ThemeMode.light,
        home: const AboutScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await open(tester, find.text('User manual'));
    expect(platform.loadedHtml.last, contains('@media (monochrome)'),
        reason: 'its dark rules never apply in a light app');
    expect(platform.loadedHtml.last, isNot(contains('prefers-color-scheme')));
  });
}
