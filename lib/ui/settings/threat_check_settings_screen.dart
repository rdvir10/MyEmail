import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/security/online_checks.dart';
import '../../state/providers.dart';
import '../../state/threat_check_providers.dart';

/// Settings, Threat check: the keys for the two outside checks Check for
/// threats asks. Pasted here, kept in this device's secure storage, and
/// not in the backup: each device has its own copy.
class ThreatCheckSettingsScreen extends ConsumerWidget {
  const ThreatCheckSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final keys = ref.watch(threatKeysProvider).value;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Threat check'), centerTitle: false),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              "Check for threats, in a message's ⋮ menu, looks at its "
              "sender, links and attachments on the phone, and at what its "
              'mail server found. With these keys it also asks Google Safe '
              'Browsing about its links, sending only the links, and '
              "VirusTotal about its attachments, sending only each file's "
              'fingerprint, never the file. The keys stay on this device.',
              style: muted,
            ),
          ),
          _KeyRow(
            key: const ValueKey('threat-key-safe-browsing'),
            name: safeBrowsingKeyName,
            title: 'Google Safe Browsing key',
            set: keys?.safeBrowsing ?? false,
            help: 'An API key from your Google Cloud project, with the Safe '
                'Browsing API enabled.',
          ),
          _KeyRow(
            key: const ValueKey('threat-key-virustotal'),
            name: virusTotalKeyName,
            title: 'VirusTotal key',
            set: keys?.virusTotal ?? false,
            help: 'From your VirusTotal profile, under API key. The free '
                'one checks four files a minute.',
          ),
        ],
      ),
    );
  }
}

class _KeyRow extends ConsumerWidget {
  const _KeyRow({
    super.key,
    required this.name,
    required this.title,
    required this.set,
    required this.help,
  });

  final String name;
  final String title;
  final bool set;
  final String help;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
        leading: Icon(set ? Icons.key : Icons.key_off_outlined),
        title: Text(title),
        subtitle: Text(set ? 'Set on this device' : 'Not set. $help'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final secrets = ref.read(credentialStoreProvider);
          final typed = await showDialog<String>(
            context: context,
            builder: (_) => _KeyDialog(title: title, set: set),
          );
          if (typed == null) return;
          if (typed.isEmpty) {
            await secrets.deleteSecret(name);
          } else {
            await secrets.writeSecret(name, typed);
          }
          ref.invalidate(threatKeysProvider);
        },
      );
}

/// The key pasted in; an empty one, from Remove, takes it away.
class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.title, required this.set});

  final String title;
  final bool set;

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const ValueKey('threat-key-field'),
          controller: _key,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Paste the key'),
        ),
        actions: [
          if (widget.set)
            TextButton(
              key: const ValueKey('threat-key-remove'),
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('threat-key-save'),
            onPressed: () {
              final key = _key.text.trim();
              if (key.isNotEmpty) Navigator.of(context).pop(key);
            },
            child: const Text('Save'),
          ),
        ],
      );
}
