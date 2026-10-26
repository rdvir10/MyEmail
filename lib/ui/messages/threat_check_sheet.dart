import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mail_message.dart';
import '../../domain/threat_check.dart';
import '../../state/threat_check_providers.dart';
import '../settings/threat_check_settings_screen.dart';

/// Check for threats, from a message's ⋮ menu: what its mail server
/// found, its sender, links and attachments, and what Google Safe
/// Browsing and VirusTotal say where they are set up.
Future<void> showThreatCheck(BuildContext context, MailMessage message) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ThreatCheckSheet(message: message),
    );

const _green = Color(0xFF2E7D32);
const _amber = Color(0xFFB26A00);

class ThreatCheckSheet extends ConsumerWidget {
  const ThreatCheckSheet({super.key, required this.message});

  final MailMessage message;

  static const _areas = {
    ThreatArea.server: 'What the mail server found',
    ThreatArea.sender: 'The sender',
    ThreatArea.links: 'Links',
    ThreatArea.attachments: 'Attachments',
    ThreatArea.online: 'Google Safe Browsing and VirusTotal',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final checked = ref.watch(threatCheckProvider(message));
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: switch (checked) {
          AsyncData(:final value) =>
            _report(context, ref, theme, muted, value),
          AsyncError(:final error) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'The check could not be made: '
                '${error is ReadableError ? error.message : error}',
                style: muted,
              ),
            ),
          _ => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
        },
      ),
    );
  }

  Widget _report(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    TextStyle? muted,
    ThreatReport report,
  ) {
    final (IconData icon, Color colour, String verdict) = switch (report.level) {
      ThreatLevel.danger => (Icons.gpp_bad_outlined, theme.colorScheme.error,
          'This looks dangerous'),
      ThreatLevel.caution => (Icons.warning_amber_rounded, _amber,
          'Be careful with this one'),
      ThreatLevel.safe => (Icons.verified_user_outlined, _green,
          'No sign of a threat'),
    };
    final online = [
      if (report.safeBrowsing) 'Google Safe Browsing',
      if (report.virusTotal) 'VirusTotal',
    ];
    final hosts = <String, int>{};
    for (final l in report.links) {
      if (l.host.isNotEmpty) hosts[l.host] = (hosts[l.host] ?? 0) + 1;
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Row(
          children: [
            Icon(icon, size: 32, color: colour),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                verdict,
                key: const ValueKey('threat-verdict'),
                style: theme.textTheme.titleLarge?.copyWith(color: colour),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          online.isEmpty
              ? 'Checked on the phone. Google Safe Browsing and VirusTotal '
                  'are not set up.'
              : 'Checked on the phone and with ${online.join(' and ')}.',
          style: muted,
        ),
        if (online.length < 2)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('threat-set-up'),
              // A key added there checks again here, with it.
              onPressed: () async {
                final before = await ref.read(threatKeysProvider.future);
                if (!context.mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ThreatCheckSettingsScreen(),
                  ),
                );
                if (!context.mounted) return;
                if (await ref.read(threatKeysProvider.future) != before) {
                  ref.invalidate(threatCheckProvider(message));
                }
              },
              child: const Text('Set up the online checks'),
            ),
          ),
        if (report.checking) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 4),
          Text('Asking ${online.join(' and ')}…', style: muted),
        ],
        for (final MapEntry(key: area, value: heading) in _areas.entries)
          if (report.findings.where((f) => f.area == area).toList()
              case final found when found.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              heading,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            for (final (i, f) in (found
                  ..sort((a, b) => b.level.index.compareTo(a.level.index)))
                .indexed)
              ListTile(
                key: ValueKey('threat-finding:${area.name}:$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (f.level) {
                    ThreatLevel.danger => Icons.gpp_bad_outlined,
                    ThreatLevel.caution => Icons.warning_amber_rounded,
                    ThreatLevel.safe => Icons.check_circle_outline,
                  },
                  color: switch (f.level) {
                    ThreatLevel.danger => theme.colorScheme.error,
                    ThreatLevel.caution => _amber,
                    ThreatLevel.safe => _green,
                  },
                ),
                title: Text(f.title),
                subtitle: f.detail.isEmpty ? null : Text(f.detail),
              ),
          ],
        if (hosts.isNotEmpty)
          ExpansionTile(
            key: const ValueKey('threat-links'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              'Where its links go (${hosts.length})',
              style: theme.textTheme.labelLarge,
            ),
            children: [
              for (final MapEntry(key: host, value: count) in hosts.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link, size: 18),
                  title: Text(host),
                  trailing: count > 1 ? Text('×$count', style: muted) : null,
                ),
            ],
          ),
      ],
    );
  }
}
