import 'dart:math';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/account.dart';
import '../../domain/folder_capabilities.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import 'imap_transport.dart';

/// `<accountId>:<path>`; account ids never contain a colon.
(String accountId, String path) splitFolderId(String folderId) {
  final i = folderId.indexOf(':');
  if (i < 0) throw ArgumentError('Not a folder id: $folderId');
  return (folderId.substring(0, i), folderId.substring(i + 1));
}

/// `<folderId>#<uid>`.
(String folderId, int uid) splitMessageId(String messageId) {
  final i = messageId.lastIndexOf('#');
  if (i < 0) throw ArgumentError('Not a message id: $messageId');
  return (messageId.substring(0, i), int.parse(messageId.substring(i + 1)));
}

/// A transport-level folder into the domain, with nesting resolved against
/// the set of paths that exist. Mirrors [folderFromMailbox] for callers that
/// have already left enough_mail types behind.
MailFolder folderFromRemote({
  required String accountId,
  required MailProvider provider,
  required RemoteFolder remote,
  required Set<String> allPaths,
  int sortIndex = 0,
}) {
  final capabilities = remote.isServerManaged
      ? const FolderCapabilities.systemFolder(canAcceptMessages: true)
      : FolderCapabilities.forProvider(provider, remote.role);
  String? parentId;
  if (remote.role == FolderRole.user) {
    final cut = remote.path.lastIndexOf('/');
    if (cut > 0) {
      final parent = remote.path.substring(0, cut);
      if (allPaths.contains(parent)) parentId = MailFolder.idFor(accountId, parent);
    }
  }
  return MailFolder.at(
    accountId: accountId,
    path: remote.path,
    role: remote.role,
    capabilities: capabilities,
    parentId: parentId,
    unreadCount: remote.unread,
    totalCount: remote.total,
    sortIndex: sortIndex,
  );
}

/// The transport's view of a fetched header. Needs UID, FLAGS, ENVELOPE and
/// BODYSTRUCTURE in the fetch.
RemoteHeader remoteHeaderFromMime(em.MimeMessage m, {DateTime? fallbackDate}) {
  final uid = m.uid;
  if (uid == null) {
    throw ArgumentError('Message has no UID; fetch with UID in the criteria');
  }
  final subject = m.decodeSubject()?.trim();
  final from = m.from?.firstOrNull ?? m.sender;
  final sender =
      from == null ? const MailAddress(email: '') : addressFromMime(from);
  return RemoteHeader(
    uid: uid,
    subject: (subject == null || subject.isEmpty) ? '(No subject)' : subject,
    from: sender,
    to: [for (final a in m.to ?? const <em.MailAddress>[]) addressFromMime(a)],
    cc: [for (final a in m.cc ?? const <em.MailAddress>[]) addressFromMime(a)],
    replyTo: _replyToOf(m, sender),
    date: m.decodeDate() ?? fallbackDate ?? DateTime.now(),
    isRead: m.isSeen,
    isFlagged: m.isFlagged,
    hasAttachments: m.hasAttachments(),
    attachmentBytes: attachmentBytesOf(m),
    isMeeting: carriesInvitation(m),
    messageId: normaliseMessageId(
      m.envelope?.messageId ?? m.getHeaderValue('message-id'),
    ),
    inReplyTo: normaliseMessageId(
      m.envelope?.inReplyTo ?? m.getHeaderValue('in-reply-to'),
    ),
  );
}

/// Reply-To from the ENVELOPE the header fetch already asks for, or from
/// the header itself when the message was parsed whole.
List<MailAddress> _replyToOf(em.MimeMessage m, MailAddress sender) {
  final listed = m.envelope?.replyTo ??
      m.decodeHeaderMailAddressValue('reply-to') ??
      const <em.MailAddress>[];
  return replyToBesidesSender(
    [for (final a in listed) addressFromMime(a)],
    sender,
  );
}

/// A `Message-ID` reduced to the part that identifies it.
///
/// Servers are inconsistent about the angle brackets and the whitespace, and
/// `In-Reply-To` sometimes carries several ids where the spec allows one. The
/// two ends of a link have to match exactly or the thread breaks, so both go
/// through here. The first id wins: that is the message actually answered.
String? normaliseMessageId(String? raw) {
  if (raw == null) return null;
  // `*` rather than `+`: an empty `<>` is a real thing servers send, and it
  // has to come back as null rather than as the literal brackets, which would
  // then match every other empty one and thread them together.
  final match = RegExp(r'<([^>]*)>').firstMatch(raw);
  final value = (match?.group(1) ?? raw).trim();
  return value.isEmpty ? null : value;
}

RemoteFolder remoteFolderFromMailbox(em.Mailbox box) => RemoteFolder(
      path: toModelPath(box.path, box.pathSeparator),
      role: roleForMailbox(box),
      isServerManaged: isServerManagedLabel(box),
      unread: box.messagesUnseen,
      total: box.messagesExists,
    );

/// Pure translations between enough_mail's types and the app's domain.
///
/// Kept free of any client or socket so they can be tested with hand-built
/// mailboxes and parsed MIME text. The engine that drives the connection is
/// thin and is exercised against a live account instead.

/// A folder name with a `/` in it, made safe to put in a path.
///
/// The app's paths are slash-separated, and both a folder's parent and its
/// own name are read back by splitting on that slash. Outlook lets a
/// folder be called "AP/AR", and a mailbox at work usually has one: left
/// alone it fakes a level, so the folder lands under a parent it does not
/// belong to, or at the top level showing half its own name.
///
/// U+2215, the division slash, stands in for it. It is not the separator,
/// it looks like what the person named the folder, and nothing is lost by
/// it: a Graph mailbox is addressed by folder id, not by this path.
String safePathSegment(String name) => name.replaceAll('/', '∕');

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
bool isServerManagedLabel(em.Mailbox box) =>
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

  final capabilities = isServerManagedLabel(box)
      ? const FolderCapabilities.systemFolder(canAcceptMessages: true)
      : FolderCapabilities.forProvider(provider, role);

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
  final sender =
      from == null ? const MailAddress(email: '') : addressFromMime(from);
  return MailMessage(
    id: MailMessage.idFor(folderId, uid),
    accountId: accountId,
    folderId: folderId,
    uid: uid,
    subject: (subject == null || subject.isEmpty) ? '(No subject)' : subject,
    from: sender,
    to: [for (final a in m.to ?? const <em.MailAddress>[]) addressFromMime(a)],
    cc: [for (final a in m.cc ?? const <em.MailAddress>[]) addressFromMime(a)],
    replyTo: _replyToOf(m, sender),
    date: m.decodeDate() ?? fallbackDate ?? DateTime.now(),
    preview: '',
    isRead: m.isSeen,
    isFlagged: m.isFlagged,
    hasAttachments: m.hasAttachments(),
    messageId: normaliseMessageId(
      m.envelope?.messageId ?? m.getHeaderValue('message-id'),
    ),
    inReplyTo: normaliseMessageId(
      m.envelope?.inReplyTo ?? m.getHeaderValue('in-reply-to'),
    ),
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
    calendar: calendarPartOf(m),
  );
}

/// Is this file the invitation rather than something attached beside it?
///
/// The media type is the right answer and usually the one given. It is not
/// always given: a mail system that does not know what an `.ics` is sends it
/// as `application/octet-stream`, and one that does may still call it
/// `application/ics`, which is not a registered type but is common. The name
/// settles those two, and nothing else is called `.ics`.
bool isCalendarFile(String mimeType, String name) {
  final type = mimeType.toLowerCase();
  return type.startsWith('text/calendar') ||
      type == 'application/ics' ||
      type == 'application/calendar' ||
      name.toLowerCase().trim().endsWith('.ics');
}

/// The invitation inside a message, if it carries one: the first
/// `text/calendar` part, decoded. Outlook and Google both send meeting
/// requests this way, beside the readable body.
///
/// Failing that, a part that is an `.ics` by name. A meeting booked outside
/// a mail system — a Zoom or Webex invitation passed on, an agenda sent by an
/// assistant — arrives as a file hung off an ordinary message, and one sent
/// with the wrong media type is still an invitation.
String? calendarPartOf(em.MimeMessage m) {
  final part = m.getPartWithMediaSubtype(em.MediaSubtype.textCalendar);
  final text = part?.decodeContentText();
  if (text != null && text.trim().isNotEmpty) return text;
  return _calendarFileIn(m);
}

String? _calendarFileIn(em.MimeMessage m) {
  for (final disposition in [
    em.ContentDisposition.attachment,
    em.ContentDisposition.inline,
  ]) {
    for (final info in m.findContentInfo(disposition: disposition)) {
      final type = info.contentType?.mediaType.toString() ?? '';
      if (!isCalendarFile(type, info.fileName ?? '')) continue;
      final text = m.getPart(info.fetchId)?.decodeContentText();
      if (text != null && text.trim().isNotEmpty) return text;
    }
  }
  return null;
}

/// Whether a message carries an invitation, from its structure alone.
///
/// The structure is what the header fetch already asks for, so this costs
/// nothing and can be known before a message is opened — which is the whole
/// point: a list that says which rows are meetings is a list you can read
/// without opening anything.
bool carriesInvitation(em.MimeMessage message) {
  if (message.getPartWithMediaSubtype(em.MediaSubtype.textCalendar) != null) {
    return true;
  }
  for (final disposition in [
    em.ContentDisposition.attachment,
    em.ContentDisposition.inline,
  ]) {
    for (final info in message.findContentInfo(disposition: disposition)) {
      final type = info.contentType?.mediaType.toString() ?? '';
      if (isCalendarFile(type, info.fileName ?? '')) return true;
    }
  }
  return false;
}

/// What the files on a message add up to, in bytes.
///
/// Free: the BODYSTRUCTURE the header fetch already asks for carries a size
/// per part, so this costs nothing beyond the arithmetic. Inline parts are
/// left out — a logo in a signature is not a file anyone attached, and
/// counting it would make every signed message look like it carries one.
int attachmentBytesOf(em.MimeMessage message) {
  var total = 0;
  for (final a in attachmentsOf(message)) {
    if (!a.isInline) total += a.sizeBytes;
  }
  return total;
}

/// What a message has attached, read from its structure alone.
///
/// Inline parts are kept but marked: a logo in a signature is not something
/// anyone attached on purpose, but a photo sent inline is still a photo, and
/// deciding which is which by guessing at the name is worse than showing
/// both and saying which is which.
///
/// Parts with no file name get one made from their type, because "open the
/// attachment" needs something to call it and "" is not something.
List<MailAttachment> attachmentsOf(em.MimeMessage message) {
  final found = <MailAttachment>[];
  for (final disposition in [
    em.ContentDisposition.attachment,
    em.ContentDisposition.inline,
  ]) {
    for (final info in message.findContentInfo(disposition: disposition)) {
      final mime = info.contentType?.mediaType.toString() ??
          'application/octet-stream';
      // The text of the message itself is a part like any other. It is the
      // body, not an attachment, and listing it as one is how "1 attachment"
      // appears on a plain note.
      if (disposition == em.ContentDisposition.inline &&
          mime.startsWith('text/')) {
        continue;
      }
      found.add(
        MailAttachment(
          id: info.fetchId,
          name: safeFileName(info.fileName ?? _nameFromType(mime, info.fetchId)),
          mimeType: mime,
          sizeBytes: info.size ?? 0,
          isInline: disposition == em.ContentDisposition.inline,
        ),
      );
    }
  }
  return found;
}

String _nameFromType(String mime, String fetchId) {
  final slash = mime.indexOf('/');
  final extension = slash < 0 ? 'bin' : mime.substring(slash + 1);
  return 'part-$fetchId.$extension';
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

/// An IMAP SEARCH criteria string for a free-text query.
///
/// Matches subject, sender or body, which is what people expect a mail
/// search box to do. Words are ANDed, since IMAP's default is to combine
/// criteria with AND and each word narrows the result the way a search box
/// should. Quotes in the query are escaped so they cannot close the string
/// and inject further criteria.
String buildSearchCriteria(String query) {
  final words = query
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'ALL';
  return [
    'CHARSET UTF-8',
    for (final word in words)
      // OR takes exactly two arguments, so three fields nest as
      // OR OR <a> <b> <c>.
      'OR OR SUBJECT ${_quote(word)} FROM ${_quote(word)} BODY ${_quote(word)}',
  ].join(' ');
}

String _quote(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// The first line or so of a body, for the message list.
///
/// Marketing mail's text part is often its HTML with the tags pulled out,
/// entities and all: a row of "&zwnj;" spacers, "&nbsp;" between words.
/// Those are decoded, and the characters that are there to be invisible
/// (zero-width joiners and spaces, byte-order marks) are dropped, so what
/// is left is what a person would call the first line.
String previewFromText(String text, {int maxLength = 140}) {
  final flat = _decodeEntities(text)
      .replaceAll(RegExp('[​-‍⁠﻿]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return flat.length <= maxLength
      ? flat
      : '${flat.substring(0, maxLength).trimRight()}…';
}

const _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'zwnj': '‌',
  'zwj': '‍',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
};

String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(
    RegExp(r'&(#x([0-9a-fA-F]{1,6})|#([0-9]{1,7})|([a-zA-Z]{2,8}));'),
    (m) {
      if (m[2] != null) return _char(int.parse(m[2]!, radix: 16));
      if (m[3] != null) return _char(int.parse(m[3]!));
      return _namedEntities[m[4]!.toLowerCase()] ?? m[0]!;
    },
  );
}

String _char(int code) =>
    code > 0 && code <= 0x10FFFF ? String.fromCharCode(code) : '';
