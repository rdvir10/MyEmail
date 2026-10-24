import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_tip.dart';
import '../../state/compose_providers.dart' show addressesLookValid, parseAddresses;
import '../../state/providers.dart';

/// Outlook's MailTips, under the recipients: who has an automatic reply on
/// (with its first words), who is outside the organisation, which list
/// reaches many people. Asked of Exchange a moment after the recipients
/// change, for a message from a Microsoft account; nothing for any other.
class MailTipsLine extends ConsumerStatefulWidget {
  const MailTipsLine({
    super.key,
    required this.accountId,
    required this.fields,
  });

  /// The account the message goes from: Exchange answers for its own.
  final String accountId;

  /// To, Cc and Bcc.
  final List<TextEditingController> fields;

  /// How long the recipients have to stay as they are before Exchange is
  /// asked: a request per letter typed is a request for nothing.
  static const pause = Duration(milliseconds: 800);

  @override
  ConsumerState<MailTipsLine> createState() => _MailTipsLineState();
}

class _MailTipsLineState extends ConsumerState<MailTipsLine> {
  Timer? _wait;
  String _asked = '';
  Map<String, MailTip> _tips = const {};
  Map<String, String> _names = const {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      f.addListener(_changed);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void didUpdateWidget(MailTipsLine old) {
    super.didUpdateWidget(old);
    if (old.accountId != widget.accountId) {
      _asked = '';
      _changed();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    for (final f in widget.fields) {
      f.removeListener(_changed);
    }
    super.dispose();
  }

  void _changed() {
    _wait?.cancel();
    _wait = Timer(MailTipsLine.pause, _ask);
  }

  Future<void> _ask() async {
    if (!mounted) return;
    final people = [
      for (final f in widget.fields) ...parseAddresses(f.text),
    ].where((a) => addressesLookValid([a])).toList();
    final emails = {for (final a in people) a.email.toLowerCase()}.toList()
      ..sort();
    final key = '${widget.accountId}|${emails.join(',')}';
    if (key == _asked) return;
    _asked = key;
    if (emails.isEmpty) {
      setState(() => _tips = const {});
      return;
    }
    final tips =
        await ref.read(mailEngineProvider).mailTips(widget.accountId, emails);
    if (!mounted || key != _asked) return;
    setState(() {
      _tips = {for (final t in tips) t.email.toLowerCase(): t};
      _names = {
        for (final a in people)
          a.email.toLowerCase(): (a.name?.trim().isNotEmpty ?? false)
              ? a.name!.trim()
              : a.email,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final MapEntry(key: email, value: tip) in _tips.entries)
        if (!tip.isEmpty) ...tip.linesFor(_names[email] ?? email),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(
              Icons.info_outline,
              size: 16,
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
