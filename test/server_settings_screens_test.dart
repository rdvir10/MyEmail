import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/mailbox_settings/server_settings.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mailbox_settings.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/settings/auto_replies_screen.dart';
import 'package:myemail/ui/settings/rules_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Settings, Automatic replies (#52) and Rules (#37), against the sample
/// mailbox's settings kept in memory.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(
    WidgetTester tester,
    SampleMailEngine engine,
    Widget home,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: home,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  group('automatic replies', () {
    test('the status says when', () {
      final now = DateTime(2026, 10, 28, 12);
      String status(AutoReply r) => autoReplyStatus(r, use24h: true, now: now);
      expect(status(const AutoReply()), 'Off');
      expect(status(const AutoReply(on: true)), 'On');
      expect(
        status(AutoReply(
          on: true,
          start: DateTime(2026, 11, 2, 9),
          end: DateTime(2026, 11, 6, 18),
        )),
        'From Mon 2 Nov, 09:00 to Fri 6 Nov, 18:00',
      );
      expect(
        status(AutoReply(
          on: true,
          start: DateTime(2026, 10, 26, 9),
          end: DateTime(2026, 10, 30, 18),
        )),
        'On until Fri 30 Oct, 18:00',
      );
      expect(
        status(AutoReply(
          on: true,
          start: DateTime(2026, 10, 19, 9),
          end: DateTime(2026, 10, 23, 18),
        )),
        'Off: ended Fri 23 Oct',
      );
    });

    testWidgets("Gmail's: on, with a subject, to contacts only, saved",
        (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, engine, const AutoRepliesScreen());
      final row = find.byKey(const ValueKey('auto-reply-account:acct-personal'));
      expect(
          find.descendant(of: row, matching: find.text('Off')), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('auto-reply-outside')), findsNothing,
          reason: 'Gmail has no inside and outside');
      await tester.tap(find.byKey(const ValueKey('auto-reply-on')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('auto-reply-subject')), 'Away');
      await tester.enterText(
          find.byKey(const ValueKey('auto-reply-message')), 'Back on Monday.');
      await tester.tap(find.byKey(const ValueKey('auto-reply-contacts-only')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-save')));
      await tester.pumpAndSettle();

      final saved = (engine.settings['acct-personal']! as MemoryServerSettings).reply;
      expect(saved, const AutoReply(
        on: true,
        subject: 'Away',
        message: 'Back on Monday.',
        audience: ReplyAudience.contacts,
      ));
      expect(find.textContaining('Automatic replies are on'), findsOneWidget);
      expect(
          find.descendant(of: row, matching: find.text('On')), findsOneWidget,
          reason: 'the list reads it again');
    });

    testWidgets('on with no message is not sent', (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, engine, const AutoRepliesScreen());
      await tester.tap(
          find.byKey(const ValueKey('auto-reply-account:acct-personal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-on')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-save')));
      await tester.pumpAndSettle();

      expect(find.text('Write the message first.'), findsOneWidget);
      expect((engine.settings['acct-personal']! as MemoryServerSettings).reply.on,
          isFalse);
    });

    testWidgets("Outlook's: outside the organisation, contacts only, a "
        'message of their own; then inside only', (tester) async {
      final engine = SampleMailEngine();
      final outlook = MemoryServerSettings(
        reply: const AutoReply(on: true, message: 'Away this week.'),
      );
      engine.settings['acct-personal'] = outlook;
      await pump(tester, engine, const AutoRepliesScreen());
      await tester.tap(
          find.byKey(const ValueKey('auto-reply-account:acct-personal')));
      await tester.pumpAndSettle();

      expect(find.text('Message to people in my organisation'), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-reply-subject')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('auto-reply-contacts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-own-outside')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('auto-reply-outside-message')),
          'I am out of the office.');
      await tester.tap(find.byKey(const ValueKey('auto-reply-save')));
      await tester.pumpAndSettle();

      expect(outlook.reply.audience, ReplyAudience.contacts);
      expect(outlook.reply.outsideMessage, 'I am out of the office.');
      expect(outlook.reply.message, 'Away this week.');

      await tester.tap(
          find.byKey(const ValueKey('auto-reply-account:acct-personal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-outside')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('auto-reply-outside-message')),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('auto-reply-save')));
      await tester.pumpAndSettle();
      expect(outlook.reply.audience, ReplyAudience.insideOnly);
      expect(outlook.reply.outsideMessage, 'I am out of the office.',
          reason: 'kept for the next time outside is on');
    });

    testWidgets('a period is set with its start and end', (tester) async {
      final engine = SampleMailEngine();
      await pump(tester, engine, const AutoRepliesScreen());
      await tester.tap(
          find.byKey(const ValueKey('auto-reply-account:acct-personal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-on')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-reply-scheduled')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('auto-reply-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-reply-end')), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('auto-reply-message')), 'Away.');
      await tester.tap(find.byKey(const ValueKey('auto-reply-save')));
      await tester.pumpAndSettle();

      final saved = (engine.settings['acct-personal']! as MemoryServerSettings).reply;
      expect(saved.scheduled, isTrue);
      expect(saved.end!.isAfter(saved.start!), isTrue);
      expect(saved.start!.isAfter(DateTime.now()), isTrue,
          reason: 'from the next hour');
    });

    testWidgets('an account that has not allowed it is offered Allow',
        (tester) async {
      final engine = SampleMailEngine();
      engine.settings['acct-personal'] = _Refusing();
      await pump(tester, engine, const AutoRepliesScreen());
      final row = find.byKey(const ValueKey('auto-reply-account:acct-personal'));
      expect(find.descendant(of: row, matching: find.text('Not allowed yet')),
          findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('server-settings-allow')), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-reply-save')), findsNothing);
    });
  });

  group('rules', () {
    testWidgets('one is made, switched off and deleted', (tester) async {
      final engine = SampleMailEngine();
      final outlook = MemoryServerSettings();
      engine.settings['acct-personal'] = outlook;
      await pump(tester, engine, const RulesScreen());
      final row = find.byKey(const ValueKey('rules-account:acct-personal'));
      expect(find.descendant(of: row, matching: find.text('None')),
          findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rule-new')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();
      expect(find.text('Say who it is from, or what its subject has.'),
          findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Shop');
      await tester.enterText(find.byKey(const ValueKey('rule-from')),
          'shop@example.com, orders@example.com');
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();
      expect(find.text('Choose the folder to move it to.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rule-folder')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-folder:INBOX')), findsNothing);
      expect(find.byKey(const ValueKey('rule-folder:[Gmail]/Sent Mail')),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('rule-folder:Finance/Receipts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rule-read')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();

      final made = outlook.saved.single;
      expect(made.name, 'Shop');
      expect(made.from, ['shop@example.com', 'orders@example.com']);
      expect(made.moveTo, 'Finance/Receipts');
      expect(made.markRead, isTrue);
      expect(find.text('Shop'), findsOneWidget, reason: 'listed');

      await tester.tap(find.byKey(ValueKey('rule-on:${made.id}')));
      await tester.pumpAndSettle();
      expect(outlook.saved.single.enabled, isFalse);

      await tester.tap(find.byKey(ValueKey('rule-delete:${made.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rule-delete-confirm')));
      await tester.pumpAndSettle();
      expect(outlook.saved, isEmpty);
      expect(find.text('No rules yet'), findsOneWidget);
    });

    testWidgets("Gmail's filters have no names and no switch, and one that "
        'does more says so', (tester) async {
      final engine = SampleMailEngine();
      engine.settings['acct-personal'] = MemoryServerSettings(
        microsoft: false,
        rules: const [
          MailRule(id: 'f1', from: ['news@example.com'], moveTo: 'Archive'),
          MailRule(
            id: 'f2',
            from: ['boss@example.com'],
            markRead: true,
            partly: true,
          ),
        ],
      );
      await pump(tester, engine, const RulesScreen());
      await tester.tap(find.byKey(const ValueKey('rules-account:acct-personal')));
      await tester.pumpAndSettle();

      expect(find.text('From news@example.com: move to Archive'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.textContaining('Does more than this shows'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rule-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-name')), findsNothing);
    });

    testWidgets("from a message: More, Create rule, with the sender's "
        'address and its subject a tap away', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = SampleMailEngine();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create rule…'));
      await tester.pumpAndSettle();

      expect(find.byType(RuleEditorScreen), findsOneWidget);
      final from = tester.widget<TextField>(
          find.byKey(const ValueKey('rule-from')));
      expect(from.controller!.text, message.from.email);
      await tester.tap(find.byKey(const ValueKey('rule-use-subject')));
      await tester.pumpAndSettle();
      final subject = tester.widget<TextField>(
          find.byKey(const ValueKey('rule-subject')));
      expect(subject.controller!.text, message.subject.trim());
    });
  });
}

/// Settings whose account has not allowed the app to read them.
class _Refusing extends MemoryServerSettings {
  @override
  Future<AutoReply> autoReply() async => throw const SignInNeedsConsent(
        'This account needs signing in again.',
      );

  @override
  Future<List<MailRule>> rules() async => throw const SignInNeedsConsent(
        'This account needs signing in again.',
      );
}
