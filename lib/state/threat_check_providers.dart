import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/security/online_checks.dart';
import '../domain/address_suggestions.dart';
import '../domain/mail_attachment.dart';
import '../domain/mail_message.dart';
import '../domain/threat_check.dart';
import 'message_keeping.dart' show notRetried;
import 'providers.dart';

/// Google Safe Browsing and VirusTotal, as the threat check asks them;
/// tests put their own in.
final safeBrowsingProvider =
    Provider<SafeBrowsing>((ref) => HttpSafeBrowsing());
final virusTotalProvider = Provider<VirusTotal>((ref) => HttpVirusTotal());

/// How many attachments VirusTotal is asked about in one check: its free
/// allowance is four lookups a minute.
const virusTotalPerCheck = 4;

/// The largest attachment fetched to be fingerprinted.
const virusTotalLargest = 32 * 1024 * 1024;

/// Whether each outside check has its key here. Kept, and invalidated by
/// Settings, Threat check when a key is saved or removed.
final threatKeysProvider =
    FutureProvider<({bool safeBrowsing, bool virusTotal})>((ref) async {
  final secrets = ref.watch(credentialStoreProvider);
  bool set(String? key) => key != null && key.trim().isNotEmpty;
  return (
    safeBrowsing: set(await secrets.readSecret(safeBrowsingKeyName)),
    virusTotal: set(await secrets.readSecret(virusTotalKeyName)),
  );
});

/// Check for threats on [message]: what the phone finds at once, then
/// with Google Safe Browsing's and VirusTotal's answers, where their keys
/// are set.
final threatCheckProvider = StreamProvider.autoDispose
    .family<ThreatReport, MailMessage>((ref, message) async* {
  final engine = ref.watch(mailEngineProvider);
  final secrets = ref.watch(credentialStoreProvider);
  // Read, not watched: the accounts changing would ask VirusTotal again,
  // and its allowance is four a minute.
  final accounts = await ref.read(accountsProvider.future);

  final notes = <ThreatFinding>[];
  Map<String, String> headers;
  try {
    headers = await engine.messageHeaders(message.id, threatHeaderNames);
  } catch (e) {
    headers = const {};
    notes.add(ThreatFinding(
      ThreatLevel.safe,
      ThreatArea.server,
      "The mail server's verdicts could not be read",
      detail: '$e',
    ));
  }
  final body = await engine.loadMessageBody(message.id);
  List<MailAttachment> attachments;
  try {
    attachments = message.hasAttachments
        ? await engine.listAttachments(message.id)
        : const [];
  } catch (e) {
    attachments = const [];
    debugPrint('[myemail] threat check: attachments not listed: $e');
  }
  List<AddressSuggestion> people;
  try {
    people = await engine.recentAddresses();
  } catch (_) {
    people = const [];
  }

  // Known: whoever has been written to, and the accounts' own domains.
  // The message's own sender has been seen once, by this message.
  final knownAddresses = {
    for (final p in people)
      if (p.timesSent > 0 || p.timesSeen > 1) p.email.trim().toLowerCase(),
  };
  String domainOf(String email) =>
      email.substring(email.lastIndexOf('@') + 1).trim().toLowerCase();
  final known = {
    for (final a in accounts) baseDomain(domainOf(a.emailAddress)),
    for (final p in people)
      if (p.timesSent > 0 && p.email.contains('@'))
        baseDomain(domainOf(p.email)),
  }..remove('');

  final links = linksIn(html: body.html, text: body.text);
  final sbKey = (await secrets.readSecret(safeBrowsingKeyName))?.trim() ?? '';
  final vtKey = (await secrets.readSecret(virusTotalKeyName))?.trim() ?? '';
  final files = [
    for (final a in attachments)
      if (!a.isInline && a.sizeBytes <= virusTotalLargest) a,
  ]..sort((a, b) =>
      (isRiskyAttachment(b) ? 1 : 0).compareTo(isRiskyAttachment(a) ? 1 : 0));
  final local = ThreatReport(
    findings: [
      ...checkHeaders(headers),
      ...notes,
      ...checkSender(message, knownAddresses: knownAddresses, known: known),
      ...checkLinks(links, known: known),
      ...checkAttachments(attachments),
    ],
    links: links,
    attachments: attachments,
    safeBrowsing: sbKey.isNotEmpty,
    virusTotal: vtKey.isNotEmpty,
    checking: sbKey.isNotEmpty || (vtKey.isNotEmpty && files.isNotEmpty),
  );
  yield local;
  if (!local.checking) return;

  final online = <ThreatFinding>[];
  void add(ThreatLevel level, String title, [String detail = '']) =>
      online.add(ThreatFinding(level, ThreatArea.online, title, detail: detail));

  if (sbKey.isNotEmpty) {
    final urls = {
      for (final l in links)
        if (l.target case final t? when t.scheme == 'http' || t.scheme == 'https')
          t.toString(),
    }.take(200).toList();
    if (urls.isNotEmpty) {
      try {
        final listed =
            await ref.read(safeBrowsingProvider).listed(urls, key: sbKey);
        if (listed.isEmpty) {
          add(ThreatLevel.safe, 'Google Safe Browsing lists none of its links',
              '${urls.length} checked.');
        }
        for (final MapEntry(key: url, value: type) in listed.entries) {
          add(ThreatLevel.danger,
              'Google lists a link as ${threatTypeName(type)}', url);
        }
      } on OnlineCheckFailed catch (e) {
        add(ThreatLevel.safe, 'Google Safe Browsing could not check its links',
            e.message);
      }
    }
  }

  if (vtKey.isNotEmpty && files.isNotEmpty) {
    for (final a in files.take(virusTotalPerCheck)) {
      try {
        final bytes = await engine.fetchAttachment(message.id, a.id);
        final hash = [
          for (final b in (await Sha256().hash(bytes)).bytes)
            b.toRadixString(16).padLeft(2, '0'),
        ].join();
        final verdict =
            await ref.read(virusTotalProvider).file(hash, key: vtKey);
        if (verdict == null) {
          add(ThreatLevel.safe, 'VirusTotal has not seen ${a.name}',
              'A file never seen before is neither cleared nor caught.');
        } else if (verdict.malicious > 0) {
          final engines =
              verdict.malicious + verdict.suspicious + verdict.clean;
          add(ThreatLevel.danger,
              '${a.name}: ${verdict.malicious} of $engines antivirus engines '
              'flag it as malicious');
        } else if (verdict.suspicious > 0) {
          add(ThreatLevel.caution,
              '${a.name}: ${verdict.suspicious} antivirus engines find it '
              'suspicious');
        } else {
          add(ThreatLevel.safe, '${a.name}: no antivirus engine flags it',
              '${verdict.clean} engines checked it.');
        }
      } on OnlineCheckFailed catch (e) {
        add(ThreatLevel.safe, 'VirusTotal could not check ${a.name}',
            e.message);
        break;
      } catch (e) {
        add(ThreatLevel.safe, '${a.name} could not be fetched to check',
            '$e');
      }
    }
    if (files.length > virusTotalPerCheck) {
      add(ThreatLevel.safe,
          'Only $virusTotalPerCheck of ${files.length} files were checked',
          "VirusTotal's free allowance is four a minute.");
    }
  }
  yield local.withOnline(online, checking: false);
}, retry: notRetried);
