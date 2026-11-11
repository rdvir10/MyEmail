import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth/microsoft_oauth.dart' show SignInExpired;
import '../data/ui_state_store.dart';
import '../domain/account.dart';
import '../domain/password_expiry.dart';
import 'message_keeping.dart' show notRetried;
import 'providers.dart';
import 'sync_providers.dart' show mailNotifierProvider;

/// Whether Microsoft can say when [account]'s password was changed: a
/// Microsoft account signed in on its own. A shared mailbox has no password
/// of its own, and an app password reaches mail and nothing else.
bool hasOwnMicrosoftPassword(Account account) =>
    account.provider == MailProvider.outlook &&
    account.authMethod == AuthMethod.oauth &&
    !account.isShared;

/// Where a Microsoft work account's password is changed, where its
/// organisation lets it be changed online.
final changePasswordPage =
    Uri.parse('https://mysignins.microsoft.com/security-info/password/change');

/// The time, as the password lines see it: a test's own.
final passwordClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// How many days each account's password lasts, by account id: the
/// organisation's rule, typed in on the account's settings. Absent,
/// [PasswordExpiry.defaultDays]; 0 for never.
class PasswordDays extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() =>
      ref.watch(uiStateStoreProvider).readOrder(UiStateKeys.passwordDays);

  int of(String accountId) => state[accountId] ?? PasswordExpiry.defaultDays;

  void set(String accountId, int days) {
    final next = {...state}..remove(accountId);
    if (days != PasswordExpiry.defaultDays) next[accountId] = days;
    state = next;
    ref.read(uiStateStoreProvider).writeOrder(UiStateKeys.passwordDays, next);
  }
}

final passwordDaysProvider =
    NotifierProvider<PasswordDays, Map<String, int>>(PasswordDays.new);

/// What Microsoft says about [accountId]'s password. Kept for the app's
/// life, and read again by [PasswordKeeper.keepUp]. Throws
/// `SignInNeedsConsent` for an account that has not allowed its profile to
/// be read. Not retried: the answer to a refusal is a sign-in.
final passwordAgeProvider = FutureProvider.family<PasswordAge, String>(
  (ref, accountId) => ref.watch(mailEngineProvider).passwordAge(accountId),
  retry: notRetried,
);

/// When each account's password was last changed, by account id, where
/// Microsoft keeps no date for it: put in on the account's settings, or
/// taken from Microsoft signing the app out after a change. A user whose
/// password lives on the organisation's own servers (Hadco's) has none in
/// Microsoft's cloud.
class PasswordChangedDates extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() =>
      ref.watch(uiStateStoreProvider).readOrder(UiStateKeys.passwordChanged);

  DateTime? of(String accountId) => switch (state[accountId]) {
        final s? => DateTime.fromMillisecondsSinceEpoch(s * 1000),
        null => null,
      };

  void set(String accountId, DateTime? at) {
    final next = {...state}..remove(accountId);
    if (at != null) next[accountId] = at.millisecondsSinceEpoch ~/ 1000;
    state = next;
    ref
        .read(uiStateStoreProvider)
        .writeOrder(UiStateKeys.passwordChanged, next);
  }

  /// Microsoft signed [accountId] out at [at] after what looks like a
  /// password change. Taken only where it is later than the date held:
  /// the same refusal comes again on every try until the account signs in.
  void signedOutAt(String accountId, DateTime at) {
    final held = of(accountId);
    if (held != null && !at.isAfter(held.add(const Duration(minutes: 1)))) {
      return;
    }
    debugPrint('[myemail] password changed, by the sign-out: $at');
    set(accountId, at);
  }
}

final passwordChangedProvider =
    NotifierProvider<PasswordChangedDates, Map<String, int>>(
        PasswordChangedDates.new);

/// [age] with the date put in here where Microsoft keeps none.
PasswordAge passwordAgeWith(PasswordAge age, DateTime? putIn) =>
    age.lastChanged != null || putIn == null
        ? age
        : PasswordAge(lastChanged: putIn, neverExpires: age.neverExpires);

/// When [accountId]'s password runs out; null where that cannot be said.
/// Microsoft's date where it has one, the one put in here otherwise, even
/// while Microsoft cannot be asked.
final passwordExpiryProvider =
    Provider.family<PasswordExpiry?, String>((ref, accountId) {
  final asked = ref.watch(passwordAgeProvider(accountId));
  ref.watch(passwordChangedProvider);
  final putIn = ref.read(passwordChangedProvider.notifier).of(accountId);
  final age = asked.value ?? (putIn == null ? null : PasswordAge.unknown);
  if (age == null) return null;
  final days =
      ref.watch(passwordDaysProvider)[accountId] ?? PasswordExpiry.defaultDays;
  return PasswordExpiry.of(passwordAgeWith(age, putIn), days);
});

/// The line under [accountId] in the folder list, from
/// [PasswordExpiry.warnDays] before its password runs out; null before.
final passwordWarningProvider =
    Provider.family<String?, String>((ref, accountId) {
  final expiry = ref.watch(passwordExpiryProvider(accountId));
  if (expiry == null) return null;
  final now = ref.watch(passwordClockProvider)();
  return expiry.isNear(now) ? expiry.warning(now) : null;
});

/// Reads each Microsoft account's password date again, now and then, and
/// sets the phone's reminders by it: [PasswordExpiry.reminderDays] before
/// the day, in the morning. Android shows them whether the app is running
/// or not, and a tap opens the account's settings.
class PasswordKeeper {
  PasswordKeeper(this._ref);

  final Ref _ref;
  DateTime? _lastAt;

  /// How often the dates are read again while the app is in use.
  static const every = Duration(hours: 6);

  /// Never throws. [force] after the account signed in again, or its days
  /// were changed; [reread] false for the days, which leave the dates as
  /// they were read.
  Future<void> keepUp({bool force = false, bool reread = true}) async {
    final now = _ref.read(passwordClockProvider)();
    final last = _lastAt;
    if (!force && last != null && now.difference(last) < every) return;
    _lastAt = now;
    try {
      await _keepUp(now, reread: reread);
    } catch (e) {
      debugPrint('[myemail] could not set the password reminders: $e');
    }
  }

  Future<void> _keepUp(DateTime now, {required bool reread}) async {
    final store = _ref.read(uiStateStoreProvider);
    final notifier = _ref.read(mailNotifierProvider);
    final accounts = [
      for (final a in _ref.read(accountsProvider).value ?? const <Account>[])
        if (hasOwnMicrosoftPassword(a)) a,
    ];
    // Each reminder set, by id, with when it comes, in seconds.
    final stored = store.readOrder(UiStateKeys.passwordReminders);
    final wanted = <String, int>{};
    for (final account in accounts) {
      final dates = _ref.read(passwordChangedProvider.notifier);
      PasswordAge? age;
      try {
        age = await (reread
            ? _ref.refresh(passwordAgeProvider(account.id).future)
            : _ref.read(passwordAgeProvider(account.id).future));
      } on SignInExpired catch (e) {
        // Signed out by a password change: the new password's day, which
        // is what the count starts from.
        if (e.passwordChangedAt case final at?) {
          dates.signedOutAt(account.id, at);
        }
      } catch (_) {
        // Not allowed, or not reachable just now.
      }
      final putIn = dates.of(account.id);
      if (age == null && putIn == null) {
        // Nothing to go on: whatever was set for it stays as it was.
        for (final d in PasswordExpiry.reminderDays) {
          final id = '${PasswordExpiry.reminderId(account.id, d)}';
          if (stored[id] case final at?) wanted[id] = at;
        }
        continue;
      }
      final days = _ref.read(passwordDaysProvider.notifier).of(account.id);
      final expiry = PasswordExpiry.of(
        passwordAgeWith(age ?? PasswordAge.unknown, putIn),
        days,
      );
      if (expiry == null) continue;
      for (final r in expiry.reminders(now)) {
        final id = PasswordExpiry.reminderId(account.id, r.daysBefore);
        final set = await notifier.scheduleReminder(
          id: id,
          at: r.at,
          title: '${account.displayName} password expires in '
              '${r.daysBefore} days',
          body: '${account.emailAddress}: change it by '
              '${passwordDay(expiry.expires)}.',
          payload: passwordPayload(account.id),
        );
        if (set) wanted['$id'] = r.at.millisecondsSinceEpoch ~/ 1000;
      }
    }
    // One no longer wanted is taken back, unless its time has come: it is
    // on the screen, or was, and taking it back would take it down.
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    for (final MapEntry(key: id, value: at) in stored.entries) {
      final n = int.tryParse(id);
      if (n == null || wanted.containsKey(id) || at <= nowSeconds) continue;
      await notifier.cancelReminder(n);
    }
    await store.writeOrder(UiStateKeys.passwordReminders, wanted);
  }
}

final passwordKeeperProvider =
    Provider<PasswordKeeper>((ref) => PasswordKeeper(ref));
