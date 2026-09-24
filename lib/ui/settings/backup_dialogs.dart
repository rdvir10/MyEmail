import 'package:flutter/material.dart';

import '../../data/backup/secret_vault.dart';

/// What the export dialog settled on. Null from [askExportChoice] means the
/// person backed out.
class ExportChoice {
  const ExportChoice({this.passphrase});

  /// Null for a file with no sign-in details in it.
  final String? passphrase;

  bool get includesSignIns => passphrase != null;
}

/// Ask whether the sign-in details should travel, and under what passphrase.
///
/// The choice is presented as a real trade rather than a checkbox with a
/// warning icon, because both answers are defensible and the right one depends
/// on where the file is going to live.
Future<ExportChoice?> askExportChoice(BuildContext context) =>
    showDialog<ExportChoice>(
      context: context,
      builder: (_) => const _ExportDialog(),
    );

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _include = true;
  bool _show = false;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _text => _passphrase.text;
  VaultStrength get _strength => VaultStrength.of(_text);
  bool get _matches => _text == _confirm.text;

  bool get _ready =>
      !_include || (!_strength.refused && _matches);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Save settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include sign-in details'),
              subtitle: const Text(
                'Restoring then needs no passwords. The file is encrypted with '
                'a passphrase you choose.',
              ),
              value: _include,
              onChanged: (v) => setState(() => _include = v),
            ),
            const SizedBox(height: 8),
            Text(
              _include
                  // Said plainly. Someone choosing this is putting a key to
                  // their mailbox in a file that will sit in a cloud folder,
                  // and the only thing between the two is the passphrase.
                  ? 'The file will be worth as much as the passphrase. Anyone '
                      'who has both can read your mail. Lose the passphrase '
                      'and the sign-in details in the file are gone.'
                  : 'No passwords or tokens go in the file, so it is safe to '
                      'keep anywhere. Each account needs signing in once after '
                      'a restore.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (_include) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _passphrase,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Hide' : 'Show',
                    icon: Icon(_show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Text(
                '${_strength.label}. ${_strength.advice}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _strength.refused
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Type it again',
                  // A typo here cannot be recovered from later: the file is
                  // the only copy and nothing else knows the passphrase.
                  errorText: (_confirm.text.isNotEmpty && !_matches)
                      ? 'These do not match.'
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ready
              ? () => Navigator.of(context).pop(
                    ExportChoice(passphrase: _include ? _text : null),
                  )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Ask for the passphrase that opens a file.
///
/// [attemptFailed] switches the copy after a wrong answer, so a second try
/// does not look like the first one having been ignored.
Future<String?> askRestorePassphrase(
  BuildContext context, {
  bool attemptFailed = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _RestoreDialog(attemptFailed: attemptFailed),
    );

class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog({required this.attemptFailed});

  final bool attemptFailed;

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _passphrase = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _submit() {
    if (_passphrase.text.isEmpty) return;
    Navigator.of(context).pop(_passphrase.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Passphrase needed'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.attemptFailed
                ? 'That passphrase did not open the file. Try again.'
                : 'This backup has sign-in details in it. Enter the passphrase '
                    'you chose when you saved it.',
            style: widget.attemptFailed
                ? theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)
                : theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passphrase,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Passphrase',
              suffixIcon: IconButton(
                tooltip: _show ? 'Hide' : 'Show',
                icon: Icon(_show
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _passphrase.text.isEmpty ? null : _submit,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
