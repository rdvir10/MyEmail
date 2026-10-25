import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mailbox_settings/gmail_settings_api.dart';
import '../../data/mailbox_settings/server_settings.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/mailbox_settings.dart';
import '../../state/providers.dart';
import '../../state/server_settings_providers.dart';
import '../common/bottom_message.dart';
import 'server_settings_access.dart';

/// Settings, Rules: each account's, as its server runs them on mail as it
/// arrives. Outlook's Inbox rules and Gmail's filters, which work with the
/// phone off and show in Outlook and Gmail on the web.
class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if (canReachServerSettings(a)) a,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Rules'), centerTitle: false),
      body: ListView(
        children: [
          for (final account in accounts)
            ListTile(
              key: ValueKey('rules-account:${account.id}'),
              leading: const Icon(Icons.rule_outlined),
              title: Text(account.emailAddress),
              subtitle: Text(
                switch (ref.watch(mailRulesProvider(account.id))) {
                  AsyncData(:final value) => switch (value.length) {
                      0 => 'None',
                      1 => '1 rule',
                      final n => '$n rules',
                    },
                  AsyncError(:final error) =>
                    serverSettingsProblem(account, error).offerSignIn
                        ? 'Not allowed yet'
                        : 'Could not be read just now',
                  _ => 'Checking…',
                },
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => AccountRulesScreen(account: account),
              )),
            ),
          if (accounts.isEmpty)
            const ListTile(title: Text('No account here has server rules.')),
        ],
      ),
    );
  }
}

/// One account's rules: switched on and off, deleted, and new ones made.
class AccountRulesScreen extends ConsumerWidget {
  const AccountRulesScreen({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loaded = ref.watch(mailRulesProvider(account.id));
    final settings = ref.watch(mailEngineProvider).serverSettings(account.id);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rules'),
        centerTitle: false,
        actions: [
          if (loaded is AsyncData && settings != null)
            IconButton(
              key: const ValueKey('rule-new'),
              tooltip: 'New rule',
              icon: const Icon(Icons.add),
              onPressed: () => openRuleEditor(context, account),
            ),
        ],
      ),
      body: switch (loaded) {
        AsyncData(:final value) when settings != null => ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(account.emailAddress, style: muted),
              ),
              if (value.isEmpty)
                const ListTile(
                  title: Text('No rules yet'),
                  subtitle: Text('Add one with +, or from a message: More, '
                      'Create rule.'),
                ),
              for (final rule in value)
                _RuleRow(account: account, settings: settings, rule: rule),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  '${settings.serverName} runs these, in this order, on mail '
                  'as it arrives, with the phone off too.'
                  '${settings.rulesCanBeOff ? '' : ' Gmail cannot switch a '
                      'filter off: delete it instead.'}',
                  style: muted,
                ),
              ),
            ],
          ),
        AsyncError(:final error) => ServerSettingsProblem(
            account: account,
            error: error,
            onRetry: () => ref.invalidate(mailRulesProvider(account.id)),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _RuleRow extends ConsumerStatefulWidget {
  const _RuleRow({
    required this.account,
    required this.settings,
    required this.rule,
  });

  final Account account;
  final ServerSettings settings;
  final MailRule rule;

  @override
  ConsumerState<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends ConsumerState<_RuleRow> {
  bool _busy = false;

  MailRule get rule => widget.rule;

  Future<void> _run(Future<void> Function() change, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await change();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          persist: false,
          content: Text(done),
        ));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          persist: false,
          content: Text(e is ReadableError ? e.message : '$e'),
        ));
    } finally {
      ref.invalidate(mailRulesProvider(widget.account.id));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete this rule?'),
        content: Text(rule.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('rule-delete-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run(() => widget.settings.deleteRule(rule), 'Rule deleted.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final named = rule.name.trim().isNotEmpty;
    final lines = [
      if (named) rule.summary,
      if (rule.partly)
        'Does more than this shows: change it in '
            '${widget.settings.serverName} on the web.',
    ];
    return ListTile(
      key: ValueKey('rule:${rule.id}'),
      title: Text(rule.title),
      subtitle: lines.isEmpty ? null : Text(lines.join('\n')),
      isThreeLine: lines.length > 1,
      textColor: rule.enabled ? null : theme.colorScheme.onSurfaceVariant,
      trailing: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.settings.rulesCanBeOff)
                  Switch(
                    key: ValueKey('rule-on:${rule.id}'),
                    value: rule.enabled,
                    onChanged: rule.partly
                        ? null
                        : (on) => _run(
                              () => widget.settings.setRuleEnabled(rule, on),
                              on ? 'Rule switched on.' : 'Rule switched off.',
                            ),
                  ),
                IconButton(
                  key: ValueKey('rule-delete:${rule.id}'),
                  tooltip: 'Delete rule',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete,
                ),
              ],
            ),
    );
  }
}

/// The editor for a new rule on [account], from [message] where it is made
/// from one: from its sender, with its subject a tap away.
Future<void> openRuleEditor(
  BuildContext context,
  Account account, {
  MailMessage? message,
}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RuleEditorScreen(account: account, message: message),
    ));

/// A new rule: when mail is from someone or its subject has some words,
/// move it, delete it, mark it read.
class RuleEditorScreen extends ConsumerStatefulWidget {
  const RuleEditorScreen({super.key, required this.account, this.message});

  final Account account;
  final MailMessage? message;

  @override
  ConsumerState<RuleEditorScreen> createState() => _RuleEditorScreenState();
}

enum _Then { move, delete, stay }

class _RuleEditorScreenState extends ConsumerState<RuleEditorScreen> {
  final _name = TextEditingController();
  final _from = TextEditingController();
  final _subject = TextEditingController();
  _Then _then = _Then.move;
  String? _folder;
  bool _markRead = false;
  bool _saving = false;
  String? _error;

  Account get account => widget.account;

  @override
  void initState() {
    super.initState();
    final from = widget.message?.from.email.trim() ?? '';
    _from.text = from;
  }

  @override
  void dispose() {
    _name.dispose();
    _from.dispose();
    _subject.dispose();
    super.dispose();
  }

  static List<String> _parts(String text) => [
        for (final p in text.split(RegExp(r'[,;\n]')))
          if (p.trim().isNotEmpty) p.trim(),
      ];

  MailRule get _rule => MailRule(
        name: _name.text.trim(),
        from: _parts(_from.text),
        subjectContains: _parts(_subject.text),
        moveTo: _then == _Then.move ? _folder : null,
        delete: _then == _Then.delete,
        markRead: _markRead,
      );

  /// Where a rule may move mail: the account's own folders, and its
  /// archive. Not the Inbox it would be moving out of, nor Drafts, Sent or
  /// the Outbox; Gmail's own [Gmail] folders are labels the API names
  /// otherwise, all but All Mail.
  List<MailFolder> _targets() {
    final gmail = account.provider == MailProvider.gmail;
    bool gmailOwn(MailFolder f) =>
        f.path.startsWith('[Gmail]') || f.path.startsWith('[Google Mail]');
    return [
      for (final f in ref.read(foldersProvider).value?[account.id] ??
          const <MailFolder>[])
        if (!f.isSynthetic &&
            switch (f.role) {
              FolderRole.archive => true,
              FolderRole.junk => !gmail,
              FolderRole.user => !gmail || !gmailOwn(f),
              _ => false,
            })
          f,
    ]..sort((a, b) {
        if ((a.role == FolderRole.archive) != (b.role == FolderRole.archive)) {
          return a.role == FolderRole.archive ? -1 : 1;
        }
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
  }

  Future<void> _pickFolder() async {
    final targets = _targets();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final f in targets)
                ListTile(
                  key: ValueKey('rule-folder:${f.path}'),
                  leading: Icon(f.role == FolderRole.archive
                      ? Icons.archive_outlined
                      : Icons.folder_outlined),
                  title: Text(f.role == FolderRole.archive
                      ? 'Archive'
                      : f.path),
                  onTap: () => Navigator.of(sheet).pop(f.path),
                ),
              if (targets.isEmpty)
                const ListTile(title: Text('This account has no folders of '
                    'its own to move mail to.')),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _folder = picked;
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    final rule = _rule;
    if (rule.from.isEmpty && rule.subjectContains.isEmpty) {
      setState(() => _error = 'Say who it is from, or what its subject has.');
      return;
    }
    if (_then == _Then.move && _folder == null) {
      setState(() => _error = 'Choose the folder to move it to.');
      return;
    }
    if (!rule.isValid) {
      setState(() => _error = 'Choose something for it to do.');
      return;
    }
    final settings = ref.read(mailEngineProvider).serverSettings(account.id);
    if (settings == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await settings.addRule(rule);
      ref.invalidate(mailRulesProvider(account.id));
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          persist: false,
          content: Text('Rule saved. ${settings.serverName} runs it on new '
              'mail.'),
        ));
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ReadableError ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(mailEngineProvider).serverSettings(account.id);
    // Watched, so the folders are in by the time the picker opens.
    ref.watch(foldersProvider);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final subject = widget.message?.subject.trim() ?? '';
    final folderName = _folder == null
        ? 'Choose a folder'
        : _targets().where((f) => f.path == _folder).firstOrNull?.role ==
                    FolderRole.archive ||
                _folder == GmailSettingsApi.archiveName
            ? 'Archive'
            : _folder!;
    void changed(String _) {
      if (_error != null) setState(() => _error = null);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('New rule'),
        centerTitle: false,
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : TextButton(
                  key: const ValueKey('rule-save'),
                  onPressed: settings == null ? null : _save,
                  child: const Text('Save'),
                ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(account.emailAddress, style: muted),
          if (settings?.rulesHaveNames ?? false) ...[
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('rule-name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'What it does, when empty',
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text('When a message arrives', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('rule-from'),
            controller: _from,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'From',
              hintText: 'Addresses or parts of them, with commas',
            ),
            onChanged: changed,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('rule-subject'),
            controller: _subject,
            decoration: const InputDecoration(
              labelText: 'Subject has',
              hintText: 'Words, with commas: any of them',
            ),
            onChanged: changed,
          ),
          if (subject.isNotEmpty) ...[
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ActionChip(
                key: const ValueKey('rule-use-subject'),
                avatar: const Icon(Icons.subject, size: 18),
                label: Text(
                  'This subject: $subject',
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => setState(() {
                  _subject.text = subject;
                  _error = null;
                }),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'With both, a message has to match both.',
              style: muted,
            ),
          ),
          const SizedBox(height: 16),
          Text('Do this', style: theme.textTheme.titleSmall),
          RadioGroup<_Then>(
            groupValue: _then,
            onChanged: (t) => setState(() {
              _then = t ?? _Then.move;
              _error = null;
            }),
            child: Column(
              children: [
                const RadioListTile<_Then>(
                  key: ValueKey('rule-move'),
                  contentPadding: EdgeInsets.zero,
                  value: _Then.move,
                  title: Text('Move it to a folder'),
                ),
                if (_then == _Then.move)
                  ListTile(
                    key: const ValueKey('rule-folder'),
                    contentPadding: const EdgeInsets.only(left: 48),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folderName),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: _pickFolder,
                  ),
                const RadioListTile<_Then>(
                  key: ValueKey('rule-delete'),
                  contentPadding: EdgeInsets.zero,
                  value: _Then.delete,
                  title: Text('Delete it'),
                ),
                const RadioListTile<_Then>(
                  key: ValueKey('rule-stay'),
                  contentPadding: EdgeInsets.zero,
                  value: _Then.stay,
                  title: Text('Leave it in the Inbox'),
                ),
              ],
            ),
          ),
          CheckboxListTile(
            key: const ValueKey('rule-read'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Mark it as read'),
            value: _markRead,
            onChanged: (v) => setState(() {
              _markRead = v ?? false;
              _error = null;
            }),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                key: const ValueKey('rule-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Rules work on mail that arrives from now on, not on what is '
              'already in the Inbox.',
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}
