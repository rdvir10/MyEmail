import 'dart:math';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/account.dart';
import '../../domain/folder_capabilities.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';

/// Pure translations between enough_mail's types and the app's domain.
///
/// Kept free of any client or socket so they can be tested with hand-built
/// mailboxes and parsed MIME text. The engine that drives the connection is
/// thin and is exercised against a live account instead.

/// Paths in the domain always use `/`. Servers use their own delimiter
/// (Gmail `/`, many others `.`), so the engine converts at the boundary.
String toModelPath(String serverPath, String delimiter) =>
    delimiter == '/' ? serverPath : serverPath.split(delimiter).join('/');

String toServerPath(String modelPath, String delimiter) =>
    delimiter == '/' ? modelPath : modelPath.split('/').join(delimiter);

FolderRole roleForMailbox(em.Mailbox box) {
  if (box.isInbox) return FolderRole.inbox;
  if (box.isDrafts) return FolderRole.drafts;
  if (box.isSent) return FolderRole.sent;
  if (box.isTrash) return FolderRole.deleted;
  if (box.isJunk) return FolderRole.junk;
  if (box.isArchive) return FolderRole.archive;
  // Gmail advertises "All Mail" with \All, which enough_mail may or may not
  // fold into its archive flag depending on version; check by name too.
  if (box.flags.any((f) => f.name == 'all')) return FolderRole.archive;
  return FolderRole.user;
}

/// Gmail's Starred (\Flagged) and Important (\Important) are labels the
/// server maintains itself: browsable, droppable onto, but not renamable or
/// deletable. They come through as user folders with locked-down capabilities.
bool _isServerManagedLabel(em.Mailbox box) =>
    box.flags.any((f) => f.name == 'flagged' || f.name == 'important');

/// Map one server mailbox to a domain folder, or null when it is not a real
/// folder (Gmail's `[Gmail]` container is \Noselect).
///
/// System folders are flattened to the root regardless of where the server
/// puts them, so `[Gmail]/Sent Mail` sits beside the Inbox in the tree. User
/// folders keep their nesting when the parent path is itself a folder.
MailFolder? folderFromMailbox({
  required String accountId,
  required MailProvider provider,
  required em.Mailbox box,
  required Set<String> selectableModelPaths,
  int sortIndex = 0,
}) {
  if (box.isNotSelectable) return null;

  final delimiter = box.pathSeparator;
  final path = toModelPath(box.path, delimiter);
  final role = roleForMailbox(box);

  final capabilities = _isServerManagedLabel(box)
      ? const FolderCapabilities.systemFolder(canAcceptMessages: true)
      : FolderCapabilities.forGmail(role);

  String? parentId;
  if (role == FolderRole.user) {
    final cut = path.lastIndexOf('/');
    if (cut > 0) {
      final parentPath = path.substring(0, cut);
      if (selectableModelPaths.contains(parentPath)) {
        parentId = MailFolder.idFor(accountId, parentPath);
      }
    }
  }

  return MailFolder.at(
    accountId: accountId,
    path: path,
    role: role,
    capabilities: capabilities,
    parentId: parentId,
    unreadCount: box.messagesUnseen,
    totalCount: box.messagesExists,
    sortIndex: sortIndex,
  );
}

/// The sequence-number window for one page of a folder, newest first.
///
/// IMAP sequence numbers run 1..EXISTS oldest to newest, so page 0 is the
/// top of that range. Returns null when [offset] is past the end.
({int start, int end})? pageSequence({
  required int exists,
  required int offset,
  required int limit,
}) {
  final end = exists - offset;
  if (end < 1 || limit < 1) return null;
  final start = max(1, end - limit + 1);
  return (start: start, end: end);
}

MailAddress addressFromMime(em.MailAddress a) =>
    MailAddress(email: a.email, name: a.personalName);

/// Headers and flags from a fetched message. Needs UID, FLAGS, ENVELOPE and
/// BODYSTRUCTURE to have been fetched; the preview is filled in later from
/// the cached body, since Gmail offers no server-side preview.
MailMessage messageFromMime({
  required String accountId,
  required String folderId,
  required em.MimeMessage m,
  DateTime? fallbackDate,
}) {
  final uid = m.uid;
  if (uid == null) {
    throw ArgumentError('Message has no UID; fetch with UID in the criteria');
  }
  final subject = m.decodeSubject()?.trim();
  final from = m.from?.firstOrNull ?? m.sender;
  return MailMessage(
    id: MailMessage.idFor(folderId, uid),
    accountId: accountId,
    folderId: folderId,
    uid: uid,
    subject: (subject == null || subject.isEmpty) ? '(No subject)' : subject,
    from: from == null
        ? const MailAddress(email: '')
        : addressFromMime(from),
    to: [for (final a in m.to ?? const <em.MailAddress>[]) addressFromMime(a)],
    date: m.decodeDate() ?? fallbackDate ?? DateTime.now(),
    preview: '',
    isRead: m.isSeen,
    isFlagged: m.isFlagged,
    hasAttachments: m.hasAttachments(),
  );
}

/// The readable body: the plain-text part if the sender supplied one, else a
/// text rendering of the HTML so the browser preview and any text-only view
/// still show something. The HTML travels alongside for the WebView.
MailBody bodyFromMime(em.MimeMessage m) {
  final html = m.decodeTextHtmlPart();
  final text = m.decodeTextPlainPart();
  return MailBody(
    text: (text != null && text.trim().isNotEmpty)
        ? text
        : html != null
            ? htmlToText(html)
            : '',
    html: html,
  );
}

/// A rough text rendering of HTML for previews and fallbacks: block tags
/// become line breaks, other tags vanish, common entities are decoded.
String htmlToText(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>',
      caseSensitive: false, dotAll: true), '');
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(
      RegExp(r'</(p|div|tr|li|h[1-6]|blockquote)>', caseSensitive: false),
      '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
  s = s.replaceAll(RegExp(r' *\n *'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

/// The first line or so of a body, for the message list.
String previewFromText(String text, {int maxLength = 140}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= maxLength
      ? flat
      : '${flat.substring(0, maxLength).trimRight()}…';
}
