import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/sync/background_sync.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting_reply_filing.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/domain/sync_prefs.dart';
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';

/// Replies to your meetings file themselves (calendar idea #52): an
/// Accepted, Maybe or Declined to a meeting you organised, with nothing
/// written in it, leaves the Inbox as it arrives, unannounced. One with a
/// word in it, or a new time, stays. When in doubt, it stays.
void main() {
  const me = 'RDvir@hadco.example';

  /// A reply's calendar part as [prodId] writes it: [answer] from Dana to
  /// the meeting [organizer] organised, with [extra] lines in the event and
  /// [attendeeParams] on Dana's line.
  String reply({
    String method = 'REPLY',
    String answer = 'ACCEPTED',
    String? organizer = 'mailto:rdvir@hadco.example',
    String prodId = 'Microsoft Exchange Server 2010',
    List<String> extra = const [],
    String attendeeParams = '',
  }) =>
      [
        'BEGIN:VCALENDAR',
        'METHOD:$method',
        'PRODID:$prodId',
        'VERSION:2.0',
        'BEGIN:VEVENT',
        'ATTENDEE;PARTSTAT=$answer;CN=Dana Levi$attendeeParams'
            ':mailto:dana@example.com',
        ...extra,
        'SUMMARY;LANGUAGE=en-US:Accepted: Planning',
        'DTSTART:20261118T080000Z',
        'DTEND:20261118T090000Z',
        'UID:040000008200E00074C5B7101A82E0080000000001',
        if (organizer != null) 'ORGANIZER;CN=Ron Dvir:$organizer',
        'DTSTAMP:20261116T120000Z',
        'SEQUENCE:0',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n');

  MailMessage message({
    String subject = 'Accepted: Planning',
    bool isRead = false,
    bool isFlagged = false,
    Importance importance = Importance.normal,
    bool hasAttachments = false,
    List<String> attachmentNames = const [],
    List<MailAddress> to = const [MailAddress(email: 'rdvir@hadco.example')],
  }) =>
      MailMessage(
        id: 'h:Inbox#7',
        accountId: 'h',
        folderId: 'h:Inbox',
        uid: 7,
        subject: subject,
        from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
        to: to,
        date: DateTime(2026, 11, 16, 12),
        preview: '',
        isRead: isRead,
        isFlagged: isFlagged,
        importance: importance,
        hasAttachments: hasAttachments,
        attachmentNames: attachmentNames,
        isMeeting: true,
      );

  String? stays(
    MailBody body, {
    MailMessage? of,
    ReplyFiling filing = ReplyFiling.all,
  }) =>
      whyReplyStays(of ?? message(), body,
          filing: filing, ownAddress: me);

  group('what goes', () {
    test('an Accepted from Outlook with nothing written in it', () {
      // As Exchange hands it over: an empty body, and an empty COMMENT.
      expect(
        stays(MailBody(
          text: ' \n',
          html: '<html><head></head><body><p>&nbsp;</p></body></html>',
          calendar: reply(extra: [r'COMMENT;LANGUAGE=en-US:\n']),
        )),
        isNull,
      );
    });

    test('a Maybe and a Declined too, unless declines are kept', () {
      for (final answer in ['TENTATIVE', 'DECLINED']) {
        expect(stays(MailBody(text: '', calendar: reply(answer: answer))),
            isNull, reason: answer);
      }
      expect(
        stays(MailBody(text: '', calendar: reply(answer: 'DECLINED')),
            filing: ReplyFiling.keepDeclines),
        isNotNull,
      );
      expect(
        stays(MailBody(text: '', calendar: reply(answer: 'TENTATIVE')),
            filing: ReplyFiling.keepDeclines),
        isNull,
        reason: 'only the declines are kept',
      );
    });

    test("Google Calendar's own reply, whose words are all Google's", () {
      expect(
        stays(MailBody(
          text: 'Dana Levi has accepted this invitation.\n\nPlanning\n'
              'Wednesday 18 Nov 2026 ⋅ 10am – 11am (Israel Standard Time)\n\n'
              'Organiser\nRon Dvir\n\nInvitation from Google Calendar\n\n'
              'You are receiving this email because you are subscribed to '
              'calendar notifications.',
          calendar: reply(
            prodId: '-//Google Inc//Google Calendar 70.9054//EN',
            attendeeParams: ';X-NUM-GUESTS=0',
          ),
        )),
        isNull,
      );
    });

    test("MyEmail's own reply, its one line", () {
      expect(
        stays(MailBody(
          text: 'Dana Levi has tentatively accepted this invitation.',
          html: '<p>Dana Levi has tentatively accepted this invitation.</p>',
          calendar: reply(answer: 'TENTATIVE', prodId: '-//MyEmail//EN'),
        )),
        isNull,
      );
    });

    test('the organiser is known whatever the case of the address', () {
      expect(
        stays(MailBody(
          text: '',
          calendar: reply(organizer: 'MAILTO:rdvir@HADCO.example'),
        )),
        isNull,
      );
    });

    test('with no organiser named, one addressed to you is to your meeting',
        () {
      expect(stays(MailBody(text: '', calendar: reply(organizer: null))),
          isNull);
      expect(
        stays(MailBody(text: '', calendar: reply(organizer: null)),
            of: message(to: const [MailAddress(email: 'boss@hadco.example')])),
        isNotNull,
      );
    });

    test('with only the invitation attached as a file', () {
      expect(
        stays(
          MailBody(text: '', calendar: reply()),
          of: message(hasAttachments: true, attachmentNames: ['invite.ics']),
        ),
        isNull,
      );
    });
  });

  group('what stays', () {
    test('everything, while the switch is off', () {
      expect(
        stays(MailBody(text: '', calendar: reply()), filing: ReplyFiling.off),
        isNotNull,
      );
      expect(const CalendarPrefs().replyFiling, ReplyFiling.off,
          reason: 'off until Ron turns it on');
    });

    test('a reply with a word written in it', () {
      expect(
        stays(MailBody(
          text: 'Sounds good, I will bring the numbers.',
          calendar: reply(),
        )),
        isNotNull,
      );
      expect(
        stays(MailBody(
          text: 'Dana Levi has accepted this invitation.\n\nSee you there',
          html: '<p>Dana Levi has accepted this invitation.</p>'
              '<p>See you there</p>',
          calendar: reply(prodId: '-//MyEmail//EN'),
        )),
        isNotNull,
        reason: "MyEmail's line, and a note after it",
      );
    });

    test('a note the calendar part carries, either way it is written', () {
      expect(
        stays(MailBody(
          text: '',
          calendar: reply(extra: ['COMMENT;LANGUAGE=en-US:Running late']),
        )),
        isNotNull,
      );
      expect(
        stays(MailBody(
          text: 'Dana Levi has accepted this invitation.',
          calendar: reply(
            prodId: '-//Google Inc//Google Calendar 70.9054//EN',
            attendeeParams: ';X-RESPONSE-COMMENT="Ten minutes late"',
          ),
        )),
        isNotNull,
        reason: "Google's note goes on the attendee's line",
      );
    });

    test('a new time proposed, an invitation, a cancellation', () {
      for (final method in ['COUNTER', 'REQUEST', 'CANCEL', 'PUBLISH']) {
        expect(stays(MailBody(text: '', calendar: reply(method: method))),
            isNotNull, reason: method);
      }
      expect(
        stays(MailBody(text: '', calendar: reply()),
            of: message(subject: 'New Time Proposed: Planning')),
        isNotNull,
        reason: 'a proposal Outlook sent as an answer',
      );
    });

    test('an answer that is not one of the three', () {
      for (final answer in ['DELEGATED', 'NEEDS-ACTION', 'X-SOMETHING']) {
        expect(stays(MailBody(text: '', calendar: reply(answer: answer))),
            isNotNull, reason: answer);
      }
    });

    test("someone else's meeting", () {
      expect(
        stays(MailBody(
          text: '',
          calendar: reply(organizer: 'mailto:boss@hadco.example'),
        )),
        isNotNull,
      );
    });

    test('a reply read, flagged, marked important or with a file', () {
      final body = MailBody(text: '', calendar: reply());
      expect(stays(body, of: message(isRead: true)), isNotNull);
      expect(stays(body, of: message(isFlagged: true)), isNotNull);
      expect(stays(body, of: message(importance: Importance.high)),
          isNotNull);
      expect(
        stays(body,
            of: message(
                hasAttachments: true,
                attachmentNames: ['invite.ics', 'numbers.xlsx'])),
        isNotNull,
      );
      expect(stays(body, of: message(hasAttachments: true)), isNotNull,
          reason: 'files not yet named may be anything');
    });

    test('a calendar part not yet fetched, missing or unreadable', () {
      expect(
        stays(MailBody(text: '', calendar: reply(), calendarPending: true)),
        isNotNull,
      );
      expect(stays(const MailBody(text: '')), isNotNull);
      for (final junk in [
        'BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nEND:VEVENT',
        '\u0000\u0001 not a calendar',
        'BEGIN:VEVENT\nATTENDEE;PARTSTAT=ACCEPTED;X-RESPONSE-COMMENT="\n',
      ]) {
        expect(() => stays(MailBody(text: '', calendar: junk)),
            returnsNormally);
        expect(stays(MailBody(text: '', calendar: junk)), isNotNull);
      }
    });
  });

  group('the setting', () {
    test('is kept, and read back, with the rest of the calendar settings', () {
      for (final filing in ReplyFiling.values) {
        final prefs = const CalendarPrefs().copyWith(replyFiling: filing);
        final back = CalendarPrefs.fromJson(prefs.toJson());
        expect(back.replyFiling, filing);
        expect(back, prefs);
      }
      expect(CalendarPrefs.fromJson({'replies': 'everything'}).replyFiling,
          ReplyFiling.off, reason: 'a word this build does not know');
      expect(CalendarPrefs.tryParse('{"deleteAnswered":false}')!.replyFiling,
          ReplyFiling.off, reason: 'settings kept before there was one');
    });

    test('is read by the background pass from where the app keeps it', () {
      final store = MemoryUiStateStore();
      expect(replyFilingIn(store), ReplyFiling.off);
      store.writeString(UiStateKeys.calendarPrefs, '{not json');
      expect(replyFilingIn(store), ReplyFiling.off);
      store.writeString(
        UiStateKeys.calendarPrefs,
        '{"replies":"keepDeclines","dayStart":8}',
      );
      expect(replyFilingIn(store), ReplyFiling.keepDeclines);
    });

    testWidgets('a switch in Settings, Calendar, with declines beside it',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryUiStateStore();
      final container = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(store),
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CalendarSettingsScreen()),
      ));
      await tester.pumpAndSettle();

      final files = find.byKey(const ValueKey('calendar-file-replies'));
      final declines = find.byKey(const ValueKey('calendar-keep-declines'));
      expect(files, findsOneWidget);
      expect(tester.widget<SwitchListTile>(files).value, isFalse);
      expect(declines, findsNothing, reason: 'nothing to keep while off');
      expect(find.text('File replies to your meetings'), findsOneWidget);

      await tester.tap(files);
      await tester.pumpAndSettle();
      expect(container.read(calendarPrefsProvider).replyFiling,
          ReplyFiling.all);
      expect(declines, findsOneWidget);
      expect(tester.widget<SwitchListTile>(declines).value, isFalse);

      await tester.tap(declines);
      await tester.pumpAndSettle();
      expect(container.read(calendarPrefsProvider).replyFiling,
          ReplyFiling.keepDeclines);
      expect(replyFilingIn(store), ReplyFiling.keepDeclines,
          reason: 'written where the background pass reads it');

      await tester.tap(files);
      await tester.pumpAndSettle();
      expect(container.read(calendarPrefsProvider).replyFiling,
          ReplyFiling.off);
      expect(declines, findsNothing);
    });
  });

  group('the background pass', () {
    final now = DateTime(2026, 11, 16, 12);
    late _RepliesEngine engine;
    late FakeMailNotifier notifier;
    late MemorySyncStateStore state;
    var filing = ReplyFiling.all;

    setUp(() async {
      engine = _RepliesEngine(now);
      notifier = FakeMailNotifier();
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      filing = ReplyFiling.all;
    });

    Future<BackgroundSyncReport> pass() => BackgroundSync(
          engine: engine,
          notifier: notifier,
          state: state,
          clock: () => now,
          replyFiling: () => filing,
        ).run();

    final empty = reply();
    final withWords = reply();

    test('a reply with nothing written goes to Deleted Items, unannounced; '
        'one with words stays and is announced', () async {
      await pass();
      engine.arrive(2, calendar: empty, text: '');
      engine.arrive(3, calendar: withWords, text: 'See you there.');
      engine.arrive(4, text: 'An ordinary message');

      final report = await pass();

      expect(engine.moved.single.ids, ['h:Inbox#2']);
      expect(engine.moved.single.to, 'h:Deleted Items');
      expect(engine.deleted, isEmpty, reason: 'moved, never deleted');
      expect({for (final n in notifier.posted) n.payload},
          {'h:Inbox#3', 'h:Inbox#4'});
      expect(report.posted, 2);
      expect(engine.inbox.map((m) => m.id), isNot(contains('h:Inbox#2')));
    });

    test('everything stays, and nothing more is opened, while the switch is '
        'off', () async {
      filing = ReplyFiling.off;
      await pass();
      await state.writePrefs((await state.readPrefs()).withQuiet(
          'h', QuietRule(until: now.add(const Duration(hours: 1)))));
      engine.arrive(2, calendar: empty, text: '');

      await pass();

      expect(engine.moved, isEmpty);
      expect(engine.opened, isEmpty,
          reason: 'meeting mail not announced is not opened, as before');
    });

    test('filed even where the account is not announced', () async {
      await pass();
      await state.writePrefs(
        const SyncPrefs(mode: SyncMode.periodic, notify: false),
      );
      engine.arrive(2, calendar: empty, text: '');

      await pass();

      expect(engine.moved.single.ids, ['h:Inbox#2']);
      expect(notifier.posted, isEmpty);
    });

    test('a decline stays, and is announced, where declines are kept',
        () async {
      filing = ReplyFiling.keepDeclines;
      await pass();
      engine.arrive(2, calendar: reply(answer: 'DECLINED'), text: '');
      engine.arrive(3, calendar: reply(answer: 'ACCEPTED'), text: '');

      await pass();

      expect(engine.moved.single.ids, ['h:Inbox#3']);
      expect(notifier.posted.single.payload, 'h:Inbox#2');
    });

    test('an account with no Deleted Items keeps them all', () async {
      engine.withDeletedItems = false;
      await pass();
      engine.arrive(2, calendar: empty, text: '');

      await pass();

      expect(engine.moved, isEmpty);
      expect(engine.deleted, isEmpty,
          reason: 'a delete there would be for good');
      expect(notifier.posted.single.payload, 'h:Inbox#2');
    });

    test('a move that fails leaves the reply where it was, announced, and '
        'the pass goes on', () async {
      await pass();
      engine.moveFailure = const ConnectionFailed('Microsoft is busy');
      engine.arrive(2, calendar: empty, text: '');

      final report = await pass();

      expect(report.ok, isTrue);
      expect(notifier.posted.single.payload, 'h:Inbox#2');
    });

    test('of a move that went part way, only what did not go is announced',
        () async {
      await pass();
      engine.arrive(2, calendar: empty, text: '');
      engine.arrive(3, calendar: empty, text: '');
      engine.moveFailure = const PartialMove(
        done: [],
        moved: ['h:Inbox#3'],
        cause: ConnectionFailed('Microsoft is busy'),
      );

      await pass();

      expect(notifier.posted.map((n) => n.payload), ['h:Inbox#2']);
    });

    test('only from the Inbox: a folder announced as well keeps its own',
        () async {
      await state.writePrefs(const SyncPrefs(
        mode: SyncMode.periodic,
        watchedFolderIds: {'h:Projects'},
      ));
      await pass();
      engine.arrive(2, calendar: empty, text: '', folder: 'Projects');

      await pass();

      expect(engine.moved, isEmpty);
      expect(notifier.posted.single.payload, 'h:Projects#2');
    });

    test('a reply already read is left alone', () async {
      await pass();
      engine.arrive(2, calendar: empty, text: '', isRead: true);

      await pass();

      expect(engine.moved, isEmpty);
    });

    test('a calendar part that throws, or never comes, keeps the reply',
        () async {
      await pass();
      engine.arrive(2, calendar: empty, text: '');
      engine.bodyFailure = Exception('the body would not come');

      final report = await pass();

      expect(report.ok, isTrue);
      expect(engine.moved, isEmpty);
    });
  });
}

/// One Microsoft account, its Inbox, a folder beside it and Deleted Items,
/// for a background pass to read: what has arrived, each message's body,
/// and every move and delete asked of it.
class _RepliesEngine extends Fake implements MailEngine {
  _RepliesEngine(this.now) {
    arrive(1, text: 'Older mail');
  }

  final DateTime now;
  final List<MailMessage> inbox = [];
  final Map<String, MailBody> bodies = {};
  bool withDeletedItems = true;
  Object? moveFailure;
  Exception? bodyFailure;

  final List<({List<String> ids, String to})> moved = [];
  final List<List<String>> deleted = [];
  final List<String> opened = [];

  static const account = Account(
    id: 'h',
    displayName: 'Hadco',
    emailAddress: 'RDvir@hadco.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );

  void arrive(
    int uid, {
    String? calendar,
    required String text,
    bool isRead = false,
    String folder = 'Inbox',
  }) {
    final id = 'h:$folder#$uid';
    inbox.insert(
      0,
      MailMessage(
        id: id,
        accountId: 'h',
        folderId: 'h:$folder',
        uid: uid,
        subject: calendar == null ? 'Message $uid' : 'Accepted: Planning',
        preview: text,
        from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
        to: const [MailAddress(email: 'rdvir@hadco.example')],
        date: now.subtract(const Duration(minutes: 5)),
        isRead: isRead,
        isMeeting: calendar != null,
      ),
    );
    bodies[id] = MailBody(text: text, calendar: calendar);
  }

  @override
  Future<int> wakeSnoozed({DateTime? now}) async => 0;

  @override
  Future<List<Account>> loadAccounts() async => const [account];

  MailFolder _folder(String path, FolderRole role) => MailFolder.at(
        accountId: 'h',
        path: path,
        role: role,
        capabilities: FolderCapabilities.forGmail(role),
      );

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async => [
        _folder('Inbox', FolderRole.inbox),
        _folder('Projects', FolderRole.user),
        if (withDeletedItems) _folder('Deleted Items', FolderRole.deleted),
      ];

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async =>
      const [];

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      [
        for (final m in inbox)
          if (m.folderId == folderId) m,
      ];

  @override
  Future<MailMessage?> cachedMessage(String messageId) async =>
      inbox.where((m) => m.id == messageId).firstOrNull;

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    opened.add(messageId);
    final failure = bodyFailure;
    if (failure != null) throw failure;
    return bodies[messageId] ?? const MailBody(text: '');
  }

  @override
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  ) async {
    final failure = moveFailure;
    if (failure is PartialMove) {
      inbox.removeWhere((m) => failure.moved.contains(m.id));
      throw failure;
    }
    if (failure != null) throw failure;
    moved.add((ids: messageIds, to: toFolderId));
    inbox.removeWhere((m) => messageIds.contains(m.id));
    return [
      MessageMove(
        fromFolderId: 'h:Inbox',
        toFolderId: toFolderId,
        movedIds: [for (final id in messageIds) '$id-moved'],
      ),
    ];
  }

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    deleted.add(messageIds);
    return const [];
  }
}
