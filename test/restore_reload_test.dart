import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/backup_providers.dart';
import 'package:myemail/state/providers.dart';

/// What the screens show after a restore has written under them.
void main() {
  testWidgets('a restored setting is what shows, and what a change keeps',
      (tester) async {
    // The notifier read the store once. It went on showing the old
    // favourites, and the next star wrote them back over the restored ones.
    final store = MemoryUiStateStore();
    await store.writeIds(UiStateKeys.favorites, {'a:Old'});
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [uiStateStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Consumer(builder: (context, r, _) {
          ref = r;
          r.watch(favoriteFoldersProvider);
          return const SizedBox();
        }),
      ),
    ));
    expect(ref.read(favoriteFoldersProvider), {'a:Old'});

    await store.writeIds(UiStateKeys.favorites, {'a:Restored'}); // the restore
    reloadRestoredSettings(ref);
    await tester.pump();

    expect(ref.read(favoriteFoldersProvider), {'a:Restored'});
    ref.read(favoriteFoldersProvider.notifier).toggle('a:New');
    await tester.pump();
    expect(store.readIds(UiStateKeys.favorites), {'a:Restored', 'a:New'});
  });
}
