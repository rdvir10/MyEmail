import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/view_settings_screen.dart';

/// Choosing what a swipe does, in each direction.
void main() {
  late MemoryUiStateStore store;

  setUp(() => store = MemoryUiStateStore());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('the setting', () {
    test('defaults to what the list already did', () {
      // Right moved and left deleted before either was configurable. Anything
      // else here would change behaviour for an existing install on upgrade,
      // silently, on a destructive gesture.
      const settings = DisplaySettings();

      expect(settings.swipeRight, SwipeAction.move);
      expect(settings.swipeLeft, SwipeAction.delete);
    });

    test('survives a round trip through storage', () {
      const settings = DisplaySettings(
        swipeRight: SwipeAction.archive,
        swipeLeft: SwipeAction.toggleRead,
      );

      final restored = DisplaySettings.fromJson(settings.toJson());

      expect(restored.swipeRight, SwipeAction.archive);
      expect(restored.swipeLeft, SwipeAction.toggleRead);
      expect(restored, settings);
    });

    test('settings written before swipes existed keep the old behaviour', () {
      // An upgrade reads a record with neither key in it. Falling back to
      // anything other than the previous behaviour would rearrange a gesture
      // under someone mid-use.
      final old = DisplaySettings.fromJson(const {
        'readingPane': 'bottom',
        'density': 'compact',
        'conversations': true,
      });

      expect(old.swipeRight, SwipeAction.move);
      expect(old.swipeLeft, SwipeAction.delete);
      expect(old.readingPane, ReadingPanePosition.bottom);
    });

    test('a value from a newer build falls back rather than failing', () {
      final forward = DisplaySettings.fromJson(const {
        'swipeRight': 'teleport',
        'swipeLeft': 'archive',
      });

      expect(forward.swipeRight, SwipeAction.move);
      expect(forward.swipeLeft, SwipeAction.archive);
    });

    test('the two directions are independent', () {
      final c = container();
      final notifier = c.read(displayProvider.notifier);

      notifier.setSwipeLeft(SwipeAction.toggleFlag);

      expect(c.read(displayProvider).swipeLeft, SwipeAction.toggleFlag);
      expect(c.read(displayProvider).swipeRight, SwipeAction.move,
          reason: 'setting one direction must not reset the other');
    });

    test('a change is persisted at once', () {
      final c = container();

      c.read(displayProvider.notifier).setSwipeRight(SwipeAction.none);

      final reread = container();
      expect(reread.read(displayProvider).swipeRight, SwipeAction.none);
    });
  });

  group('the View screen', () {
    testWidgets('offers both directions', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container(),
          child: const MaterialApp(home: ViewSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Swipe actions'), 200);

      expect(find.text('Swipe right'), findsOneWidget);
      expect(find.text('Swipe left'), findsOneWidget);
    });

    testWidgets('choosing an action saves it', (tester) async {
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: ViewSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Swipe right'), 200);

      // Two dropdowns carry the same item labels, so the tap has to be
      // scoped to the row it belongs to.
      final rightRow = find.ancestor(
        of: find.text('Swipe right'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: rightRow, matching: find.byType(DropdownButton<SwipeAction>)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(SwipeAction.archive.label).last);
      await tester.pumpAndSettle();

      expect(c.read(displayProvider).swipeRight, SwipeAction.archive);
    });

    testWidgets('the summary line says what the swipes are set to',
        (tester) async {
      final c = container();
      c.read(displayProvider.notifier).setSwipeLeft(SwipeAction.archive);

      late String summary;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (_, ref, _) {
                summary = const ViewSummary().text(ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(summary, contains('archive'));
    });
  });
}
