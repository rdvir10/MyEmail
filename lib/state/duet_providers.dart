import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/duet/duet_uploader.dart';
import '../data/ui_state_store.dart';
import '../domain/duet_settings.dart';
import 'providers.dart';

/// Settings, Claude (Duet), kept where the background worker reads them.
class DuetSettingsNotifier extends Notifier<DuetSettings> {
  @override
  DuetSettings build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(UiStateKeys.duet, next.toJson()));
    return DuetSettings.fromJson(store.readString(UiStateKeys.duet));
  }

  void setEnabled(bool on) => state = state.copyWith(enabled: on);

  void setServer(String server) => state = state.copyWith(
        server: server.trim().isEmpty ? DuetSettings.defaultServer : server.trim(),
      );

  /// [accountId] sent or not; ticked the first time, Hadco's address starts
  /// read-once.
  void setSent(String accountId, bool sent, {required String address}) {
    final accounts = {...state.accounts};
    final readOnce = {...state.readOnce};
    if (sent) {
      if (accounts.add(accountId) && DuetSettings.readOnceByDefault(address)) {
        readOnce.add(accountId);
      }
    } else {
      accounts.remove(accountId);
      readOnce.remove(accountId);
    }
    state = state.copyWith(accounts: accounts, readOnce: readOnce);
  }

  void setReadOnce(String accountId, bool once) => state = state.copyWith(
        readOnce: once
            ? {...state.readOnce, accountId}
            : ({...state.readOnce}..remove(accountId)),
      );

  /// [accountIds] removed from the app: no longer sent, so the next pass
  /// clears them from the connector. Left ticked, Settings went on counting
  /// them, and the Duet screen, which lists only the accounts there now,
  /// could not untick them.
  void forget(Set<String> accountIds) {
    if (!accountIds.any(state.accounts.contains) &&
        !accountIds.any(state.readOnce.contains)) {
      return;
    }
    state = state.copyWith(
      accounts: state.accounts.difference(accountIds),
      readOnce: state.readOnce.difference(accountIds),
    );
  }
}

final duetSettingsProvider =
    NotifierProvider<DuetSettingsNotifier, DuetSettings>(DuetSettingsNotifier.new);

/// The uploader, with the app's engine and stores; a test's own client in
/// tests.
final duetUploaderProvider = Provider<DuetUploader>((ref) => DuetUploader(
      engine: ref.watch(mailEngineProvider),
      ui: ref.watch(uiStateStoreProvider),
      secrets: ref.watch(credentialStoreProvider),
    ));
