import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/state/providers.dart';

/// Make an empty folder and move to it.
///
/// Opening a folder lands on its first message, so an empty reading pane is
/// no longer something a test can ask for by clearing the selection: the list
/// puts it straight back. A folder with nothing to land on is the honest way
/// to reach that state, and every folder in the sample data has mail in it,
/// so the test makes one.
Future<void> goToEmptyFolder(WidgetTester tester, ProviderContainer c) async {
  final accountId = c.read(accountsProvider).value!.first.id;
  // Pumped rather than simply awaited: the sample engine answers after a
  // short delay, and in a widget test the clock only moves when the tester
  // moves it, so awaiting on its own would wait for ever.
  final pending = c
      .read(foldersProvider.notifier)
      .create(accountId: accountId, name: 'Nothing here');
  await tester.pump(const Duration(seconds: 1));
  final folder = await pending;
  await tester.pumpAndSettle();

  c.read(selectedFolderIdProvider.notifier).select(folder.id);
  await tester.pumpAndSettle();
}
