import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../state/compose_providers.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import 'compose_screen.dart';

/// Open a compose window.
///
/// Building the draft needs the original's body for a reply or forward, which
/// may mean a fetch, so this shows a brief blocking spinner rather than
/// opening an editor that then rewrites itself under the user.
Future<void> openCompose(
  BuildContext context,
  WidgetRef ref, {
  required ComposeKind kind,
  MailMessage? original,
  String? accountId,
}) async {
  final resolvedAccount = accountId ??
      original?.accountId ??
      _accountForCurrentFolder(ref) ??
      ref.read(accountsProvider).value?.firstOrNull?.id;

  if (resolvedAccount == null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Add an account first.')));
    return;
  }

  final draftFuture = buildDraft(
    ref: ref,
    kind: kind,
    accountId: resolvedAccount,
    original: original,
  );

  // Only show the spinner if the build is actually slow; a cached body makes
  // it instant and a flashed dialog looks like a glitch.
  final draft = await _withSpinner(context, draftFuture);
  if (draft == null || !context.mounted) return;

  await Navigator.of(context).push(
    MaterialPageRoute<bool>(builder: (_) => ComposeScreen(draft: draft)),
  );
}

/// Which account the open folder belongs to. Null in the unified Inbox,
/// where there is no single answer.
String? _accountForCurrentFolder(WidgetRef ref) {
  final folderId = ref.read(effectiveSelectedFolderIdProvider);
  if (folderId == null || folderId == kUnifiedInboxId) return null;
  return ref.read(folderIndexProvider)[folderId]?.accountId;
}

Future<T?> _withSpinner<T>(BuildContext context, Future<T> work) async {
  var done = false;
  var dialogShown = false;
  final result = work.whenComplete(() => done = true);

  await Future<void>.delayed(const Duration(milliseconds: 150));
  if (!done && context.mounted) {
    dialogShown = true;
    unawaitedShowDialog(context);
  }

  final value = await result;
  if (dialogShown && context.mounted) Navigator.of(context).pop();
  return value;
}

void unawaitedShowDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
}
