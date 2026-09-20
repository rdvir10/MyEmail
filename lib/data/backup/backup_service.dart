import '../../domain/account.dart';
import '../../domain/settings_backup.dart';
import '../account_store.dart';
import '../credential_store.dart';
import '../ui_state_store.dart';
import 'secret_vault.dart';

/// Reads the app's settings into a [SettingsBackup], and puts one back.
///
/// Kept apart from the UI and from any file picker, so both directions can be
/// tested against in-memory stores with no disk and no platform channel.
class BackupService {
  const BackupService({
    required this.accountStore,
    required this.uiState,
    this.credentialStore,
    this.vault = const SecretVault(),
    this.appVersion,
    this.now,
  });

  final AccountStore accountStore;
  final UiStateStore uiState;

  /// Only ever touched when a passphrase is given. Without one, the export
  /// path never reads a secret, so a plain backup cannot leak one even by
  /// mistake.
  final CredentialStore? credentialStore;

  final SecretVault vault;
  final String? appVersion;
  final DateTime Function()? now;

  /// Every key worth carrying between devices, and what shape each holds.
  ///
  /// A fixed list rather than "whatever is in shared_preferences". Two reasons
  /// it has to be: the store has no way to enumerate keys, and sweeping up
  /// everything would take the message-cache bookkeeping and the notification
  /// watermarks with it. A watermark restored onto another device says mail
  /// it has never seen has already been announced, so the first sync there
  /// would go silent.
  static const exported = <String, _Shape>{
    UiStateKeys.expanded: _Shape.ids,
    UiStateKeys.favorites: _Shape.ids,
    UiStateKeys.hidden: _Shape.ids,
    UiStateKeys.collapsedAccounts: _Shape.ids,
    UiStateKeys.order: _Shape.order,
    UiStateKeys.quickSteps: _Shape.text,
    UiStateKeys.signatures: _Shape.text,
    UiStateKeys.paneWidths: _Shape.text,
    UiStateKeys.folderPane: _Shape.text,
    UiStateKeys.display: _Shape.text,
    UiStateKeys.trustedSenders: _Shape.ids,
    // Deliberately absent: UiStateKeys.selected, which is where you happened
    // to be standing, and UiStateKeys.recentMoves, which is a short history
    // rather than a setting. Neither is worth carrying and both would be odd
    // to find waiting on a new device.
  };

  /// Read everything into a backup.
  ///
  /// With [passphrase], the accounts' stored secrets are encrypted into the
  /// file so a restore needs no sign-in. Without one, no secret is read at
  /// all.
  Future<SettingsBackup> export({String? passphrase}) async {
    final entries = <String, Object?>{};
    for (final MapEntry(key: key, value: shape) in exported.entries) {
      switch (shape) {
        case _Shape.ids:
          final ids = uiState.readIds(key);
          if (ids.isNotEmpty) entries[key] = ids.toList()..sort();
        case _Shape.order:
          final order = uiState.readOrder(key);
          if (order.isNotEmpty) entries[key] = order;
        case _Shape.text:
          final text = uiState.readString(key);
          if (text != null && text.isNotEmpty) entries[key] = text;
      }
    }

    final accounts = accountStore.read();

    Map<String, Object?>? sealed;
    if (passphrase != null) {
      final store = credentialStore;
      if (store == null) {
        throw StateError('No credential store to read secrets from');
      }
      final secrets = <String, String>{};
      for (final account in accounts) {
        final secret = await store.readSecret(account.id);
        // An account with nothing stored is one that was never signed in, or
        // was signed out. Writing an empty value would restore a broken
        // sign-in that looks like a working one.
        if (secret != null && secret.isNotEmpty) secrets[account.id] = secret;
      }
      sealed = await vault.seal(secrets: secrets, passphrase: passphrase);
    }

    return SettingsBackup(
      accounts: accounts,
      entries: entries,
      sealedSecrets: sealed,
      exportedAt: (now ?? DateTime.now)(),
      appVersion: appVersion,
    );
  }

  /// Apply a backup over whatever is here now.
  ///
  /// Accounts already set up on this device are kept as they are rather than
  /// overwritten: the one on the device has a working secret behind it, and
  /// the one in the file does not, so preferring the file would sign a working
  /// account out. Matching is by address rather than by id, because the same
  /// mailbox added separately on two devices has two different ids.
  /// [passphrase] is required when the file carries secrets, and ignored
  /// when it does not.
  Future<RestoreReport> import(
    SettingsBackup backup, {
    String? passphrase,
  }) async {
    // Decrypt before writing anything. A wrong passphrase must leave the
    // device untouched rather than half-restored with no sign-ins.
    Map<String, String> secrets = const {};
    final sealed = backup.sealedSecrets;
    if (sealed != null && passphrase != null) {
      secrets = await vault.open(sealed: sealed, passphrase: passphrase);
    }

    final existing = accountStore.read();
    final knownAddresses = {
      for (final a in existing) a.emailAddress.toLowerCase(),
    };
    final knownIds = {for (final a in existing) a.id};

    final added = <Account>[];
    final skipped = <Account>[];
    for (final account in backup.accounts) {
      if (knownAddresses.contains(account.emailAddress.toLowerCase()) ||
          knownIds.contains(account.id)) {
        skipped.add(account);
        continue;
      }
      added.add(account);
    }

    if (added.isNotEmpty) {
      await accountStore.write([...existing, ...added]);
    }

    // Secrets only for accounts this restore actually added. An account
    // already here has a secret that works, and the file's copy may be older
    // than the one on the device — a rotated OAuth refresh token in
    // particular would be dead, so writing it would sign a working account
    // out.
    var signedIn = 0;
    final store = credentialStore;
    if (store != null) {
      for (final account in added) {
        final secret = secrets[account.id];
        if (secret == null || secret.isEmpty) continue;
        await store.writeSecret(account.id, secret);
        signedIn++;
      }
    }

    var restored = 0;
    for (final MapEntry(key: key, value: value) in backup.entries.entries) {
      final shape = exported[key];
      // A key this build does not know about is from a newer version. Writing
      // it blind could put a value of the wrong shape where a notifier expects
      // to read one, so it is left alone.
      if (shape == null) continue;
      switch (shape) {
        case _Shape.ids:
          if (value is! List) continue;
          await uiState.writeIds(key, {
            for (final v in value)
              if (v is String) v,
          });
        case _Shape.order:
          if (value is! Map) continue;
          await uiState.writeOrder(key, {
            for (final MapEntry(key: k, value: v) in value.entries)
              if (k is String && v is int) k: v,
          });
        case _Shape.text:
          if (value is! String) continue;
          await uiState.writeString(key, value);
      }
      restored++;
    }

    return RestoreReport(
      accountsAdded: added,
      accountsAlreadyHere: skipped,
      settingsRestored: restored,
      accountsSignedIn: signedIn,
    );
  }
}

enum _Shape { ids, order, text }

/// What a restore actually did, so the screen can say so rather than claiming
/// success and leaving the person to work out what changed.
class RestoreReport {
  const RestoreReport({
    required this.accountsAdded,
    required this.accountsAlreadyHere,
    required this.settingsRestored,
    this.accountsSignedIn = 0,
  });

  /// Added by this restore.
  final List<Account> accountsAdded;

  /// How many of those came with a working sign-in out of the file.
  final int accountsSignedIn;

  /// Already on this device, left with their working sign-in.
  final List<Account> accountsAlreadyHere;

  final int settingsRestored;

  /// Accounts that are here but cannot connect until someone signs them in.
  int get awaitingSignIn => accountsAdded.length - accountsSignedIn;

  bool get needsSignIn => awaitingSignIn > 0;
}
