import '../../domain/mailbox_settings.dart';
import '../graph/graph_settings_api.dart';
import '../mail_engine.dart';
import 'gmail_settings_api.dart';

/// One account's settings kept on its server: its automatic replies, and
/// the rules the server runs on mail as it arrives. A Microsoft account's
/// over Graph, a Gmail account's over the Gmail API; see
/// `MailEngine.serverSettings`. Each asks for a permission of its own, so
/// any call may throw `SignInNeedsConsent`, which a sign-in again clears.
abstract class ServerSettings {
  /// "Outlook" or "Gmail", for sentences.
  String get serverName;

  /// Outlook's rules have names and can be switched off; Gmail's filters
  /// have neither.
  bool get rulesHaveNames;
  bool get rulesCanBeOff;

  /// The replies can say one thing inside the organisation and another
  /// outside it: Microsoft.
  bool get repliesKnowOrganisation;

  /// The reply has a subject of its own: Gmail.
  bool get repliesHaveSubject;

  Future<AutoReply> autoReply();
  Future<void> setAutoReply(AutoReply reply);

  /// In the order the server runs them.
  Future<List<MailRule>> rules();

  /// [rule] made, run after the others, and answered with its id.
  Future<MailRule> addRule(MailRule rule);
  Future<void> setRuleEnabled(MailRule rule, bool enabled);
  Future<void> deleteRule(MailRule rule);
}

/// A Microsoft account's, over Graph. A rule names its folder by Graph's
/// id, which the account's mail connection knows by path.
class GraphServerSettings implements ServerSettings {
  GraphServerSettings({
    required this.api,
    required this.folderIdOf,
    required this.pathsById,
  });

  final GraphSettingsApi api;
  final Future<String> Function(String path) folderIdOf;
  final Future<Map<String, String>> Function() pathsById;

  @override
  String get serverName => 'Outlook';
  @override
  bool get rulesHaveNames => true;
  @override
  bool get rulesCanBeOff => true;
  @override
  bool get repliesKnowOrganisation => true;
  @override
  bool get repliesHaveSubject => false;

  @override
  Future<AutoReply> autoReply() => api.automaticReplies();

  @override
  Future<void> setAutoReply(AutoReply reply) => api.setAutomaticReplies(reply);

  @override
  Future<List<MailRule>> rules() async {
    final paths = await pathsById();
    return api.rules((id) => paths[id]);
  }

  @override
  Future<MailRule> addRule(MailRule rule) async {
    final folderId = rule.moveTo == null || rule.delete
        ? null
        : await folderIdOf(rule.moveTo!);
    return api.createRule(rule, folderId);
  }

  @override
  Future<void> setRuleEnabled(MailRule rule, bool enabled) =>
      api.setRuleEnabled(rule.id!, enabled);

  @override
  Future<void> deleteRule(MailRule rule) => api.deleteRule(rule.id!);
}

/// A Gmail account's, over the Gmail API. A filter names its label by
/// Gmail's id, which the API lists by name, IMAP's folder path; the
/// archive, All Mail, is no label at all but the Inbox taken off.
class GmailServerSettings implements ServerSettings {
  GmailServerSettings({required this.api, required this.isArchive});

  final GmailSettingsApi api;
  final Future<bool> Function(String path) isArchive;

  @override
  String get serverName => 'Gmail';
  @override
  bool get rulesHaveNames => false;
  @override
  bool get rulesCanBeOff => false;
  @override
  bool get repliesKnowOrganisation => false;
  @override
  bool get repliesHaveSubject => true;

  @override
  Future<AutoReply> autoReply() => api.vacation();

  @override
  Future<void> setAutoReply(AutoReply reply) => api.setVacation(reply);

  @override
  Future<List<MailRule>> rules() async => api.filters(await api.labelNames());

  @override
  Future<MailRule> addRule(MailRule rule) async {
    final to = rule.delete ? null : rule.moveTo;
    if (to == null) return api.createFilter(rule);
    if (to == GmailSettingsApi.archiveName || await isArchive(to)) {
      return api.createFilter(rule, archive: true);
    }
    final labels = await api.labelNames();
    final id = [
      for (final MapEntry(:key, :value) in labels.entries)
        if (value == to) key,
    ].firstOrNull;
    if (id == null) {
      throw ConnectionFailed('Gmail has no label called $to.');
    }
    return api.createFilter(rule, labelId: id);
  }

  /// Never asked: [rulesCanBeOff] is false.
  @override
  Future<void> setRuleEnabled(MailRule rule, bool enabled) async =>
      throw UnsupportedError("Gmail's filters cannot be switched off.");

  @override
  Future<void> deleteRule(MailRule rule) => api.deleteFilter(rule.id!);
}

/// Kept in memory, for the sample mailbox and tests: as Outlook's with
/// [microsoft], as Gmail's otherwise.
class MemoryServerSettings implements ServerSettings {
  MemoryServerSettings({this.microsoft = true, AutoReply? reply, List<MailRule>? rules})
      : reply = reply ?? const AutoReply(),
        saved = [...?rules];

  final bool microsoft;
  AutoReply reply;
  final List<MailRule> saved;
  var _next = 0;

  @override
  String get serverName => microsoft ? 'Outlook' : 'Gmail';
  @override
  bool get rulesHaveNames => microsoft;
  @override
  bool get rulesCanBeOff => microsoft;
  @override
  bool get repliesKnowOrganisation => microsoft;
  @override
  bool get repliesHaveSubject => !microsoft;

  @override
  Future<AutoReply> autoReply() async => reply;

  @override
  Future<void> setAutoReply(AutoReply reply) async => this.reply = reply;

  @override
  Future<List<MailRule>> rules() async => List.of(saved);

  @override
  Future<MailRule> addRule(MailRule rule) async {
    final made = rule.copyWith(id: 'rule-${++_next}');
    saved.add(made);
    return made;
  }

  @override
  Future<void> setRuleEnabled(MailRule rule, bool enabled) async {
    final i = saved.indexWhere((r) => r.id == rule.id);
    if (i >= 0) saved[i] = saved[i].copyWith(enabled: enabled);
  }

  @override
  Future<void> deleteRule(MailRule rule) async =>
      saved.removeWhere((r) => r.id == rule.id);
}
