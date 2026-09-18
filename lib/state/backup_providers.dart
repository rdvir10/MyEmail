import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/backup/backup_service.dart';
import '../ui/settings/backup_screen.dart';
import 'providers.dart';

/// Reading the app's settings out and putting them back.
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    accountStore: ref.watch(accountStoreProvider),
    uiState: ref.watch(uiStateStoreProvider),
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
