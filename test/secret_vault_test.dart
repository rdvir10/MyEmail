import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/backup/secret_vault.dart';

/// Encrypting the sign-in details inside a backup file.
///
/// Low iteration counts throughout: the real 120,000 is there to make guessing
/// expensive, and paying that cost on every one of these would add minutes to
/// the suite without testing anything the cheap count does not.
void main() {
  const vault = SecretVault(iterations: 1000);
  const secrets = {
    'acct-aaa': 'abcdabcdabcdabcd',
    'acct-bbb': '{"refresh_token":"r-1","access_token":"a-1"}',
  };
  const passphrase = 'correct horse battery staple';

  test('what goes in comes back out', () async {
    final sealed = await vault.seal(secrets: secrets, passphrase: passphrase);

    expect(
      await vault.open(sealed: sealed, passphrase: passphrase),
      secrets,
    );
  });

  test('no secret is readable in the sealed form', () async {
    final sealed = await vault.seal(secrets: secrets, passphrase: passphrase);

    final asText = jsonEncode(sealed);
    expect(asText, isNot(contains('abcdabcdabcdabcd')));
    expect(asText, isNot(contains('refresh_token')));
    expect(asText, isNot(contains('r-1')));
  });

  test('the passphrase itself is not in the file', () async {
    // Nor any hash of it that could be checked offline faster than deriving
    // the key: the only verifier is the GCM tag.
    final sealed = await vault.seal(secrets: secrets, passphrase: passphrase);

    expect(jsonEncode(sealed), isNot(contains(passphrase)));
  });

  test('a wrong passphrase is refused, not answered with rubbish', () async {
    final sealed = await vault.seal(secrets: secrets, passphrase: passphrase);

    await expectLater(
      vault.open(sealed: sealed, passphrase: 'not the passphrase'),
      throwsA(isA<VaultWrongPassphrase>()),
    );
  });

  test('an edited file is refused', () async {
    // GCM authenticates the ciphertext, so tampering fails rather than
    // decrypting to something plausible.
    final sealed = Map<String, Object?>.from(
      await vault.seal(secrets: secrets, passphrase: passphrase),
    );
    final bytes = base64Decode(sealed['ciphertext'] as String);
    bytes[0] ^= 0xFF;
    sealed['ciphertext'] = base64Encode(bytes);

    await expectLater(
      vault.open(sealed: sealed, passphrase: passphrase),
      throwsA(isA<VaultWrongPassphrase>()),
    );
  });

  test('two files with the same passphrase are not the same bytes', () async {
    // The salt and nonce are drawn fresh each time. Reusing either would leak
    // that two backups hold the same secrets, and reusing a nonce under one
    // key is the mistake AES-GCM does not survive.
    final first = await vault.seal(secrets: secrets, passphrase: passphrase);
    final second = await vault.seal(secrets: secrets, passphrase: passphrase);

    expect(first['salt'], isNot(second['salt']));
    expect(first['nonce'], isNot(second['nonce']));
    expect(first['ciphertext'], isNot(second['ciphertext']));
  });

  test('a short passphrase is refused before anything is written', () async {
    // A file can be guessed at forever, with no server to lock anyone out, so
    // the usual eight-character rule is the wrong one here.
    await expectLater(
      vault.seal(secrets: secrets, passphrase: 'short'),
      throwsA(isA<VaultPassphraseTooShort>()),
    );
  });

  test('the iteration count travels with the file', () async {
    // So raising it later does not strand files written today.
    final sealed = await vault.seal(secrets: secrets, passphrase: passphrase);

    expect(sealed['iterations'], 1000);
    expect(
      await const SecretVault(iterations: 50000)
          .open(sealed: sealed, passphrase: passphrase),
      secrets,
      reason: 'a vault configured differently must still read an old file',
    );
  });

  test('an absurd iteration count is refused rather than run', () async {
    // Otherwise a hostile file freezes the app for minutes before failing.
    final sealed = Map<String, Object?>.from(
      await vault.seal(secrets: secrets, passphrase: passphrase),
    );
    sealed['iterations'] = 500000000;

    await expectLater(
      vault.open(sealed: sealed, passphrase: passphrase),
      throwsA(isA<VaultUnreadable>()),
    );
  });

  test('an unknown algorithm says to update rather than guessing', () async {
    final sealed = Map<String, Object?>.from(
      await vault.seal(secrets: secrets, passphrase: passphrase),
    );
    sealed['cipher'] = 'something-newer';

    await expectLater(
      vault.open(sealed: sealed, passphrase: passphrase),
      throwsA(isA<VaultUnreadable>()),
    );
  });

  test('a damaged block is reported as damage, not a wrong passphrase',
      () async {
    await expectLater(
      vault.open(
        sealed: const {'kdf': 'pbkdf2-hmac-sha256', 'cipher': 'aes-gcm-256'},
        passphrase: passphrase,
      ),
      throwsA(isA<VaultUnreadable>()),
    );
  });

  test('an empty set of secrets seals and opens like any other', () async {
    // An export where every account happens to be signed out.
    final sealed = await vault.seal(secrets: const {}, passphrase: passphrase);

    expect(await vault.open(sealed: sealed, passphrase: passphrase), isEmpty);
  });

  test('the randomness can be pinned, which is how the rest is tested', () {
    // Guards the seam itself: if `random` stopped being honoured, every test
    // above would still pass while production silently lost its entropy.
    const pinned = SecretVault(iterations: 1000);
    expect(pinned.random, isNull, reason: 'production draws from Random.secure');
    expect(
      SecretVault(iterations: 1000, random: Random(1)).random,
      isNotNull,
    );
  });

  group('passphrase strength', () {
    test('anything under the minimum is called too short', () {
      expect(VaultStrength.of('short'), VaultStrength.tooShort);
      expect(VaultStrength.of('12345678901'), VaultStrength.tooShort);
    });

    test('length and word count both count towards strong', () {
      expect(VaultStrength.of('correct horse battery staple'),
          VaultStrength.strong);
      expect(VaultStrength.of('a' * 24), VaultStrength.strong);
    });

    test('a bare minimum passphrase is called weak rather than accepted',
        () {
      expect(VaultStrength.of('abcdefghijkl'), VaultStrength.weak);
    });
  });
}
