import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/backup/backup_service.dart';
import '../data/ui_state_store.dart';
import '../ui/settings/backup_screen.dart';
import 'compose_providers.dart' show signaturesProvider;
import 'display_providers.dart';
import 'pane_widths.dart';
import 'providers.dart';
import 'quick_steps.dart';
import 'trusted_senders.dart';

/// Reading the app's settings out and putting them back.
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    accountStore: ref.watch(accountStoreProvider),
    uiState: ref.watch(uiStateStoreProvider),
    credentialStore: ref.watch(credentialStoreProvider),
  );
});

/// Where a backup file is written and read.
///
/// Overridden in tests with one that keeps the file in memory: the real one
/// opens Android's document picker, which a widget test cannot answer.
final backupFilesProvider =
    Provider<BackupFiles>((ref) => const PlatformBackupFiles());

/// The accounts list, for invalidating after a restore has written straight
/// to the store underneath it.
///
/// Aliased rather than used directly so the import path reads as what it is:
/// the restore goes around the notifier, so the notifier has to be told.
final accountsProviderForRefresh = accountsProvider;

/// The settings keys [reloadRestoredSettings] brings back in, one for each of
/// [BackupService.exported]. A test holds the two lists together.
const reloadedAfterRestore = {
  UiStateKeys.expanded,
  UiStateKeys.favorites,
  UiStateKeys.hidden,
  UiStateKeys.collapsedAccounts,
  UiStateKeys.order,
  UiStateKeys.quickSteps,
  UiStateKeys.signatures,
  UiStateKeys.paneWidths,
  UiStateKeys.folderPane,
  UiStateKeys.display,
  UiStateKeys.trustedSenders,
};

/// Every setting a restore wrote, read again from where it was written.
///
/// A restore writes to the store underneath the notifiers, each of which
/// read it once and writes its whole state back on any change. So the old
/// favourites and view went on showing, and the next star or divider drag
/// wrote them back over what had just been restored.
void reloadRestoredSettings(WidgetRef ref) {
  ref
    ..invalidate(expandedFoldersProvider)
    ..invalidate(favoriteFoldersProvider)
    ..invalidate(hiddenFoldersProvider)
    ..invalidate(collapsedAccountsProvider)
    ..invalidate(folderOrderProvider)
    ..invalidate(quickStepsProvider)
    ..invalidate(signaturesProvider)
    ..invalidate(paneWidthsProvider)
    ..invalidate(folderPaneVisibleProvider)
    ..invalidate(displayProvider)
    ..invalidate(trustedSendersProvider);
}
