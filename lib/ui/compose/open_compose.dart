import 'dart:async';

import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_message.dart';
import '../../state/compose_providers.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../../state/window_providers.dart';
import '../../domain/window_handoff.dart';
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
  List<DraftAttachment> attachments = const [],
  String? subject,
  String? bodyText,
}) async {
  final resolvedAccount = accountId ??
      original?.accountId ??
      _accountForCurrentFolder(ref) ??
      ref.read(accountsProvider).value?.firstOrNull?.id;

  if (resolvedAccount == null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(duration: kBottomMessage, content: Text('Add an account first.')));
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
  final built = await _withSpinner(context, draftFuture);
  if (built == null || !context.mounted) return;
  var draft = built;
  if (attachments.isNotEmpty) {
    draft = draft.copyWith(attachments: [...draft.attachments, ...attachments]);
  }
  if (subject != null) draft = draft.copyWith(subject: subject);
  if (bodyText != null) {
    // Shared text goes above whatever the draft started with — the
    // signature, typically — as its own paragraphs, escaped: it is text,
    // not markup, whatever it happens to contain.
    draft = draft.copyWith(htmlBody: '${textAsHtml(bodyText)}${draft.htmlBody}');
  }

  // Closing it untouched loses nothing only if nothing came in from outside:
  // text or files shared from another app are asked about.
  final disposable =
      attachments.isEmpty && subject == null && bodyText == null;

  // A window of its own, if that is how writing is set to happen and this
  // platform has windows. The draft is built here either way, so the
  // window opens with the quoted message already in it.
  if (ref.read(composeInWindowProvider) &&
      (ref.read(windowsAvailableProvider).value ?? false)) {
    // A window the system did not open falls through to here.
    if (await ref
        .read(windowOpenerProvider)
        .open(ComposeWindow(draft, disposable: disposable))) {
      return;
    }
    if (!context.mounted) return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute<bool>(
      builder: (_) => ComposeScreen(draft: draft, disposable: disposable),
    ),
  );
}

/// Plain text as HTML paragraphs, with nothing in it taken as markup.
String textAsHtml(String text) {
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return [
    for (final paragraph in escaped.split(RegExp(r'\n{2,}')))
      '<p>${paragraph.replaceAll('\n', '<br>')}</p>',
  ].join();
}

/// Reopen a saved draft for editing.
///
/// This is what tapping a message in Drafts does instead of opening the
/// reading pane. Reading a message you wrote yourself and cannot reply to is
/// not a useful screen.
Future<void> openSavedDraft(
  BuildContext context,
  WidgetRef ref,
  MailMessage message,
) async {
  final Draft? loaded;
  try {
    loaded = await _withSpinner(
      context,
      draftFromMessage(ref: ref, message: message),
    );
  } on DraftNotLoaded catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(duration: kBottomMessage, content: Text(e.message)));
    }
    return;
  }
  final draft = loaded;
  if (draft == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<bool>(builder: (_) => ComposeScreen(draft: draft)),
  );
}

/// Whether [folderId] is a Drafts folder, so a tap opens the editor.
bool isDraftsFolder(WidgetRef ref, String? folderId) {
  if (folderId == null) return false;
  return ref.read(folderIndexProvider)[folderId]?.role == FolderRole.drafts;
}

/// Which account the open folder belongs to. Null in the unified Inbox,
/// where there is no single answer.
String? _accountForCurrentFolder(WidgetRef ref) {
  final folderId = ref.read(effectiveSelectedFolderIdProvider);
  if (folderId == null || folderId == kUnifiedInboxId) return null;
  return ref.read(folderIndexProvider)[folderId]?.accountId;
}

/// [work]'s result, with a spinner over the screen if it takes long enough
/// to notice. Null if the spinner was dismissed with Back before the work
/// finished: that was the person giving up on waiting, and what they were
/// waiting for is no longer wanted.
Future<T?> _withSpinner<T>(BuildContext context, Future<T> work) async {
  var done = false;
  DialogRoute<void>? spinner;
  final result = work.whenComplete(() => done = true);
  // Listened to at once, so a failure inside the first 150 ms is not
  // reported as unhandled before the await below gets to it.
  unawaited(result.then<void>((_) {}, onError: (Object _) {}));

  await Future<void>.delayed(const Duration(milliseconds: 150));
  if (!done && context.mounted) {
    // A route kept hold of, rather than showDialog, so the one taken down
    // afterwards is this one.
    spinner = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    unawaited(Navigator.of(context, rootNavigator: true).push(spinner));
  }

  final T value;
  var dismissed = false;
  try {
    value = await result;
  } finally {
    // On a failure too, or the spinner stays up over a screen that has
    // nothing left to wait for. That route and no other: popping whatever
    // was on top closed the message being read when the spinner had
    // already gone with Back, and compose then opened over the list.
    if (spinner != null) {
      dismissed = !spinner.isActive;
      if (!dismissed) spinner.navigator?.removeRoute(spinner);
    }
  }
  return dismissed ? null : value;
}
