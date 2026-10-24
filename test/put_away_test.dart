import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/put_away_providers.dart';
import 'package:myemail/state/search_providers.dart';
import 'package:myemail/ui/accounts/add_account_screen.dart';
import 'package:myemail/ui/settings/settings_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/put_away.dart';

import 'fakes/fake_webview.dart';

/// Put away (Home, another app), the app closes what was open over the mail,
/// so it comes back to the Inbox rather than to wherever it was left.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const inbox = 'acct-personal:INBOX';
  const sent = 'acct-personal:[Gmail]/Sent Mail';

  group('the Inbox it comes back to', () {
    late Map<String, MailFolder> index;

    setUp(() async {
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
      );
      addTearDown(c.dispose);
      await c.read(accountsProvider.future);
      await c.read(foldersProvider.future);
      index = c.read(folderIndexProvider);
    });

    test('an Inbox, or All Inboxes, stays', () {
      expect(inboxToComeBackTo(inbox, index), inbox);
      expect(inboxToComeBackTo(kUnifiedInboxId, index), kUnifiedInboxId);
    });

    test("any other folder goes to its own account's Inbox", () {
      expect(inboxToComeBackTo(sent, index), inbox);
    });

    test('a folder that is not there leaves the choice alone', () {
      expect(inboxToComeBackTo('gone:folder', index), isNull);
      expect(inboxToComeBackTo(null, index), isNull);
    });
  });

  group('closing what was open', () {
    late PutAwayGuards guards;
    late BuildContext root;

    Future<void> pumpRoot(WidgetTester tester) async {
      guards = PutAwayGuards();
      await tester.pumpWidget(ProviderScope(
        overrides: [putAwayGuardsProvider.overrideWithValue(guards)],
        child: MaterialApp(
          home: Builder(builder: (context) {
            root = context;
            return Scaffold(
              drawer: const Drawer(child: Text('folders')),
              body: const Text('the mail'),
            );
          }),
        ),
      ));
    }

    Future<bool> close(WidgetTester tester) async {
      bool? all;
      unawaited(closeForPutAway(
        tester.state<NavigatorState>(find.byType(Navigator)),
        guards,
      ).then((a) => all = a));
      await tester.pumpAndSettle();
      return all!;
    }

    void push(Widget screen) => Navigator.of(root)
        .push(MaterialPageRoute<void>(builder: (_) => screen));

    testWidgets('screens, a dialog and a sheet all go', (tester) async {
      await pumpRoot(tester);
      push(const Scaffold(body: Text('settings')));
      push(const Scaffold(body: Text('view settings')));
      await tester.pumpAndSettle();
      unawaited(showDialog<void>(
          context: tester.element(find.text('view settings')),
          builder: (_) => const AlertDialog(content: Text('a question'))));
      await tester.pumpAndSettle();
      unawaited(showModalBottomSheet<void>(
          context: tester.element(find.text('a question')),
          builder: (_) => const Text('a menu')));
      await tester.pumpAndSettle();

      expect(await close(tester), isTrue);

      for (final gone in ['settings', 'view settings', 'a question', 'a menu']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.text('the mail'), findsOneWidget);
    });

    testWidgets('the folder drawer closes, and the mail stays',
        (tester) async {
      await pumpRoot(tester);
      Scaffold.of(tester.element(find.text('the mail'))).openDrawer();
      await tester.pumpAndSettle();
      expect(find.text('folders'), findsOneWidget);

      expect(await close(tester), isTrue);

      expect(find.text('folders'), findsNothing);
      expect(find.text('the mail'), findsOneWidget);
    });

    testWidgets('a screen that stays keeps the ones under it, not above',
        (tester) async {
      await pumpRoot(tester);
      push(const Scaffold(body: Text('accounts')));
      push(const StaysWhenPutAway(child: Scaffold(body: Text('signing in'))));
      push(const Scaffold(body: Text('help')));
      await tester.pumpAndSettle();

      expect(await close(tester), isFalse);

      expect(find.text('help'), findsNothing);
      expect(find.text('signing in'), findsOneWidget);
      // Under it, still there to go back to.
      expect(Navigator.of(tester.element(find.text('signing in'))).canPop(),
          isTrue);
    });

    testWidgets('one that stays only while it holds something',
        (tester) async {
      await pumpRoot(tester);
      var typed = false;
      push(StaysWhenPutAway(
        stays: () => typed,
        child: const Scaffold(body: Text('edit account')),
      ));
      await tester.pumpAndSettle();

      expect(await close(tester), isTrue);
      expect(find.text('edit account'), findsNothing);

      typed = true;
      push(StaysWhenPutAway(
        stays: () => typed,
        child: const Scaffold(body: Text('edit account')),
      ));
      await tester.pumpAndSettle();
      expect(await close(tester), isFalse);
      expect(find.text('edit account'), findsOneWidget);
    });
  });

  group('the app', () {
    late StreamController<void> putAway;
    late ProviderContainer c;

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      putAway = StreamController<void>.broadcast();
      addTearDown(putAway.close);
      c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        appPutAwayProvider.overrideWithValue(putAway.stream),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
    }

    void push(WidgetTester tester, Widget screen) =>
        tester.state<NavigatorState>(find.byType(Navigator)).push(
              MaterialPageRoute<void>(builder: (_) => screen),
            );

    testWidgets('comes back to the Inbox, Settings closed, search put away',
        (tester) async {
      await pumpApp(tester);
      c.read(selectedFolderIdProvider.notifier).select(sent);
      c.read(searchOpenProvider.notifier).open();
      push(tester, const SettingsScreen());
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      putAway.add(null);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsNothing);
      expect(c.read(effectiveSelectedFolderIdProvider), inbox);
      expect(c.read(searchOpenProvider), isFalse);
    });

    testWidgets('back while a screen was still closing, everything stays',
        (tester) async {
      // A message being written takes seconds to save on the way out. Back
      // within them, the screen was taken away and the list reset under
      // the person, who was by then looking at it.
      await pumpApp(tester);
      c.read(selectedFolderIdProvider.notifier).select(sent);
      c.read(searchOpenProvider.notifier).open();
      final saved = Completer<void>();
      push(tester, _SlowToClose(saved.future));
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }

      putAway.add(null);
      await tester.pump();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      saved.complete();
      await tester.pumpAndSettle();

      expect(find.text('still saving'), findsOneWidget);
      expect(c.read(effectiveSelectedFolderIdProvider), sent);
      expect(c.read(searchOpenProvider), isTrue);
      // Back in front, the app asks for its folders again; its answer is
      // let in before the test ends.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a sign-in under way is left for the person to finish',
        (tester) async {
      // Microsoft's is approved in the Authenticator app, and an app
      // password is made in the browser: leaving is part of signing in.
      await pumpApp(tester);
      push(tester, const AddAccountScreen());
      await tester.pumpAndSettle();

      putAway.add(null);
      await tester.pumpAndSettle();

      expect(find.byType(AddAccountScreen), findsOneWidget);
    });
  });
}

/// A screen that may close once [saved] is done, the way one that saves
/// first does.
class _SlowToClose extends ConsumerStatefulWidget {
  const _SlowToClose(this.saved);

  final Future<void> saved;

  @override
  ConsumerState<_SlowToClose> createState() => _SlowToCloseState();
}

class _SlowToCloseState extends ConsumerState<_SlowToClose>
    with GuardsPutAway<_SlowToClose> {
  @override
  Future<bool> whenPutAway() async {
    await widget.saved;
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('still saving'));
}
