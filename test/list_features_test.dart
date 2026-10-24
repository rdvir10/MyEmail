import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/row_format.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/pinned_messages.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/row_formats.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The list as Outlook draws it: To in Sent, the All / Unread and Filter
/// bar, pins, conditional formats, your replies inside threads, and when an
/// opened message counts as read.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const inbox = 'acct-personal:INBOX';
  const sent = 'acct-personal:[Gmail]/Sent Mail';

  late _Engine engine;
  late ProviderContainer c;

  setUp(() => engine = _Engine());

  Future<void> pump(WidgetTester tester, {String folder = inbox}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    c.read(selectedFolderIdProvider.notifier).select(folder);
    await tester.pumpAndSettle();
  }

  List<MailMessage> rows(WidgetTester tester) => [
        for (final t in tester.widgetList<MessageTile>(find.byType(MessageTile)))
          t.message,
      ];

  testWidgets('a row in Sent says who it went to', (tester) async {
    await pump(tester, folder: sent);
    final first = rows(tester).first;
    expect(first.from.email, 'me@example.com', reason: 'the sample sends as me');
    expect(find.textContaining('To: ${first.to.first.display}'), findsWidgets);
  });

  testWidgets('Unread leaves the unread rows, and adds what the server found',
      (tester) async {
    await pump(tester);
    // The whole list, not only the rows on screen: the newest are unread.
    List<MailMessage> listed() => c.read(sortedMessagesProvider(inbox));
    expect(listed().any((m) => m.isRead), isTrue);

    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();

    expect(listed(), isNotEmpty);
    expect(listed().every((m) => !m.isRead), isTrue);
    expect(find.text('Older unread, only on the server'), findsOneWidget,
        reason: 'a message the list never held, from filterMessages');

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(listed().any((m) => m.isRead), isTrue);
    expect(find.text('Older unread, only on the server'), findsNothing);
  });

  testWidgets('a pinned message heads the list, under Pinned', (tester) async {
    await pump(tester);
    final chosen = rows(tester)[3];

    c.read(pinnedMessagesProvider.notifier).setPinned([chosen.id], true);
    await tester.pumpAndSettle();

    expect(rows(tester).first.id, chosen.id);
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });

  testWidgets('a conditional format colours its rows', (tester) async {
    await pump(tester);
    final first = rows(tester).first;
    c.read(rowFormatsProvider.notifier).save(RowFormat(
          id: 'r1',
          condition: RowCondition.from,
          text: first.from.email,
          colour: RowColour.red,
        ));
    await tester.pumpAndSettle();

    final sender = tester.widget<Text>(
      find.descendant(
        of: find.byType(MessageTile).first,
        matching: find.textContaining(first.from.email),
      ),
    );
    expect(sender.style?.color, RowColour.red.light);
  });

  testWidgets('your reply from Sent shows inside the thread it answers',
      (tester) async {
    await pump(tester);
    final answered = rows(tester).first;
    engine.sentReply = MailMessage(
      id: '$sent#9001',
      accountId: 'acct-personal',
      folderId: sent,
      uid: 9001,
      subject: 'Re: ${answered.subject}',
      preview: 'My answer',
      from: const MailAddress(email: 'me@example.com', name: 'Me'),
      to: [answered.from],
      date: answered.date.add(const Duration(minutes: 5)),
      isRead: true,
    );
    c.read(displayProvider.notifier).setConversations(true);
    await tester.pumpAndSettle();

    await tester.tap(find.text(answered.subject).first);
    await tester.pumpAndSettle();

    final sentName = c.read(folderIndexProvider)[sent]!.displayName;
    expect(find.text(sentName), findsOneWidget,
        reason: 'the reply carries the folder it is in');
    expect(rows(tester).any((m) => m.id == engine.sentReply!.id), isTrue);
  });

  testWidgets('After 5 seconds: opened and left before then, it stays unread',
      (tester) async {
    await pump(tester);
    c.read(displayProvider.notifier).setMarkRead(MarkReadWhen.afterDelay);
    await tester.pumpAndSettle();
    final unread = rows(tester).firstWhere((m) => !m.isRead);

    await tester.tap(find.text(unread.subject).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(engine.readMarked, isEmpty);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(engine.readMarked.toSet(), {unread.id});
  });
}

/// The sample engine, with one message only the server's filter finds, a
/// reply of yours in Sent when a test puts one there, and a record of what
/// was marked read.
class _Engine extends SampleMailEngine {
  MailMessage? sentReply;
  final readMarked = <String>[];

  @override
  Future<List<MailMessage>> filterMessages(
    String folderId,
    MessageFilter filter, {
    int limit = 100,
  }) async {
    final found = await super.filterMessages(folderId, filter, limit: limit);
    if (filter != MessageFilter.unread) return found;
    return [
      ...found,
      MailMessage(
        id: '$folderId#99999',
        accountId: folderId.split(':').first,
        folderId: folderId,
        uid: 99999,
        subject: 'Older unread, only on the server',
        preview: '',
        from: const MailAddress(email: 'old@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime.now().add(const Duration(minutes: 1)),
        isRead: false,
      ),
    ];
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final reply = sentReply;
    if (reply != null && folderId == reply.folderId) return [reply];
    return super.cachedMessages(folderId, offset: offset, limit: limit);
  }

  @override
  Future<void> setRead(String messageId, bool isRead) async {
    if (isRead) readMarked.add(messageId);
    return super.setRead(messageId, isRead);
  }

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) async {
    if (isRead) readMarked.addAll(messageIds);
    return super.setMessagesRead(messageIds, isRead);
  }
}
