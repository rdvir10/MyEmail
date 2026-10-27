import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/print/message_printer.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/print_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/threat_check_sheet.dart';
import 'package:myemail/ui/settings/rules_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// A message's menu in the list, from a right click or a hold (3.7.0):
/// Reply, Reply all, Forward and Delete as icons across its top, what is
/// done most by name, and the rest under More, so it fits on the screen.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late FakeMessagePrinter printer;
  setUp(() => printer = FakeMessagePrinter());

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      messagePrinterProvider.overrideWithValue(printer),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: AppShell()),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  MailMessage first(WidgetTester tester) =>
      tester.widget<MessageTile>(find.byType(MessageTile).first).message;

  Finder entry(String text) => find.widgetWithText(PopupMenuItem<String>, text);

  Future<void> rightClick(WidgetTester tester, MailMessage m) async {
    await tester.tap(find.byKey(ValueKey('tile:${m.id}')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  Future<void> fromMore(WidgetTester tester, String text) async {
    await tester.tap(entry('More'));
    await tester.pumpAndSettle();
    await tester.tap(entry(text));
    await tester.pumpAndSettle();
  }

  testWidgets('held on a phone, it is all on the screen at once',
      (tester) async {
    await pump(tester, size: const Size(400, 800));
    final m = first(tester);

    await tester.longPress(find.byKey(ValueKey('tile:${m.id}')));
    await tester.pumpAndSettle();

    final menu = find.ancestor(
      of: entry('More'),
      matching: find.byType(Scrollable),
    );
    expect(tester.state<ScrollableState>(menu.first).position.maxScrollExtent,
        0,
        reason: 'nothing to scroll to: More at the bottom is in sight');
    expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
  });

  testWidgets('Reply is the first icon across the top', (tester) async {
    await pump(tester);
    final m = first(tester);

    await rightClick(tester, m);
    await tester.tap(find.byKey(const ValueKey('menu-reply')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final draft = tester.widget<ComposeScreen>(find.byType(ComposeScreen)).draft;
    expect(draft.kind, ComposeKind.reply);
  });

  testWidgets('Delete is the last, and takes the message', (tester) async {
    await pump(tester);
    final m = first(tester);

    await rightClick(tester, m);
    await tester.tap(find.byKey(const ValueKey('menu-delete')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('tile:${m.id}')), findsNothing);
  });

  testWidgets('the seldom ones wait under More', (tester) async {
    await pump(tester);
    await rightClick(tester, first(tester));
    for (final text in ['Copy', 'Forward as attachment', 'Block sender']) {
      expect(entry(text), findsNothing, reason: text);
    }

    await tester.tap(entry('More'));
    await tester.pumpAndSettle();

    for (final text in [
      'Forward as attachment',
      'Copy',
      'Meeting from this message…',
      'Print or save as PDF…',
      'Check for threats…',
      'Create rule…',
      'Block sender',
    ]) {
      expect(entry(text), findsOneWidget, reason: text);
    }
    expect(find.byKey(const ValueKey('menu-reply')), findsNothing,
        reason: 'More is a menu of its own, in place of the first');
  });

  testWidgets('Print from More prints the message', (tester) async {
    await pump(tester);
    final m = first(tester);

    await rightClick(tester, m);
    await fromMore(tester, 'Print or save as PDF…');

    expect(printer.printed.single.title, m.subject);
  });

  testWidgets('Check for threats from More checks it', (tester) async {
    await pump(tester);

    await rightClick(tester, first(tester));
    await fromMore(tester, 'Check for threats…');

    expect(find.byType(ThreatCheckSheet), findsOneWidget);
  });

  testWidgets('Create rule from More starts one from the message',
      (tester) async {
    await pump(tester);
    final m = first(tester);

    await rightClick(tester, m);
    await fromMore(tester, 'Create rule…');

    final screen =
        tester.widget<RuleEditorScreen>(find.byType(RuleEditorScreen));
    expect(screen.message?.id, m.id);
  });
}
