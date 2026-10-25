import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mailbox_settings/server_settings.dart';
import '../domain/mailbox_settings.dart';
import 'message_keeping.dart' show notRetried;
import 'providers.dart';

/// Thrown by these providers for an account whose server settings cannot be
/// reached at all: one signed in with an app password.
class NoServerSettings implements Exception {
  const NoServerSettings();
}

ServerSettings _settingsOf(Ref ref, String accountId) =>
    ref.watch(mailEngineProvider).serverSettings(accountId) ??
    (throw const NoServerSettings());

/// [accountId]'s automatic replies, as its server has them now. Throws
/// `SignInNeedsConsent` for an account that has not allowed the app to
/// change its settings, and [NoServerSettings]. Not retried: the answer to
/// a refusal is a sign-in, which reads them again.
final autoReplyProvider = FutureProvider.autoDispose
    .family<AutoReply, String>((ref, accountId) {
  return _settingsOf(ref, accountId).autoReply();
}, retry: notRetried);

/// [accountId]'s rules, as its server runs them, in order. Throws as
/// [autoReplyProvider] does.
final mailRulesProvider = FutureProvider.autoDispose
    .family<List<MailRule>, String>((ref, accountId) {
  return _settingsOf(ref, accountId).rules();
}, retry: notRetried);
