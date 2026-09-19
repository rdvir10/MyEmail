import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/mailbox_widgets.dart';
import 'package:myemail/data/widget/widget_state_store.dart';
import 'package:myemail/data/widget/widget_taps.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/mailbox_counts.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;

/// The two numbers on the home screen, and where they come from.
void main() {
  MailMessage at(DateTime date) => MailMessage(
        id: 'm${date.microsecondsSinceEpoch}',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: date.microsecondsSinceEpoch,
        subject: 'Subject',
        preview: 'Preview',
        from: const MailAddress(email: 'someone@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: date,
      );

  group('counting what is new', () {
    final mark = DateTime.utc(2026, 9, 18, 12);

    test('counts what arrived after the mark', () {
      final messages = [
        at(mark.add(const Duration(minutes: 5))),
        at(mark.add(const Duration(minutes: 1))),
        at(mark.subtract(const Duration(minutes: 1))),
      ];

      expect(arrivedSince(messages, mark), 2);
    });

    test('a message at the mark is not after it', () {
      expect(arrivedSince([at(mark)], mark), 0);
    });

    test('nothing is new until the app has been opened once', () {
      // Otherwise a fresh install announces four thousand new messages, which
      // is true in a useless way.
      expect(arrivedSince([at(mark), at(mark)], null), 0);
    });

    test('an empty mailbox is zero, not nothing', () {
      expect(arrivedSince(const [], mark), 0);
    });
  });

  group('what the widget is told', () {
    late SampleMailEngine engine;
    late FakeHomeScreenSurface surface;
    late MemoryWidgetStateStore store;
    late MailboxWidgets widgets;

    setUp(() {
      engine = SampleMailEngine();
      surface = FakeHomeScreenSurface();
      store = MemoryWidgetStateStore();
      widgets = MailboxWidgets(surface: surface, store: store);
    });

    Future<String> anInbox() async {
      final account = (await engine.loadAccounts()).first;
      final folders = await engine.loadFolders(account.id);
      return folders.firstWhere((f) => f.role == FolderRole.inbox).id;
    }

    test('nothing is written until a widget has been placed', () async {
      await widgets.refresh(engine);

      expect(surface.values, isEmpty);
      expect(surface.redraws, 0, reason: 'nothing to redraw');
    });

    test('setting one up writes its mailbox, both numbers and a name',
        () async {
      final inbox = await anInbox();

      await widgets.setUp(appWidgetId: '7', mailbox: WidgetMailbox(folderId: inbox), engine: engine);

      expect(surface.values['widget.7.folder'], inbox);
      expect(surface.values['count.$inbox.total'], isA<int>());
      expect(surface.values['count.$inbox.total'], greaterThan(0));
      expect(surface.values['count.$inbox.new'], 0,
          reason: 'never opened, so nothing counts as new yet');
      expect(surface.values['count.$inbox.label'], contains('Inbox'));
      expect(surface.redraws, 1);
    });

    test('the name says whose mailbox it is', () async {
      // Two accounts both have an Inbox, and a widget with no name on it is a
      // number without a subject.
      final account = (await engine.loadAccounts()).first;
      final inbox = await anInbox();

      await widgets.setUp(appWidgetId: '7', mailbox: WidgetMailbox(folderId: inbox), engine: engine);

      expect(
          surface.values['count.$inbox.label'], contains(account.displayName));
    });

    test('opening the app moves the mark and takes the count back to zero',
        () async {
      final inbox = await anInbox();
      await widgets.setUp(appWidgetId: '7', mailbox: WidgetMailbox(folderId: inbox), engine: engine);
      // A mark from long ago: everything in the window arrived after it.
      store.openedAt = DateTime.utc(2000);
      await widgets.refresh(engine);
      expect(surface.values['count.$inbox.new'], greaterThan(0));

      await widgets.markCaughtUp(DateTime.now().toUtc(), engine);

      expect(surface.values['count.$inbox.new'], 0);
      expect(store.openedAt!.isAfter(DateTime.utc(2001)), isTrue);
    });

    test('the unified inbox adds the accounts up', () async {
      final accounts = await engine.loadAccounts();
      var total = 0;
      for (final a in accounts) {
        for (final f in await engine.loadFolders(a.id)) {
          if (f.role == FolderRole.inbox) total += f.totalCount;
        }
      }

      await widgets.setUp(
          appWidgetId: '7', mailbox: WidgetMailbox(folderId: kUnifiedInboxId), engine: engine);

      expect(surface.values['count.$kUnifiedInboxId.total'], total);
      expect(surface.values['count.$kUnifiedInboxId.label'], 'All inboxes');
    });

    test('a mailbox that has gone leaves the widget unassigned', () async {
      // Deleted, renamed, or its account removed. Writing zeroes would read
      // as an empty mailbox rather than a missing one.
      await widgets.setUp(
          appWidgetId: '7', mailbox: WidgetMailbox(folderId: 'acct-gone:INBOX'), engine: engine);

      expect(surface.values.containsKey('widget.7.folder'), isFalse);
      expect(surface.values.keys.where((k) => k.startsWith('count.')), isEmpty);
    });

    test('two widgets on two mailboxes are counted separately', () async {
      final accounts = await engine.loadAccounts();
      final first = (await engine.loadFolders(accounts[0].id))
          .firstWhere((f) => f.role == FolderRole.inbox);
      final second = (await engine.loadFolders(accounts[1].id))
          .firstWhere((f) => f.role == FolderRole.inbox);

      await widgets.setUp(appWidgetId: '1', mailbox: WidgetMailbox(folderId: first.id), engine: engine);
      await widgets.setUp(
          appWidgetId: '2', mailbox: WidgetMailbox(folderId: second.id), engine: engine);

      expect(surface.values['widget.1.folder'], first.id);
      expect(surface.values['widget.2.folder'], second.id);
      expect(surface.values['count.${first.id}.total'], first.totalCount);
      expect(surface.values['count.${second.id}.total'], second.totalCount);
    });

    test('a failure in here never escapes', () async {
      // This runs at the end of every sync pass. A widget that is briefly out
      // of date must not be able to fail the pass, or the startup of the app.
      final inbox = await anInbox();
      store.mailboxes['7'] = WidgetMailbox(folderId: inbox);

      await expectLater(
        MailboxWidgets(surface: _BrokenSurface(), store: store).refresh(engine),
        completes,
      );
    });
  });

  group('what each widget is set to', () {
    test('a widget placed before there were settings keeps working', () {
      // The value used to be the folder id on its own. It has to go on
      // meaning what it meant, which is everything in that folder.
      final migrated = WidgetMailbox.fromJson('acct-personal:INBOX');

      expect(migrated?.folderId, 'acct-personal:INBOX');
      expect(migrated?.counts, WidgetCount.all);
      expect(migrated?.label, isNull);
    });

    test('a record survives being written and read', () {
      const mailbox = WidgetMailbox(
        folderId: 'a:INBOX',
        counts: WidgetCount.unread,
        label: 'Hadco',
      );

      expect(WidgetMailbox.fromJson(mailbox.toJson()), mailbox);
    });

    test('a blank name is no name, not a blank one', () {
      expect(
        WidgetMailbox.fromJson({'folder': 'a:INBOX', 'label': '  '})?.label,
        isNull,
      );
    });

    test('rubbish is dropped rather than crashing the widget', () {
      expect(WidgetMailbox.fromJson(42), isNull);
      expect(WidgetMailbox.fromJson({'counts': 'unread'}), isNull);
    });
  });

  group('counting what is unread', () {
    late SampleMailEngine engine;
    late FakeHomeScreenSurface surface;
    late MemoryWidgetStateStore store;
    late MailboxWidgets widgets;

    setUp(() {
      engine = SampleMailEngine();
      surface = FakeHomeScreenSurface();
      store = MemoryWidgetStateStore();
      widgets = MailboxWidgets(surface: surface, store: store);
    });

    test('both numbers are written, whichever the widget shows', () async {
      // So changing the mode redraws at once instead of waiting for a sync.
      final account = (await engine.loadAccounts()).first;
      final inbox = (await engine.loadFolders(account.id))
          .firstWhere((f) => f.role == FolderRole.inbox);

      await widgets.setUp(
        appWidgetId: '7',
        mailbox: WidgetMailbox(
          folderId: inbox.id,
          counts: WidgetCount.unread,
        ),
        engine: engine,
      );

      expect(surface.values['count.${inbox.id}.total'], inbox.totalCount);
      expect(surface.values['count.${inbox.id}.unread'], inbox.unreadCount);
      expect(surface.values['widget.7.mode'], 'unread');
    });

    test('the unified inbox adds the unread up too', () async {
      var unread = 0;
      for (final a in await engine.loadAccounts()) {
        for (final f in await engine.loadFolders(a.id)) {
          if (f.role == FolderRole.inbox) unread += f.unreadCount;
        }
      }

      await widgets.setUp(
        appWidgetId: '7',
        mailbox: const WidgetMailbox(folderId: kUnifiedInboxId),
        engine: engine,
      );

      expect(surface.values['count.$kUnifiedInboxId.unread'], unread);
    });

    test('a widget with a name of its own says so', () async {
      final inbox = await (() async {
        final account = (await engine.loadAccounts()).first;
        return (await engine.loadFolders(account.id))
            .firstWhere((f) => f.role == FolderRole.inbox)
            .id;
      })();

      await widgets.setUp(
        appWidgetId: '7',
        mailbox: WidgetMailbox(folderId: inbox, label: 'Hadco'),
        engine: engine,
      );

      expect(surface.values['widget.7.label'], 'Hadco');
      // The folder's own name is still written: it is what the widget falls
      // back to, and what the settings screen shows underneath.
      expect(surface.values['count.$inbox.label'], contains('Inbox'));
    });
  });

  group('widgets that are no longer there', () {
    test('are forgotten once Android says which are left', () async {
      // Nothing tells the app when a widget is dragged to the bin, so its
      // mailbox would be recounted at every sync for ever.
      final engine = SampleMailEngine();
      final store = MemoryWidgetStateStore();
      final widgets = MailboxWidgets(
        surface: FakeHomeScreenSurface(),
        store: store,
      );
      final account = (await engine.loadAccounts()).first;
      final inbox = (await engine.loadFolders(account.id))
          .firstWhere((f) => f.role == FolderRole.inbox);
      await widgets.setUp(
        appWidgetId: '1',
        mailbox: WidgetMailbox(folderId: inbox.id),
        engine: engine,
      );
      await widgets.setUp(
        appWidgetId: '2',
        mailbox: WidgetMailbox(folderId: inbox.id),
        engine: engine,
      );

      await widgets.refresh(engine, placed: ['2']);

      expect(store.mailboxes.keys, ['2']);
    });

    test('nothing is forgotten where the answer is not known', () async {
      // The background isolate cannot ask Android, and an empty answer there
      // must not wipe every widget the app has.
      final engine = SampleMailEngine();
      final store = MemoryWidgetStateStore();
      final widgets = MailboxWidgets(
        surface: FakeHomeScreenSurface(),
        store: store,
      );
      store.mailboxes['1'] = const WidgetMailbox(folderId: 'a:INBOX');

      await widgets.refresh(engine);

      expect(store.mailboxes.keys, ['1']);
    });
  });

  group('tapping a widget', () {
    test('opens the folder it was counting', () {
      expect(
        folderFromWidgetLink(
          Uri.parse('myemail://folder?id=acct-personal%3AFinance%2FReceipts'),
        ),
        'acct-personal:Finance/Receipts',
      );
    });

    test('a link with no folder in it opens nothing in particular', () {
      expect(folderFromWidgetLink(Uri.parse('myemail://folder')), isNull);
      expect(folderFromWidgetLink(Uri.parse('myemail://folder?id=')), isNull);
    });

    test("someone else's link is not ours to follow", () {
      // The app is opened by more than this: an update, a share, a mailto.
      expect(folderFromWidgetLink(Uri.parse('https://example.com')), isNull);
      expect(folderFromWidgetLink(Uri.parse('myemail://compose')), isNull);
      expect(folderFromWidgetLink(null), isNull);
    });
  });

  group('values that cross to Android', () {
    // The crash this group exists for: an opaque colour is 0xFF……, which as
    // a Dart integer is bigger than a Java int. It crossed as a Long, was
    // stored with putLong, and the widget provider read it with getInt and
    // threw. The provider is a receiver in the app's own process, so that
    // was not a widget failing to draw — it was MyEmail crashing every time
    // the launcher asked for a redraw.
    test('every colour fits in a signed 32-bit int', () {
      for (final colour in WidgetColour.values) {
        expect(colour.argb, lessThanOrEqualTo(2147483647), reason: colour.name);
        expect(colour.argb, greaterThanOrEqualTo(-2147483648),
            reason: colour.name);
      }
    });

    test('and the widget is sent that, not the Dart number', () async {
      final engine = SampleMailEngine();
      final surface = FakeHomeScreenSurface();
      final store = MemoryWidgetStateStore();

      await MailboxWidgets(surface: surface, store: store).setUp(
        appWidgetId: '7',
        mailbox: const WidgetMailbox(
          folderId: kUnifiedInboxId,
          colour: WidgetColour.orange,
        ),
        engine: engine,
      );

      expect(surface.values['widget.7.colour'], WidgetColour.orange.argb);
      expect(surface.values['widget.7.colour'], isNegative,
          reason: 'an opaque colour is negative once it fits in 32 bits');
    });

    test('every number written is one Android can store as an int', () async {
      // Not just the colour: anything over two billion has the same problem,
      // and a mailbox count is written the same way.
      final engine = SampleMailEngine();
      final surface = FakeHomeScreenSurface();
      final store = MemoryWidgetStateStore();
      await MailboxWidgets(surface: surface, store: store).setUp(
        appWidgetId: '7',
        mailbox: const WidgetMailbox(folderId: kUnifiedInboxId),
        engine: engine,
      );

      for (final entry in surface.values.entries) {
        final value = entry.value;
        if (value is! int) continue;
        expect(value, lessThanOrEqualTo(2147483647), reason: entry.key);
        expect(value, greaterThanOrEqualTo(-2147483648), reason: entry.key);
      }
    });
  });
}

class _BrokenSurface implements HomeScreenSurface {
  @override
  Future<String?> getString(String key) async => throw StateError('no');

  @override
  Future<void> putInt(String key, int value) async => throw StateError('no');

  @override
  Future<void> putString(String key, String? value) async =>
      throw StateError('no');

  @override
  Future<void> redraw() async => throw StateError('no');
}
