import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/app_release.dart';
import '../../state/update_providers.dart';

/// What is installed, and whether there is anything newer.
///
/// The version is on screen for a reason beyond vanity. A self-updater that
/// fails silently is undiagnosable: without a build number to read out, "did
/// the update land?" cannot be answered from the phone.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final installed = ref.watch(installedVersionValueProvider).value;
    final flow = ref.watch(updateFlowProvider);
    final configured = ref.watch(updateServiceProvider).isConfigured;

    return Scaffold(
      appBar: AppBar(title: const Text('About'), centerTitle: false),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const Text('MyEmail'),
            subtitle: Text(
              installed == null
                  ? 'Reading version'
                  : 'Version ${installed.version}, build ${installed.build}',
            ),
          ),
          const Divider(height: 1),
          if (!configured)
            _Note(
              'Updates are not set up on this build, so there is nowhere to '
              'check. Install new versions from the builds folder in OneDrive '
              'as before.',
              theme: theme,
            )
          else
            _UpdateSection(flow: flow),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _UpdateSection extends ConsumerWidget {
  const _UpdateSection({required this.flow});

  final UpdateState flow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(updateFlowProvider.notifier);

    return switch (flow) {
      UpdateIdle() => ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Check for updates'),
          onTap: notifier.check,
        ),
      UpdateChecking() => const ListTile(
          leading: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Checking'),
        ),
      UpdateChecked(status: UpToDate()) => ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: const Text('Up to date'),
          subtitle: const Text('Tap to check again'),
          onTap: notifier.check,
        ),
      UpdateChecked(status: UpdateCheckFailed(:final reason)) => ListTile(
          leading: Icon(Icons.cloud_off, color: theme.colorScheme.error),
          title: const Text('Could not check'),
          subtitle: Text('$reason Tap to try again.'),
          onTap: notifier.check,
        ),
      UpdateChecked(status: UpdateTooOld(:final release)) => _Note(
          // Said out loud. Reporting "up to date" to someone several versions
          // behind is the worst of the options.
          'Version ${release.version} is available, but this install is too '
          'far behind to update to it directly. Install it from the builds '
          'folder in OneDrive instead.',
          theme: theme,
        ),
      UpdateChecked(status: UpdateAvailable(:final release)) =>
        _Available(release: release),
      UpdateDownloading(:final release, :final progress) => ListTile(
          leading: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress > 0 ? progress : null,
            ),
          ),
          title: Text('Downloading ${release.version}'),
          subtitle: Text('${(progress * 100).round()}%'),
        ),
      UpdateReadyToInstall(:final release) => ListTile(
          leading: const Icon(Icons.download_done),
          title: Text('${release.version} downloaded'),
          subtitle: const Text(
            'Android will ask you to confirm. If nothing appeared, tap to try '
            'again.',
          ),
          onTap: () => notifier.retryInstall(release, (flow as UpdateReadyToInstall).path),
        ),
      UpdateNeedsPermission(:final release, :final path) => _NeedsPermission(
          release: release,
          path: path,
        ),
      UpdateFailed(:final reason) => ListTile(
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: const Text('That did not work'),
          subtitle: Text('$reason Tap to start again.'),
          onTap: notifier.reset,
        ),
    };
  }
}

class _Available extends ConsumerWidget {
  const _Available({required this.release});

  final AppRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final size = release.readableSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(Icons.system_update, color: theme.colorScheme.primary),
          title: Text('Version ${release.version} is available'),
          // The size is here because a phone on mobile data deserves to know
          // what it is about to spend before it spends it.
          subtitle: Text(size == null ? 'Build ${release.build}' : '$size download'),
        ),
        if (release.notes != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              release.notes!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: FilledButton.icon(
            onPressed: () => ref
                .read(updateFlowProvider.notifier)
                .downloadAndInstall(release),
            icon: const Icon(Icons.download),
            label: const Text('Download and install'),
          ),
        ),
      ],
    );
  }
}

class _NeedsPermission extends ConsumerWidget {
  const _NeedsPermission({required this.release, required this.path});

  final AppRelease release;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(updateFlowProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Note(
          'Version ${release.version} is downloaded, but Android has not been '
          'told that MyEmail may install apps. Allow it once, then come back '
          'and tap Install. The download is kept, so nothing is downloaded '
          'twice.',
          theme: theme,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              FilledButton(
                onPressed: notifier.openPermissionSettings,
                child: const Text('Open settings'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => notifier.retryInstall(release, path),
                child: const Text('Install'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
