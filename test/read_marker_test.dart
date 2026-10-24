import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/read_marker.dart';

/// When an opened message counts as read: Outlook's Reading Pane options,
/// under Settings, View.
void main() {
  late ProviderContainer c;
  late List<String> marked;

  ReadMarker marker(MarkReadWhen when) {
    c.read(displayProvider.notifier).setMarkRead(when);
    return c.read(readMarkerProvider);
  }

  Future<void> Function() mark(String id) => () async => marked.add(id);

  setUp(() {
    c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
    );
    marked = [];
  });
  tearDown(() => c.dispose());

  test('when it opens, at once, as the app always did', () {
    marker(MarkReadWhen.opened).opened('a', mark: mark('a'));
    expect(marked, ['a']);
  });

  testWidgets('after five seconds, and not if left before', (tester) async {
    final m = marker(MarkReadWhen.afterDelay);
    m.opened('a', mark: mark('a'));
    await tester.pump(const Duration(seconds: 4));
    expect(marked, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(marked, ['a']);

    m.opened('b', mark: mark('b'));
    await tester.pump(const Duration(seconds: 2));
    m.left('b');
    await tester.pump(const Duration(seconds: 10));
    expect(marked, ['a'], reason: 'b was closed before its five seconds');
  });

  test('when I move on: the one before, when another opens or it closes', () {
    final m = marker(MarkReadWhen.leaving);
    m.opened('a', mark: mark('a'));
    expect(marked, isEmpty);
    m.opened('b', mark: mark('b'));
    expect(marked, ['a']);
    m.left('b');
    expect(marked, ['a', 'b']);
  });

  test('moving on to a message already read still counts', () {
    final m = marker(MarkReadWhen.leaving);
    m.opened('a', mark: mark('a'));
    m.opened('b');
    expect(marked, ['a']);
  });

  test('never: only by hand', () {
    final m = marker(MarkReadWhen.never);
    m.opened('a', mark: mark('a'));
    m.left('a');
    expect(marked, isEmpty);
  });

  test('the row and the pane opening one message are one opening', () {
    final m = marker(MarkReadWhen.opened);
    m.opened('a', mark: mark('a'));
    m.opened('a', mark: mark('a'));
    expect(marked, ['a']);
  });

  test('the setting is kept, and an old record reads as When it opens', () {
    const chosen = DisplaySettings(markRead: MarkReadWhen.leaving);
    expect(DisplaySettings.fromJson(chosen.toJson()).markRead,
        MarkReadWhen.leaving);
    expect(DisplaySettings.fromJson(const {}).markRead, MarkReadWhen.opened);
  });
}
