import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/ui/messages/conversation_tile.dart';
import 'package:myemail/ui/messages/date_format.dart';
import 'package:myemail/ui/messages/message_tile.dart';

/// What a row in the message list looks like, set beside another app's
/// list that Ron liked: the sender's address whole, read and unread told
/// apart at a glance, a flag a tap away, the phone's own clock, less air.
void main() {
  final today = DateTime.now();

  MailMessage message({
    String id = 'a:INBOX#1',
    String? name = 'Crystal R',
    String email = 'crystalr@hadco-metal.com',
    bool read = false,
    bool flagged = false,
    DateTime? date,
  }) =>
      MailMessage(
        id: id,
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: 'NC-SC-GA-FL Report',
        preview: 'The weekly numbers',
        from: MailAddress(email: email, name: name),
        to: const [],
        date: date ?? DateTime(today.year, today.month, today.day, 8, 14),
        isRead: read,
        isFlagged: flagged,
      );

  Future<void> pump(WidgetTester tester, Widget row) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Column(children: [row]))),
    );
  }

  MessageTile tile(
    MailMessage m, {
    ListDensity density = ListDensity.cozy,
    VoidCallback? onTap,
    VoidCallback? onToggleFlag,
  }) =>
      MessageTile(
        message: m,
        isSelected: false,
        density: density,
        onTap: onTap ?? () {},
        onToggleFlag: onToggleFlag,
      );

  group('who it is from', () {
    for (final density in ListDensity.values) {
      testWidgets('name and address, whole, when ${density.label}',
          (tester) async {
        // Compact left the address out, and elsewhere it was small, grey
        // and the first thing cut off.
        await pump(tester, tile(message(), density: density));

        expect(find.text('Crystal R <crystalr@hadco-metal.com>'),
            findsOneWidget);
      });
    }

    test('an address with no name, or named after itself, is said once', () {
      expect(senderLine(const MailAddress(email: 'noreply@x.com')),
          'noreply@x.com');
      expect(
        senderLine(const MailAddress(email: 'dana@x.com', name: 'Dana@X.com')),
        'dana@x.com',
      );
    });
  });

  group('read and unread', () {
    Color? ground(WidgetTester tester) => tester
        .widget<Material>(find
            .descendant(
              of: find.byType(MessageTile),
              matching: find.byType(Material),
            )
            .first)
        .color;

    testWidgets('sit on different ground', (tester) async {
      await pump(tester, tile(message(read: false)));
      final unread = ground(tester);
      await pump(tester, tile(message(read: true)));
      final read = ground(tester);

      expect(unread, Colors.transparent);
      expect(read, isNot(Colors.transparent));
      expect(read, isNot(unread));
    });
  });

  group('the flag', () {
    testWidgets('is a tap away, and the tap does not open the message',
        (tester) async {
      var toggled = 0;
      var opened = 0;
      await pump(
        tester,
        tile(
          message(),
          onTap: () => opened++,
          onToggleFlag: () => toggled++,
        ),
      );

      expect(find.byIcon(Icons.flag_outlined), findsOneWidget,
          reason: 'the place to tap is there before anything is flagged');
      await tester.tap(find.byTooltip('Flag'));
      await tester.pump();

      expect(toggled, 1);
      expect(opened, 0);
    });

    testWidgets('a flagged row shows it, and offers to take it off',
        (tester) async {
      await pump(
        tester,
        tile(message(flagged: true), onToggleFlag: () {}),
      );

      expect(find.byIcon(Icons.flag), findsOneWidget);
      expect(find.byTooltip('Remove flag'), findsOneWidget);
    });

    testWidgets('a whole thread flags from its row', (tester) async {
      var toggled = 0;
      await pump(
        tester,
        ConversationTile(
          conversation: Conversation([
            message(id: 'a:INBOX#1', read: true),
            message(id: 'a:INBOX#2', read: true),
          ]),
          isExpanded: false,
          onTap: () {},
          onToggleFlag: () => toggled++,
        ),
      );

      await tester.tap(find.byTooltip('Flag'));
      await tester.pump();
      expect(toggled, 1);
    });
  });

  group('the time', () {
    test("is written the way the phone's clock is", () {
      final evening = DateTime(2026, 9, 24, 20, 14);
      final morning = DateTime(2026, 9, 24, 8, 5);
      final noon = DateTime(2026, 9, 24, 12, 0);
      final midnight = DateTime(2026, 9, 24, 0, 30);

      expect(formatClock(evening, use24h: true), '20:14');
      expect(formatClock(evening, use24h: false), '8:14 PM');
      expect(formatClock(morning, use24h: false), '8:05 AM');
      expect(formatClock(noon, use24h: false), '12:00 PM');
      expect(formatClock(midnight, use24h: false), '12:30 AM');
      expect(formatMessageDateLong(evening, use24h: false),
          'Thu 24 Sep 2026, 8:14 PM');
    });

    testWidgets('on a row, as the phone is set', (tester) async {
      final m = message(
        date: DateTime(today.year, today.month, today.day, 20, 14),
      );

      tester.platformDispatcher.alwaysUse24HourFormatTestValue = false;
      addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      await pump(tester, tile(m));
      expect(find.text('8:14 PM'), findsOneWidget);

      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      await pump(tester, tile(m));
      expect(find.text('20:14'), findsOneWidget);
    });
  });

  testWidgets('rows are tighter than they were', (tester) async {
    // Three lines took 80 points, a third of it space between them; beside
    // another app's list, ours showed two thirds as many messages.
    await pump(tester, tile(message()));

    expect(tester.getSize(find.byType(MessageTile)).height,
        lessThanOrEqualTo(66));
  });

  group('a thread', () {
    testWidgets('is headed by the last one to write who is not you',
        (tester) async {
      // Answered last, a thread was headed with your own name.
      await pump(
        tester,
        ConversationTile(
          conversation: Conversation([
            message(
              id: 'a:INBOX#1',
              name: 'Samantha Bechtloff',
              email: 'samantha@mirjobs.com',
              date: DateTime(2026, 9, 23, 8, 56),
            ),
            message(
              id: 'a:INBOX#2',
              name: 'Ron Dvir',
              email: 'RDvir@hadco-metal.com',
              date: DateTime(2026, 9, 23, 9, 30),
            ),
          ]),
          isExpanded: false,
          onTap: () {},
          ownAddresses: const {'rdvir@hadco-metal.com'},
        ),
      );

      expect(find.text('Samantha Bechtloff <samantha@mirjobs.com>'),
          findsOneWidget);
    });
  });
}
