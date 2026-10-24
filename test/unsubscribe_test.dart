import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/unsubscribe.dart';
import 'package:myemail/ui/messages/unsubscribe_link.dart';

/// Unsubscribe: one tap off a mailing list, made from the headers the list
/// puts on its mail (RFC 2369 and RFC 8058).
void main() {
  group('the headers', () {
    test('one click, where the list allows it over https', () {
      final options = UnsubscribeOptions.parse(
        '<mailto:leave@list.example.com?subject=unsubscribe>, '
            '<https://list.example.com/u?id=42>',
        'List-Unsubscribe=One-Click',
      )!;
      expect(options.oneClick, Uri.parse('https://list.example.com/u?id=42'));
      expect(options.mailto!.path, 'leave@list.example.com');
      expect(options.way, UnsubscribeWay.oneClick);
    });

    test('folded across lines, even inside the brackets', () {
      final options = UnsubscribeOptions.parse(
        '<https://list.example.com/unsub\r\n scribe?id=1>',
        null,
      )!;
      expect(options.web, Uri.parse('https://list.example.com/unsubscribe?id=1'));
      expect(options.oneClick, isNull, reason: 'no List-Unsubscribe-Post');
      expect(options.way, UnsubscribeWay.page);
    });

    test('the email before the page; never one click over plain http', () {
      final options = UnsubscribeOptions.parse(
        '<http://list.example.com/u>, <MAILTO:leave@list.example.com>',
        'List-Unsubscribe=One-Click',
      )!;
      expect(options.oneClick, isNull);
      expect(options.way, UnsubscribeWay.email);
    });

    test('nothing to act on is no button', () {
      expect(UnsubscribeOptions.parse(null, null), isNull);
      expect(UnsubscribeOptions.parse('<ftp://x>, garbage', null), isNull);
    });

    test('not in Junk, Sent or Drafts, and not on your own mail', () {
      final m = MailMessage(
        id: 'a:INBOX#1',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: 'News',
        from: const MailAddress(email: 'news@shop.example.com'),
        to: const [],
        date: DateTime(2026, 10, 1),
        preview: '',
      );
      bool offered(FolderRole role, {Set<String> own = const {}}) =>
          offersUnsubscribe(m, role: role, ownAddresses: own);
      expect(offered(FolderRole.inbox), isTrue);
      expect(offered(FolderRole.user), isTrue);
      expect(offered(FolderRole.junk), isFalse);
      expect(offered(FolderRole.sent), isFalse);
      expect(offered(FolderRole.drafts), isFalse);
      expect(
        offered(FolderRole.inbox, own: {'news@shop.example.com'}),
        isFalse,
      );
    });
  });

  group('leaving', () {
    late _Engine engine;
    late ProviderContainer c;
    final asked = <Uri>[];
    final opened = <Uri>[];
    var status = 200;

    final message = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );

    setUp(() {
      asked.clear();
      opened.clear();
      status = 200;
      engine = _Engine();
      c = ProviderContainer(
        overrides: [
          mailEngineProvider.overrideWithValue(engine),
          oneClickUnsubscribeProvider.overrideWithValue((uri) async {
            asked.add(uri);
            return status;
          }),
          openInBrowserProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
      );
      addTearDown(c.dispose);
    });

    final all = UnsubscribeOptions.parse(
      '<mailto:leave@shop.example.com?subject=Remove%20me>, '
          '<https://shop.example.com/u>',
      'List-Unsubscribe=One-Click',
    )!;

    test('one click, and the list is remembered as left', () async {
      expect(await unsubscribe(c.read, message, all), UnsubscribeOutcome.done);
      expect(asked, [Uri.parse('https://shop.example.com/u')]);
      expect(engine.sent, isEmpty);
      expect(c.read(unsubscribedProvider), contains(unsubscribeKey(all)));
    });

    test('a one-click address that refuses falls to the email', () async {
      status = 500;
      expect(await unsubscribe(c.read, message, all), UnsubscribeOutcome.sent);
      final draft = engine.sent.single;
      expect(draft.accountId, 'acct-personal');
      expect(draft.to.single.email, 'leave@shop.example.com');
      expect(draft.subject, 'Remove me');
      expect(draft.kind, ComposeKind.newMessage);
    });

    test('only a page: it opens, to be finished there', () async {
      final page = UnsubscribeOptions.parse('<https://shop.example.com/p>', null)!;
      expect(await unsubscribe(c.read, message, page), UnsubscribeOutcome.opened);
      expect(opened, [Uri.parse('https://shop.example.com/p')]);
      expect(c.read(unsubscribedProvider), isEmpty,
          reason: 'not left until the page is finished');
    });
  });

  testWidgets('beside the sender of a list message, with what it will do',
      (tester) async {
    final engine = _Engine();
    final container = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        oneClickUnsubscribeProvider.overrideWithValue((_) async => 200),
      ],
    );
    addTearDown(container.dispose);
    final m = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );
    engine.unsubscribe[m.id] = UnsubscribeOptions.parse(
      '<https://shop.example.com/u>',
      'List-Unsubscribe=One-Click',
    )!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: Center(child: UnsubscribeLink(message: m))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('unsubscribe')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MyEmail tells them now'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
    await tester.pumpAndSettle();
    expect(find.text('Unsubscribed'), findsOneWidget);
  });
}

/// The sample engine, keeping what it was asked to send.
class _Engine extends SampleMailEngine {
  final sent = <Draft>[];

  @override
  Future<void> sendDraft(Draft draft) async => sent.add(draft);
}
