import 'dart:convert';

import '../../domain/account.dart';
import '../../domain/display_settings.dart';
import '../../domain/quick_step.dart';
import '../../domain/settings_backup.dart';
import '../../domain/signature.dart';
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
    final knownIds = {for (final a in existing) a.id};

    final added = <Account>[];
    final skipped = <Account>[];
    // The file's account ids as this device knows the same mailboxes. The
    // same mailbox added separately on two devices has two ids, and the
    // settings came across under the other device's: favourites pointing
    // at an account that is not here, and a signature for nobody.
    final ids = <String, String>{};
    for (final account in backup.accounts) {
      final here = existing
          .where((a) =>
              a.emailAddress.toLowerCase() ==
              account.emailAddress.toLowerCase())
          .firstOrNull;
      if (here != null) {
        ids[account.id] = here.id;
        skipped.add(account);
        continue;
      }
      if (knownIds.contains(account.id)) {
        skipped.add(account);
        continue;
      }
      added.add(account);
    }
    // Settings of accounts in the file come from the file; those of this
    // device's other accounts stay as they are.
    final covered = {
      for (final account in backup.accounts) ids[account.id] ?? account.id,
    };
    String remap(String value) => _remap(value, ids);
    bool keep(String value) => !covered.contains(_accountOf(value));

    // Secrets before the account list, and taken out again if one will not
    // go in. The other way round, a Keystore write failing part way left
    // the rest of the accounts saved with no sign-in and no settings, and
    // Restore again counted them as already here and skipped their secrets.
    //
    // Only for accounts this restore adds, or ones already here with
    // nothing stored. An account already here with a secret keeps it: the
    // file's copy may be older than the one on the device, and an older
    // OAuth token may have run out, so writing it could sign a working
    // account out.
    var signedIn = 0;
    var signedInAgain = 0;
    final store = credentialStore;
    final written = <String>[];
    try {
      if (store != null) {
        for (final account in added) {
          final secret = secrets[account.id];
          if (secret == null || secret.isEmpty) continue;
          await store.writeSecret(account.id, secret);
          written.add(account.id);
        }
        signedIn = written.length;
      }
      if (added.isNotEmpty) {
        await accountStore.write([...existing, ...added]);
      }
    } catch (_) {
      for (final id in written) {
        try {
          await store!.deleteSecret(id);
        } catch (_) {
          // Nothing more can be done; the account it belongs to was never
          // saved, so nothing will use it.
        }
      }
      rethrow;
    }

    // An account already here with no sign-in stored, such as one an earlier
    // restore added before failing, takes the file's.
    if (store != null) {
      for (final account in skipped) {
        final secret = secrets[account.id];
        if (secret == null || secret.isEmpty) continue;
        final hereId = ids[account.id] ?? account.id;
        final current = await store.readSecret(hereId);
        if (current != null && current.isNotEmpty) continue;
        await store.writeSecret(hereId, secret);
        signedInAgain++;
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
          final here = uiState.readIds(key);
          await uiState.writeIds(key, {
            // Addresses, not ids: both lists count.
            if (key == UiStateKeys.trustedSenders)
              ...here
            else
              for (final v in here)
                if (keep(v)) v,
            for (final v in value)
              if (v is String) remap(v),
          });
        case _Shape.order:
          if (value is! Map) continue;
          await uiState.writeOrder(key, {
            for (final MapEntry(key: k, value: v)
                in uiState.readOrder(key).entries)
              if (keep(k)) k: v,
            for (final MapEntry(key: k, value: v) in value.entries)
              if (k is String && v is int) remap(k): v,
          });
        case _Shape.text:
          // Read the way the setting's own notifier will read it, and left
          // out if that fails. A hand-edited or damaged file with, say, "{}"
          // for the signatures was written as it was, and compose then
          // failed on every account until the app's data was cleared.
          if (value is! String || !_readable(key, value)) continue;
          await uiState.writeString(
            key,
            key == UiStateKeys.signatures
                ? _mergeSignatures(uiState.readString(key), value, ids, keep)
                : _remapText(value, ids),
          );
      }
      restored++;
    }

    return RestoreReport(
      accountsAdded: added,
      accountsAlreadyHere: skipped,
      settingsRestored: restored,
      accountsSignedIn: signedIn,
      accountsSignedInAgain: signedInAgain,
    );
  }
}

enum _Shape { ids, order, text }

/// Whether a setting kept as text is one this build can read.
bool _readable(String key, String value) {
  try {
    switch (key) {
      case UiStateKeys.quickSteps:
        return QuickStep.listFromJson(value) != null;
      case UiStateKeys.signatures:
        return Signature.mapFromJson(value) != null;
      case UiStateKeys.display:
        DisplaySettings.fromJson(jsonDecode(value) as Map<String, dynamic>);
        return true;
      case UiStateKeys.paneWidths:
        return (jsonDecode(value) as Map<String, dynamic>)
            .values
            .every((v) => v is int);
      default:
        return true;
    }
  } catch (_) {
    return false;
  }
}

/// Which account a stored id belongs to: the account id itself, or the
/// part of a folder id before its colon.
String _accountOf(String id) {
  final colon = id.indexOf(':');
  return colon < 0 ? id : id.substring(0, colon);
}

/// An account id, or a folder id under one, as this device knows it.
String _remap(String value, Map<String, String> ids) {
  final whole = ids[value];
  if (whole != null) return whole;
  final colon = value.indexOf(':');
  if (colon <= 0) return value;
  final account = ids[value.substring(0, colon)];
  return account == null ? value : '$account${value.substring(colon)}';
}

Object? _remapJson(Object? json, Map<String, String> ids) => switch (json) {
      final String s => _remap(s, ids),
      final List<Object?> l => [for (final v in l) _remapJson(v, ids)],
      final Map<Object?, Object?> m => {
          for (final MapEntry(:key, :value) in m.entries)
            (key is String ? _remap(key, ids) : key): _remapJson(value, ids),
        },
      _ => json,
    };

/// A setting kept as JSON text (Quick Steps, say), with every id in it as
/// this device knows it. Text that is not JSON is left as it is.
String _remapText(String text, Map<String, String> ids) {
  if (ids.isEmpty) return text;
  try {
    return jsonEncode(_remapJson(jsonDecode(text), ids));
  } on FormatException {
    return text;
  }
}

/// Signatures are one per account: the file's for its accounts, and this
/// device's own for the rest.
String _mergeSignatures(
  String? here,
  String fromFile,
  Map<String, String> ids,
  bool Function(String accountId) keep,
) {
  List<Object?> list(String? text) {
    if (text == null || text.isEmpty) return const [];
    try {
      final json = jsonDecode(text);
      return json is List ? json : const [];
    } on FormatException {
      return const [];
    }
  }

  final remapped = _remapJson(list(fromFile), ids) as List<Object?>;
  return jsonEncode([
    for (final s in list(here))
      if (s is Map && s['accountId'] is String && keep(s['accountId'] as String))
        s,
    ...remapped,
  ]);
}

/// What a restore actually did, so the screen can say so rather than claiming
/// success and leaving the person to work out what changed.
class RestoreReport {
  const RestoreReport({
    required this.accountsAdded,
    required this.accountsAlreadyHere,
    required this.settingsRestored,
    this.accountsSignedIn = 0,
    this.accountsSignedInAgain = 0,
  });

  /// Added by this restore.
  final List<Account> accountsAdded;

  /// How many of those came with a working sign-in out of the file.
  final int accountsSignedIn;

  /// Already on this device, left with their working sign-in.
  final List<Account> accountsAlreadyHere;

  /// How many of those had no sign-in stored here and took the file's.
  final int accountsSignedInAgain;

  final int settingsRestored;

  /// Accounts that are here but cannot connect until someone signs them in.
  int get awaitingSignIn => accountsAdded.length - accountsSignedIn;

  bool get needsSignIn => awaitingSignIn > 0;
}
