import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/quick_step.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/quick_steps.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/ribbon.dart';

import 'fakes/fake_webview.dart';
import 'helpers/landing.dart';

const _landscapeTablet = Size(1400, 900);
const _portraitTablet = Size(800, 1280);
const _phone = Size(400, 900);

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Every command the ribbon offers, in the order they appear.
const _labels = [
  'Sync',
  'New email',
  'Delete',
  'Reply',
  'Reply all',
  'Forward',
  'Quick Steps',
  'Move',
  'Search',
];

void main() {
  late MemoryUiStateStore store;

  setUp(() {
    store = MemoryUiStateStore();
    FakeWebViewPlatform.install();
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
    _useSize(tester, size);
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  /// A ribbon button by its label, not by any text elsewhere on screen.
  Finder button(String label) =>
      find.descendant(of: find.byType(Ribbon), matching: find.text(label));

  bool isEnabled(WidgetTester tester, String label) {
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: button(label), matching: find.byType(InkWell)).first,
    );
    return inkWell.onTap != null;
  }

  group('where the ribbon appears', () {
    testWidgets('on a tablet in landscape', (tester) async {
      await pump(tester, _landscapeTablet);
      expect(find.byType(Ribbon), findsOneWidget);
    });

    testWidgets('not on a tablet in portrait', (tester) async {
      // Two panes and no room for a command bar across the top.
      await pump(tester, _portraitTablet);
      expect(find.byType(Ribbon), findsNothing);
    });

    testWidgets('not on a phone, where these actions live under the thumb',
        (tester) async {
      await pump(tester, _phone);
      expect(find.byType(Ribbon), findsNothing);
    });
  });

  group('what it offers', () {
    testWidgets('every command, each with a label under its icon',
        (tester) async {
      await pump(tester, _landscapeTablet);

      for (final label in _labels) {
        expect(button(label), findsOneWidget, reason: label);
      }
      // Read and Unread are the same button showing one of two states.
      expect(button('Read'), findsOneWidget);
    });

    testWidgets('the message commands are disabled until one is selected',
        (tester) async {
      final c = await pump(tester, _landscapeTablet);

      // Opening a folder lands on a message, so the state this is about —
      // nothing selected — is what a folder with no mail in it leaves behind.
      await goToEmptyFolder(tester, c);

      // Greyed rather than hidden: a bar whose buttons come and go as you
      // click around the list is harder to aim at.
      for (final label in ['Delete', 'Reply', 'Reply all', 'Forward', 'Move']) {
        expect(isEnabled(tester, label), isFalse, reason: label);
      }
      expect(isEnabled(tester, 'Sync'), isTrue);
      expect(isEnabled(tester, 'New email'), isTrue);
      expect(isEnabled(tester, 'Search'), isTrue);
    });

    testWidgets('selecting a message enables them', (tester) async {
      await pump(tester, _landscapeTablet);

      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();

      for (final label in ['Delete', 'Reply', 'Reply all', 'Forward', 'Move']) {
        expect(isEnabled(tester, label), isTrue, reason: label);
      }
    });
  });

  group('what the commands do', () {
    testWidgets('Read and Unread is one button that says what it will do',
        (tester) async {
      final c = await pump(tester, _landscapeTablet);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();

      // Whatever state it is in, the button offers the other one, because
      // that is what pressing it does.
      final wasRead = c.read(selectedMessageProvider)!.isRead;
      final offered = wasRead ? 'Unread' : 'Read';
      expect(button(offered), findsOneWidget);
      expect(button(wasRead ? 'Read' : 'Unread'), findsNothing);

      await tester.tap(button(offered));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageProvider)!.isRead, !wasRead);
      expect(button(wasRead ? 'Read' : 'Unread'), findsOneWidget,
          reason: 'and now it offers the other direction');
    });

    testWidgets('Delete takes that message out of the list', (tester) async {
      // By subject, not by counting rows: the list is longer than the screen,
      // so removing one only pulls the next one up and the count is unchanged.
      await pump(tester, _landscapeTablet);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final subject = tester
          .widget<MessageTile>(find.byType(MessageTile).first)
          .message
          .subject;

      await tester.tap(button('Delete'));
      await tester.pumpAndSettle();

      final remaining = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .map((t) => t.message.subject);
      expect(remaining, isNot(contains(subject)));
    });

    testWidgets('Move opens the destination sheet', (tester) async {
      await pump(tester, _landscapeTablet);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();

      await tester.tap(button('Move'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('Search puts the cursor in the search box', (tester) async {
      // The ribbon has no field of its own; it asks the list's box for focus.
      await pump(tester, _landscapeTablet);
      final field = find.widgetWithText(TextField, 'Search mail').first;
      expect(
        tester.widget<TextField>(field).focusNode?.hasFocus ?? false,
        isFalse,
      );

      await tester.tap(button('Search'));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    });

    testWidgets('Search works a second time', (tester) async {
      // A flag that is already set reports no change, which is why the
      // request is a counter.
      await pump(tester, _landscapeTablet);
      final field = find.widgetWithText(TextField, 'Search mail').first;

      await tester.tap(button('Search'));
      await tester.pumpAndSettle();
      tester.widget<TextField>(field).focusNode?.unfocus();
      await tester.pumpAndSettle();

      await tester.tap(button('Search'));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    });

    testWidgets('Sync spins while it runs and comes back', (tester) async {
      await pump(tester, _landscapeTablet);

      await tester.tap(button('Sync'));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(Ribbon),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      expect(isEnabled(tester, 'Sync'), isTrue);
    });
  });

  group('Quick Steps', () {
    testWidgets('with none set up it offers to set them up', (tester) async {
      // Enabled even with nothing selected, because otherwise the only route
      // to creating one is hidden behind selecting a message first.
      await pump(tester, _landscapeTablet);

      expect(isEnabled(tester, 'Quick Steps'), isTrue);
      await tester.tap(button('Quick Steps'));
      await tester.pumpAndSettle();

      expect(find.text('Set up Quick Steps'), findsOneWidget);
    });

    testWidgets('lists the ones there are and applies the chosen one',
        (tester) async {
      final c = container();
      c.read(quickStepsProvider.notifier).add(
            const QuickStep(
              id: 'qs1',
              name: 'Read it',
              actions: [QuickStepAction(QuickStepActionType.markRead)],
            ),
          );
      _useSize(tester, _landscapeTablet);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(MessageTile).at(1));
      await tester.pumpAndSettle();
      await tester.tap(button('Quick Steps'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Read it'), findsOneWidget);
      await tester.tap(find.textContaining('Read it'));
      await tester.pumpAndSettle();

      expect(find.text('Read it applied'), findsOneWidget);
    });
  });
}
