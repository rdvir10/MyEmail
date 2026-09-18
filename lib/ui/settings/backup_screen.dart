import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/backup_service.dart';
import '../../data/backup/secret_vault.dart';
import '../../domain/settings_backup.dart';
import '../../state/backup_providers.dart';
import 'backup_dialogs.dart';

/// Settings, Backup: write everything to a file, or read a file back.
///
/// The one thing this screen has to be honest about is what is not in the
/// file. Someone restoring onto a new tablet expects to be reading mail a
/// moment later, and will instead meet accounts that cannot connect. Saying so
/// before the export, and again after the import, is the difference between a
/// deliberate trade and an apparent bug.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key, this.isFirstRun = false});

  /// Reached from the welcome screen rather than from Settings.
  ///
  /// A new device has no accounts, so Settings is unreachable — the shell
  /// shows the add-account screen instead — and restoring is precisely what
  /// someone with a backup wants to do first. On that path the screen leads
  /// with Restore, drops Save (there is nothing yet to save), and closes
  /// itself once accounts exist, which drops the person into their mail.
  final bool isFirstRun;

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  String? _error;
  String? _done;

  Future<void> _export() async {
    final choice = await askExportChoice(context);
    if (choice == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final backup = await ref
          .read(backupServiceProvider)
          .export(passphrase: choice.passphrase);
      final saved = await ref.read(backupFilesProvider).save(
            fileName: _suggestedName(backup),
            contents: backup.toJsonString(),
          );
      if (!mounted) return;
      setState(() => _done = saved
          ? 'Saved ${backup.summary}.${choice.includesSignIns ? ' Keep the passphrase safe: without it the sign-in details cannot be recovered.' : ' Sign-in details are not in the file.'}'
          : null);
    } on VaultPassphraseTooShort catch (e) {
      if (mounted) setState(() => _error = e.message);
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

      // Ask for the passphrase only once the restore is actually going ahead,
      // and keep asking on a wrong answer rather than making the person start
      // from the file picker again.
      String? passphrase;
      if (backup.hasSecrets) {
        var failed = false;
        while (true) {
          if (!mounted) return;
          passphrase = await askRestorePassphrase(
            context,
            attemptFailed: failed,
          );
          if (passphrase == null || !mounted) return;
          try {
            await ref
                .read(backupServiceProvider)
                .vault
                .open(sealed: backup.sealedSecrets!, passphrase: passphrase);
            break;
          } on VaultWrongPassphrase {
            failed = true;
          }
        }
      }
      if (!mounted) return;
      setState(() => _busy = true);

      final report = await ref
          .read(backupServiceProvider)
          .import(backup, passphrase: passphrase);
      ref.invalidate(accountsProviderForRefresh);
      if (!mounted) return;
      setState(() => _done = _reportText(report));

      // On the welcome path there is now something behind this screen worth
      // seeing, so get out of the way rather than leaving the person on a
      // success message with no obvious next step.
      if (widget.isFirstRun && report.accountsAdded.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).maybePop();
      }
    } on VaultUnreadable catch (e) {
      if (mounted) setState(() => _error = e.message);
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
    if (report.accountsSignedIn > 0) {
      parts.add('${report.accountsSignedIn} signed in');
    }
    final summary = '${parts.join(', ')}.';
    if (!report.needsSignIn) return summary;
    return '$summary Open Settings, Accounts to sign the remaining '
        '${report.awaitingSignIn == 1 ? 'one' : 'ones'} in.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isFirstRun ? 'Restore' : 'Backup'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            widget.isFirstRun
                ? 'If you saved a backup from another device, this brings back '
                    'your accounts and every setting.'
                : 'Saves your accounts and every setting to one file: the '
                    'folder tree, Quick Steps, signatures, swipe actions and '
                    'the rest.',
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
                    'Sign-in details are only in the file if you asked for '
                    'them, and then they are encrypted with a passphrase you '
                    'choose. With them, a restore needs nothing else. Without '
                    'them, the file is safe to keep anywhere and each account '
                    'is signed in once afterwards.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          if (widget.isFirstRun) ...[
            FilledButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.restore),
              label: const Text('Choose a backup file'),
            ),
          ] else ...[
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
          ],
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
