import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mailtree/data/ui_state_store.dart';
import 'package:mailtree/domain/display_settings.dart';
import 'package:mailtree/domain/mail_message.dart';
import 'package:mailtree/state/compose_providers.dart';
import 'package:mailtree/state/display_providers.dart';
import 'package:mailtree/state/providers.dart';
import 'package:mailtree/ui/messages/conversation_tile.dart';
import 'package:mailtree/ui/messages/message_tile.dart';
import 'package:mailtree/ui/messages/reading_pane.dart';
import 'package:mailtree/ui/settings/accounts_screen.dart';
import 'package:mailtree/ui/settings/settings_screen.dart';
import 'package:mailtree/ui/settings/signatures_screen.dart';
import 'package:mailtree/ui/settings/view_settings_screen.dart';
import 'package:mailtree/ui/shell/app_shell.dart';

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

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

  Widget app(Widget home) => UncontrolledProviderScope(
        container: container(),
        child: MaterialApp(home: home),
      );

  group('DisplaySettings', () {
    test('round-trips through JSON', () {
      const settings = DisplaySettings(
        readingPane: ReadingPanePosition.bottom,
        density: ListDensity.compact,
        conversations: true,
      );
      expect(DisplaySettings.fromJson(settings.toJson()), settings);
    });

    test('an unrecognised value falls back rather than throwing', () {
      // A record written by a newer build must not leave the app unable to
      // draw a message list.
      final settings = DisplaySettings.fromJson({
        'readingPane': 'floating',
        'density': 42,
        'conversations': 'yes',
      });
      expect(settings, const DisplaySettings());
    });

    test('compact drops the preview line, the others keep it', () {
      expect(ListDensity.compact.previewLines, 0);
      expect(ListDensity.cozy.previewLines, greaterThan(0));
      expect(
        ListDensity.comfortable.verticalPadding,
        greaterThan(ListDensity.compact.verticalPadding),
      );
    });

    test('choices persist across a restart', () {
      container().read(displayProvider.notifier)
        ..setDensity(ListDensity.comfortable)
        ..setReadingPane(ReadingPanePosition.bottom);

      final reloaded = container().read(displayProvider);
      expect(reloaded.density, ListDensity.comfortable);
      expect(reloaded.readingPane, ReadingPanePosition.bottom);
    });
  });

  group('View settings screen', () {
    testWidgets('choosing a density changes what the list shows',
        (tester) async {
      _useSize(tester, const Size(1400, 900));
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      final cozy = tester.widgetList<MessageTile>(find.byType(MessageTile));
      expect(cozy.first.density, ListDensity.cozy);

      c.read(displayProvider.notifier).setDensity(ListDensity.compact);
      await tester.pumpAndSettle();

      final compact = tester.widgetList<MessageTile>(find.byType(MessageTile));
      expect(compact.first.density, ListDensity.compact);
    });

    testWidgets('a compact row keeps the attachment and flag marks',
        (tester) async {
      // They live on the preview line, which compact does not draw, so
      // without moving them a compact list would hide them entirely.
      await tester.pumpWidget(app(const _TileHarness(ListDensity.compact)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      expect(find.byIcon(Icons.flag), findsOneWidget);
      expect(find.text('The preview line'), findsNothing);
    });

    testWidgets('a cozy row shows the preview and the marks', (tester) async {
      await tester.pumpWidget(app(const _TileHarness(ListDensity.cozy)));
      await tester.pumpAndSettle();

      expect(find.text('The preview line'), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
    });

    testWidgets('the screen offers every position and every density',
        (tester) async {
      _useSize(tester, const Size(900, 1400));
      await tester.pumpWidget(app(const ViewSettingsScreen()));
      await tester.pumpAndSettle();

      for (final p in ReadingPanePosition.values) {
        expect(find.text(p.label), findsOneWidget);
      }
      for (final d in ListDensity.values) {
        expect(find.text(d.label), findsOneWidget);
      }
    });

    testWidgets('a phone is told the reading pane setting will not show here',
        (tester) async {
      _useSize(tester, const Size(400, 900));
      await tester.pumpWidget(app(const ViewSettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('too narrow'), findsOneWidget);
    });
  });

  group('reading pane position', () {
    Future<void> pumpShell(WidgetTester tester, Size size,
        ReadingPanePosition position) async {
      _useSize(tester, size);
      final c = container();
      c.read(displayProvider.notifier).setReadingPane(position);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Right gives three panes on a wide screen', (tester) async {
      await pumpShell(tester, const Size(1400, 900), ReadingPanePosition.right);
      expect(find.byType(PaneDivider), findsNWidgets(2));
      expect(find.textContaining('Select a message'), findsOneWidget);
    });

    testWidgets('Off leaves the list full height and opens a screen instead',
        (tester) async {
      await pumpShell(tester, const Size(1400, 900), ReadingPanePosition.off);

      expect(find.textContaining('Select a message'), findsNothing);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
    });

    testWidgets('Bottom stacks the message under the list', (tester) async {
      await pumpShell(tester, const Size(1400, 900), ReadingPanePosition.bottom);

      expect(find.byType(PaneDivider), findsOneWidget,
          reason: 'only the folder edge is draggable when stacked');
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(ReadingPane), findsOneWidget);
      expect(find.byType(MessageScreen), findsNothing,
          reason: 'the pane shows it, so nothing is pushed');
    });

    testWidgets('Bottom works at tablet-portrait width, which is its point',
        (tester) async {
      await pumpShell(tester, const Size(800, 1280), ReadingPanePosition.bottom);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(ReadingPane), findsOneWidget);
    });

    testWidgets('Right on a screen too narrow for it opens a message screen',
        (tester) async {
      // Not stacked. A phone held sideways is about this wide and barely 400
      // tall, and splitting that horizontally leaves two halves too short to
      // use, so Right degrades to no pane and Bottom is the way to ask for one.
      await pumpShell(tester, const Size(800, 1280), ReadingPanePosition.right);

      expect(find.textContaining('Select a message'), findsNothing,
          reason: 'no pane at this width');
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
    });

    testWidgets('a phone ignores it and always opens a screen', (tester) async {
      await pumpShell(tester, const Size(400, 900), ReadingPanePosition.right);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
    });
  });

  group('conversations in the list', () {
    testWidgets('off by default, so every message has its own row',
        (tester) async {
      _useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(app(const AppShell()));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationTile), findsNothing);
      expect(find.byType(MessageTile), findsWidgets);
    });

    testWidgets('turning it on collapses replies onto one row', (tester) async {
      _useSize(tester, const Size(1400, 1600));
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.widgetList(find.byType(MessageTile)).length;

      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();

      final after = tester.widgetList(find.byType(MessageTile)).length;
      expect(find.byType(ConversationTile), findsWidgets,
          reason: 'the sample data has a thread in it');
      expect(after, lessThan(before));
    });

    testWidgets('tapping a conversation opens it and tapping again closes it',
        (tester) async {
      _useSize(tester, const Size(1400, 1600));
      final c = container();
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      final collapsed = tester.widgetList(find.byType(MessageTile)).length;
      await tester.tap(find.byType(ConversationTile).first);
      await tester.pumpAndSettle();
      expect(
        tester.widgetList(find.byType(MessageTile)).length,
        greaterThan(collapsed),
      );

      await tester.tap(find.byType(ConversationTile).first);
      await tester.pumpAndSettle();
      expect(tester.widgetList(find.byType(MessageTile)).length, collapsed);
    });

    testWidgets('the row says how many messages are inside', (tester) async {
      _useSize(tester, const Size(1400, 1600));
      final c = container();
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      final tile = tester.widget<ConversationTile>(
        find.byType(ConversationTile).first,
      );
      expect(tile.conversation.isThread, isTrue);
      expect(find.text('${tile.conversation.length}'), findsWidgets);
    });

    testWidgets('the toggle is on the View screen and says what it does',
        (tester) async {
      _useSize(tester, const Size(900, 1600));
      await tester.pumpWidget(app(const ViewSettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Group into conversations'), findsOneWidget);
    });
  });

  group('Settings hub', () {
    testWidgets('one entry in the tree replaces the loose ones',
        (tester) async {
      _useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(app(const AppShell()));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Quick Steps'), findsNothing);
      expect(find.text('Add account'), findsNothing);
    });

    testWidgets('each row says what is currently set', (tester) async {
      _useSize(tester, const Size(900, 1400));
      await tester.pumpWidget(app(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('Reading pane right'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget, reason: 'notifications are off');
    });

    testWidgets('View opens from the hub and changes take effect',
        (tester) async {
      _useSize(tester, const Size(900, 1400));
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compact'));
      await tester.pumpAndSettle();

      expect(c.read(displayProvider).density, ListDensity.compact);
    });
  });

  group('Signatures', () {
    test('a typed signature becomes HTML and comes back unchanged', () {
      const typed = 'Ron Dvir\nrdvir@example.com';
      final html = signatureTextToHtml(typed);
      expect(html, '<p>Ron Dvir<br>rdvir@example.com</p>');
      expect(htmlToSignatureText(html), typed);
    });

    test('angle brackets and ampersands survive the round trip', () {
      // A job title with an ampersand should not become an entity in the
      // message that gets sent.
      const typed = 'Sales & Marketing\n<ron@example.com>';
      final html = signatureTextToHtml(typed);
      expect(html, contains('&amp;'));
      expect(html, isNot(contains('<ron@')));
      expect(htmlToSignatureText(html), typed);
    });

    test('an empty signature is empty HTML, not an empty paragraph', () {
      expect(signatureTextToHtml('   \n  '), '');
      expect(htmlToSignatureText(''), '');
    });

    testWidgets('there is a box per account and typing in one saves it',
        (tester) async {
      _useSize(tester, const Size(900, 1400));
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: SignaturesScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(2),
          reason: 'the sample engine has two accounts');

      await tester.enterText(find.byType(TextField).first, 'Ron');
      await tester.pumpAndSettle();

      final saved = c.read(signaturesProvider);
      expect(saved.values.single.html, '<p>Ron</p>',
          reason: 'typing saves it; a settings screen needs no Save button');
    });
  });

  group('Accounts', () {
    testWidgets('every account is listed with a way to remove it',
        (tester) async {
      _useSize(tester, const Size(900, 1400));
      await tester.pumpWidget(app(const AccountsScreen()));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove'), findsNWidgets(2));
    });

    testWidgets('removing asks first and says what goes with it',
        (tester) async {
      _useSize(tester, const Size(900, 1400));
      await tester.pumpWidget(app(const AccountsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('app password'), findsOneWidget);
      expect(find.textContaining('Nothing is deleted from the mail server'),
          findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove'), findsNWidgets(2),
          reason: 'keeping changes nothing');
    });

    testWidgets('confirming removes it from the list', (tester) async {
      _useSize(tester, const Size(900, 1400));
      await tester.pumpWidget(app(const AccountsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove'), findsOneWidget);
    });
  });
}

/// One message row on its own, so a density can be checked without the shell.
class _TileHarness extends StatelessWidget {
  const _TileHarness(this.density);

  final ListDensity density;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MessageTile(
        density: density,
        isSelected: false,
        onTap: () {},
        message: _sample,
      ),
    );
  }
}

final _sample = MailMessage(
  id: 'a:INBOX#1',
  accountId: 'a',
  folderId: 'a:INBOX',
  uid: 1,
  subject: 'The subject line',
  from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
  to: const [MailAddress(email: 'me@example.com')],
  date: DateTime(2026, 9, 14, 9, 41),
  preview: 'The preview line',
  hasAttachments: true,
  isFlagged: true,
);
