import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Encrypts the account secrets inside a backup file with a passphrase.
///
/// AES-256-GCM, with the key derived from the passphrase by PBKDF2-HMAC-SHA256.
/// Nothing here is invented: the passphrase never becomes a key directly, the
/// salt and nonce are random per file, and GCM authenticates the ciphertext so
/// a file someone has edited fails to open rather than decrypting to rubbish.
///
/// The threat this defends against is specific and worth stating, because it
/// shapes the choices below. The file is meant to travel — a cloud folder, a
/// USB stick, an email to yourself — so assume it will be read by someone it
/// was not meant for. What protects it then is only the passphrase, which is
/// why the iteration count is high enough to make guessing expensive and why
/// a weak passphrase is refused up front rather than quietly accepted.
///
/// What this cannot defend against is a passphrase in a password manager that
/// also holds the mail account. That is the person's call, not the app's, and
/// [VaultStrength] is there so the screen can at least be honest about it.
class SecretVault {
  const SecretVault({this.iterations = defaultIterations, this.random});

  /// Cost of turning the passphrase into a key.
  ///
  /// This runs in pure Dart on a tablet, once per export and once per
  /// restore, so it is bounded by patience rather than by security alone.
  /// 120,000 lands under a second on the hardware this app runs on while
  /// still making an offline guessing run expensive. Stored in the file, so
  /// raising it later does not strand files written today.
  static const defaultIterations = 120000;

  /// Shortest passphrase this will encrypt with.
  ///
  /// Eight would match most password rules and would be wrong here: those
  /// rules assume a server that locks out after a few tries, and a file has
  /// no such limit. Length is the only thing that helps offline.
  static const minimumPassphraseLength = 12;

  final int iterations;

  /// Overridden only by tests, which need repeatable salts and nonces.
  /// Production always uses [Random.secure]; a predictable nonce with a reused
  /// key is the one mistake AES-GCM does not survive.
  final Random? random;

  Random get _rng => random ?? Random.secure();

  /// Encrypt [secrets], a map of account id to that account's stored secret.
  Future<Map<String, Object?>> seal({
    required Map<String, String> secrets,
    required String passphrase,
  }) async {
    // The same rule the dialog shows, so a passphrase it would not accept
    // cannot get in by another route.
    final strength = VaultStrength.of(passphrase);
    if (strength == VaultStrength.tooShort) {
      throw const VaultPassphraseTooShort();
    }
    if (strength == VaultStrength.tooSimple) {
      throw const VaultPassphraseTooSimple();
    }

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt, iterations);

    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(secrets)),
      secretKey: key,
      nonce: nonce,
    );

    return {
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': iterations,
      'salt': base64Encode(salt),
      'cipher': 'aes-gcm-256',
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// Decrypt what [seal] produced.
  ///
  /// Throws [VaultWrongPassphrase] when the passphrase does not open the file,
  /// which is also what a tampered or truncated file looks like — GCM cannot
  /// tell the two apart, and neither can the person, so they get one message
  /// that covers both.
  Future<Map<String, String>> open({
    required Map<String, Object?> sealed,
    required String passphrase,
  }) async {
    final kdf = sealed['kdf'];
    final cipher = sealed['cipher'];
    if (kdf != 'pbkdf2-hmac-sha256' || cipher != 'aes-gcm-256') {
      throw const VaultUnreadable(
        'This backup was protected in a way this version does not understand. '
        'Update the app and try again.',
      );
    }

    final int rounds;
    final List<int> salt;
    final List<int> nonce;
    final List<int> ciphertext;
    final List<int> mac;
    try {
      rounds = sealed['iterations'] as int;
      salt = base64Decode(sealed['salt'] as String);
      nonce = base64Decode(sealed['nonce'] as String);
      ciphertext = base64Decode(sealed['ciphertext'] as String);
      mac = base64Decode(sealed['mac'] as String);
    } catch (_) {
      throw const VaultUnreadable(
        'The protected part of this backup is damaged.',
      );
    }

    // A file could name an absurd iteration count and freeze the app for
    // minutes before failing. Ours is 120,000; anything far beyond that is not
    // a file we wrote.
    if (rounds < 1000 || rounds > 2000000) {
      throw const VaultUnreadable(
        'The protected part of this backup is damaged.',
      );
    }

    final key = await _deriveKey(passphrase, salt, rounds);

    final List<int> plain;
    try {
      plain = await AesGcm.with256bits().decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
    } on SecretBoxAuthenticationError {
      throw const VaultWrongPassphrase();
    }

    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map) throw const FormatException();
      return {
        for (final MapEntry(key: k, value: v) in decoded.entries)
          if (k is String && v is String) k: v,
      };
    } on FormatException {
      // The MAC passed, so the passphrase was right and the bytes are intact;
      // the contents are simply not what we expect. Different failure, and it
      // must not be reported as a wrong passphrase.
      throw const VaultUnreadable(
        'The backup opened, but the sign-in details inside were not readable.',
      );
    }
  }

  static Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt,
    int rounds,
  ) =>
      Pbkdf2.hmacSha256(iterations: rounds, bits: 256)
          .deriveKeyFromPassword(password: passphrase, nonce: salt);

  List<int> _randomBytes(int count) =>
      [for (var i = 0; i < count; i++) _rng.nextInt(256)];
}

/// How much a passphrase is actually worth, for the export screen.
///
/// Not a score out of four dressed up as security. The only question that
/// matters for a file someone may keep forever is how long it would take to
/// guess, and for that, length beats character classes.
enum VaultStrength {
  tooShort('Too short', 'At least 12 characters.'),
  tooSimple('Too simple', 'One character over and over is guessed at once.'),
  weak('Weak', 'Longer would be much harder to guess.'),
  fair('Fair', 'Reasonable. A few more words would be better.'),
  strong('Strong', 'Good. Keep it somewhere you will not lose it.');

  const VaultStrength(this.label, this.advice);

  final String label;
  final String advice;

  /// Whether a backup may be sealed with this passphrase at all.
  bool get refused => this == tooShort || this == tooSimple;

  static VaultStrength of(String passphrase) {
    // Measured without the spaces at either end, which add nothing a guesser
    // has to find. Counting them let twelve spaces through.
    final trimmed = passphrase.trim();
    if (trimmed.length < SecretVault.minimumPassphraseLength) {
      return VaultStrength.tooShort;
    }
    if (trimmed.replaceAll(RegExp(r'\s'), '').runes.toSet().length < 2) {
      return VaultStrength.tooSimple;
    }
    // Word count matters more than symbols: four ordinary words beat one word
    // with a digit and a punctuation mark stuck on the end, and people can
    // actually remember them. Only words of three letters or more count, or
    // 'a b c d e f g' would be four words and more.
    final words = trimmed
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 3)
        .length;
    if (trimmed.length >= 24 || words >= 4) return VaultStrength.strong;
    if (trimmed.length >= 16 || words >= 3) return VaultStrength.fair;
    return VaultStrength.weak;
  }
}

/// A passphrase [SecretVault.seal] will not use.
@immutable
sealed class VaultPassphraseRefused implements Exception {
  const VaultPassphraseRefused();
  String get message;
  @override
  String toString() => message;
}

class VaultPassphraseTooShort extends VaultPassphraseRefused {
  const VaultPassphraseTooShort();
  @override
  String get message =>
      'Use at least ${SecretVault.minimumPassphraseLength} characters. A '
      'backup file can be guessed at forever, so length is what protects it.';
}

class VaultPassphraseTooSimple extends VaultPassphraseRefused {
  const VaultPassphraseTooSimple();
  @override
  String get message =>
      'One character over and over is among the first things tried, and a '
      'backup file can be guessed at forever. Use words, not a pattern.';
}

@immutable
class VaultWrongPassphrase implements Exception {
  const VaultWrongPassphrase();
  String get message =>
      'That passphrase does not open this backup. If it is definitely right, '
      'the file may have been damaged in transit.';
  @override
  String toString() => message;
}

@immutable
class VaultUnreadable implements Exception {
  const VaultUnreadable(this.message);
  final String message;
  @override
  String toString() => message;
}
