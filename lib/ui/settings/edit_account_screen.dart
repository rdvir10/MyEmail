import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../state/providers.dart';

/// Rename an account and pick the colour it wears in the folder tree.
///
/// Only those two. The address, the provider and the sign-in are what the
/// stored secret was proved against and what every cached folder and message
/// is filed under, so changing one of them is adding a different account
/// rather than editing this one; the screen shows them, greyed, and says so,
/// which is more use than leaving someone hunting for a field that was never
/// going to be there.
class EditAccountScreen extends ConsumerStatefulWidget {
  const EditAccountScreen({super.key, required this.account});

  final Account account;

  @override
  ConsumerState<EditAccountScreen> createState() => _EditAccountScreenState();
}

class _EditAccountScreenState extends ConsumerState<EditAccountScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.account.displayName);
  late int _color = widget.account.colorValue;
  bool _busy = false;
  String? _error;

  /// The same four the app assigns to new accounts, plus enough more to tell
  /// several mailboxes apart at a glance.
  static const _palette = [
    0xFF0F6CBD,
    0xFF107C41,
    0xFFB4009E,
    0xFFCA5010,
    0xFF8764B8,
    0xFF00838F,
    0xFFB3261E,
    0xFF5B5FC7,
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _changed =>
      _name.text.trim() != widget.account.displayName ||
      _color != widget.account.colorValue;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountsProvider.notifier).edit(
            accountId: widget.account.id,
            displayName: _name.text,
            colorValue: _color,
          );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Edit account'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            enabled: !_busy,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name in the folder list',
              helperText: 'Left empty, the current name is kept.',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 28),
          Text('Colour', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Marks this account in the folder tree and in the unified Inbox.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in _palette)
                _ColorDot(
                  value: value,
                  selected: value == _color,
                  onTap: _busy ? null : () => setState(() => _color = value),
                ),
            ],
          ),
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _FixedField(
            label: 'Address',
            value: widget.account.emailAddress,
            theme: theme,
          ),
          _FixedField(
            label: 'Signs in with',
            value: switch (widget.account.authMethod) {
              AuthMethod.appPassword => 'An app password',
              AuthMethod.oauth => '${widget.account.provider.label} sign-in',
            },
            theme: theme,
          ),
          const SizedBox(height: 8),
          Text(
            'The address and the sign-in cannot be changed here. Every cached '
            'folder and message is filed under this account, so a different '
            'address means a different account: add it, then remove this one.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: (_busy || !_changed) ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(value),
            shape: BoxShape.circle,
            // A ring rather than a tick alone: on the darker swatches a white
            // tick is the only thing visible and it is easy to miss which dot
            // it is sitting on.
            border: selected
                ? Border.all(color: theme.colorScheme.onSurface, width: 3)
                : null,
          ),
          child: selected
              ? const Icon(Icons.check, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }
}

class _FixedField extends StatelessWidget {
  const _FixedField({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Text(value, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      );
}
