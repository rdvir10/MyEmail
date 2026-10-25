import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/duet/duet_uploader.dart';
import '../../data/ui_state_store.dart';
import '../../domain/account.dart';
import '../../state/duet_providers.dart';
import '../../state/providers.dart';
import '../messages/date_format.dart';

/// Settings, Claude (Duet): the Inboxes MyEmail sends to Ron's connector for
/// Claude, where Duet reads them. Text only, the newest messages, after each
/// mail check.
class DuetScreen extends ConsumerStatefulWidget {
  const DuetScreen({super.key});

  @override
  ConsumerState<DuetScreen> createState() => _DuetScreenState();
}

class _DuetScreenState extends ConsumerState<DuetScreen> {
  late final TextEditingController _server = TextEditingController(
    text: ref.read(duetSettingsProvider).server,
  );
  final _key = TextEditingController();
  bool _showKey = false;
  bool _sending = false;

  /// The last pass's line, and when.
  ({String line, DateTime? at, bool ok})? _status;

  @override
  void initState() {
    super.initState();
    _status = _readStatus();
    ref
        .read(credentialStoreProvider)
        .readSecret(DuetUploader.keyName)
        .then((key) {
      if (mounted && key != null) setState(() => _key.text = key);
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  ({String line, DateTime? at, bool ok})? _readStatus() {
    final text = ref.read(uiStateStoreProvider).readString(UiStateKeys.duetStatus);
    if (text == null) return null;
    try {
      final j = jsonDecode(text) as Map;
      return (
        line: '${j['line'] ?? ''}',
        at: DateTime.tryParse('${j['at'] ?? ''}'),
        ok: j['ok'] == true,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _saveKey(String key) async {
    final store = ref.read(credentialStoreProvider);
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await store.deleteSecret(DuetUploader.keyName);
    } else {
      await store.writeSecret(DuetUploader.keyName, trimmed);
    }
  }

  Future<void> _send({bool again = false}) async {
    setState(() => _sending = true);
    final uploader = ref.read(duetUploaderProvider);
    await _saveKey(_key.text);
    if (again) await uploader.forgetSent();
    final result = await uploader.run(force: true);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _status = result.ran ? _readStatus() : _status;
    });
    if (!result.ran) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          persist: false,
          content: Text('Switch it on and put in the upload key first.'),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(duetSettingsProvider);
    final notifier = ref.read(duetSettingsProvider.notifier);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Claude (Duet)'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SwitchListTile(
            key: const ValueKey('duet-on'),
            title: const Text('Send my Inboxes to my Claude connector'),
            subtitle: const Text('For Duet to read'),
            value: settings.enabled,
            onChanged: notifier.setEnabled,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: TextField(
              key: const ValueKey('duet-server'),
              controller: _server,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Connector address'),
              onChanged: notifier.setServer,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const ValueKey('duet-key'),
              controller: _key,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Upload key',
                hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
                suffixIcon: IconButton(
                  tooltip: _showKey ? 'Hide the key' : 'Show the key',
                  icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
              onChanged: _saveKey,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              'Accounts sent',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
          for (final a in accounts) ...[
            CheckboxListTile(
              key: ValueKey('duet-account:${a.id}'),
              controlAffinity: ListTileControlAffinity.leading,
              secondary: CircleAvatar(radius: 8, backgroundColor: Color(a.colorValue)),
              title: Text(a.displayName),
              subtitle: Text(a.emailAddress),
              value: settings.accounts.contains(a.id),
              onChanged: (on) =>
                  notifier.setSent(a.id, on ?? false, address: a.emailAddress),
            ),
            if (settings.accounts.contains(a.id))
              SwitchListTile(
                key: ValueKey('duet-once:${a.id}'),
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                title: const Text('Only the last day, removed once Duet reads it'),
                value: settings.readOnce.contains(a.id),
                onChanged: (once) => notifier.setReadOnce(a.id, once),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('duet-send'),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Send now'),
                ),
                TextButton(
                  key: const ValueKey('duet-again'),
                  onPressed: _sending ? null : () => _send(again: true),
                  child: const Text('Send everything again'),
                ),
              ],
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                [
                  status.line,
                  if (status.at != null)
                    '${formatDay(status.at!)}, ${formatClock(status.at!, use24h: use24h)}',
                ].join(' · '),
                key: const ValueKey('duet-status'),
                style: status.ok
                    ? muted
                    : TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Text(
              "After each mail check, the newest messages in each ticked "
              "account's Inbox go to your connector on Vercel, as text, with "
              'no attachments; what leaves the Inbox leaves the connector too. '
              'An account set to the last day only (Hadco) sends that day, '
              'and each message is removed once Duet has read it, or after a '
              'day. Claude reads them only with the connector key, set in '
              "the connector's Request headers.",
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}
