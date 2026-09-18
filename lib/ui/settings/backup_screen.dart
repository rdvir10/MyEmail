import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/backup_service.dart';
import '../../domain/settings_backup.dart';
import '../../state/backup_providers.dart';

/// Settings, Backup: write everything to a file, or read a file back.
///
/// The one thing this screen has to be honest about is what is not in the
/// file. Someone restoring onto a new tablet expects to be reading mail a
/// moment later, and will instead meet accounts that cannot connect. Saying so
/// before the export, and again after the import, is the difference between a
/// deliberate trade and an apparent bug.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  String? _error;
  String? _done;

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final backup = ref.read(backupServiceProvider).export();
      final saved = await ref.read(backupFilesProvider).save(
            fileName: _suggestedName(backup),
            contents: backup.toJsonString(),
          );
      if (!mounted) return;
      setState(() => _done = saved
          ? 'Saved ${backup.summary}. Sign-in details are not in the file.'
          : null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save the file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _suggestedName(SettingsBackup backup) {
    final at = (backup.exportedAt ?? DateTime.now()).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'myemail-settings-${at.year}-${two(at.month)}-${two(at.day)}.json';
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final contents = await ref.read(backupFilesProvider).pick();
      if (contents == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final backup = SettingsBackup.parse(contents);
      if (!mounted) return;

      // Stop looking busy before the dialog goes up. A spinner turning behind
      // a modal question suggests something is still happening and the
      // question is a formality, when in fact nothing proceeds until it is
      // answered.
      setState(() => _busy = false);

      // Restoring writes over the folder tree's state, the Quick Steps and
      // the signatures on this device. That is not obvious from a button
      // labelled Restore, so it is said before anything is written.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore these settings?'),
          content: Text(
            'The file holds ${backup.summary}.\n\n'
            'This replaces the settings on this device. Accounts already set '
            'up here keep their sign-in; any new ones will need signing in, '
            'because sign-in details are never put in the file.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);

      final report = await ref.read(backupServiceProvider).import(backup);
      ref.invalidate(accountsProviderForRefresh);
      if (!mounted) return;
      setState(() => _done = _reportText(report));
    } on BackupFormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not restore: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _reportText(RestoreReport report) {
    final parts = <String>[
      '${report.settingsRestored} '
          '${report.settingsRestored == 1 ? 'setting' : 'settings'} restored',
    ];
    if (report.accountsAdded.isNotEmpty) {
      parts.add('${report.accountsAdded.length} '
          '${report.accountsAdded.length == 1 ? 'account' : 'accounts'} added');
    }
    if (report.accountsAlreadyHere.isNotEmpty) {
      parts.add('${report.accountsAlreadyHere.length} already here');
    }
    final summary = '${parts.join(', ')}.';
    if (!report.needsSignIn) return summary;
    return '$summary Open Settings, Accounts to sign the new '
        '${report.accountsAdded.length == 1 ? 'one' : 'ones'} in.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Saves your accounts and every setting to one file: the folder '
            'tree, Quick Steps, signatures, swipe actions and the rest.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'App passwords and Microsoft sign-ins are never written to '
                    'the file. Either one would open your whole mailbox to '
                    'anyone who found it, and a settings file tends to end up '
                    'in a cloud folder or a downloads directory. Restoring '
                    'brings the accounts back; each needs signing in once, '
                    'which is one field or one button.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.save_alt),
            label: const Text('Save to a file'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.restore),
            label: const Text('Restore from a file'),
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 20),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          if (_done != null) ...[
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _done!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Choosing where a file goes, and which file to read.
///
/// An interface so the screen can be tested without a platform channel: the
/// real one opens Android's document picker, which a widget test has no way
/// to drive.
abstract class BackupFiles {
  /// Returns false if the person backed out of the save dialog.
  Future<bool> save({required String fileName, required String contents});

  /// Null if they backed out of the open dialog.
  Future<String?> pick();
}

class PlatformBackupFiles implements BackupFiles {
  const PlatformBackupFiles();

  @override
  Future<bool> save({
    required String fileName,
    required String contents,
  }) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(contents)),
      mimeType: 'application/json',
      dialogTitle: 'Save MyEmail settings',
    );
    return uri != null;
  }

  @override
  Future<String?> pick() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return null;
    return utf8.decode(await files.first.readAsBytes());
  }
}
