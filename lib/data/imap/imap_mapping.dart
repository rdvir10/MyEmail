import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/search_field.dart';
import '../../domain/message_filter.dart';
import '../../domain/account.dart';
import '../../domain/folder_capabilities.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../compose/mime_parts.dart' show bareContentId;
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
/// the set of paths that exist.
///
/// System folders stay at the root wherever the server puts them, so
/// `[Gmail]/Sent Mail` sits beside the Inbox. A user folder keeps its
/// nesting when its parent is itself a folder.
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

/// The transport's view of a fetched header. Needs UID, FLAGS, ENVELOPE,
/// BODYSTRUCTURE and INTERNALDATE in the fetch.
RemoteHeader remoteHeaderFromMime(em.MimeMessage m, {DateTime? fallbackDate}) {
  final uid = m.uid;
  if (uid == null) {
    throw ArgumentError('Message has no UID; fetch with UID in the criteria');
  }
  final arrived = parseInternalDate(m.internalDate);
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
    // With no Date header it could read, the time the server took it in,
    // which is close and never changes. The time of the sync was neither:
    // an old message sorted as new, and its date moved at every refill.
    date: m.decodeDate() ?? arrived ?? fallbackDate ?? DateTime.now(),
    arrived: arrived,
    isRead: m.isSeen,
    isFlagged: m.isFlagged,
    isAnswered: m.isAnswered,
    isForwarded: markedForwarded(m),
    hasAttachments: m.hasAttachments(),
    attachmentNames: attachmentNamesOf(m),
    sizeBytes: m.size ?? 0,
    isMeeting: carriesInvitation(m),
    messageId: normaliseMessageId(
      m.envelope?.messageId ?? m.getHeaderValue('message-id'),
    ),
    inReplyTo: normaliseMessageId(
      m.envelope?.inReplyTo ?? m.getHeaderValue('in-reply-to'),
    ),
  );
}

/// Whether the message's FLAGS carry `$Forwarded`.
///
/// Compared without regard to case, where enough_mail's own getter matches
/// it exactly. It is a keyword, set by whichever mail app did the
/// forwarding, and a server can hand a keyword back in another case than the
/// one it was set in.
bool markedForwarded(em.MimeMessage m) {
  const wanted = r'$forwarded';
  return m.flags?.any((f) => f.toLowerCase() == wanted) ?? false;
}

/// IMAP's INTERNALDATE, `17-Jul-1996 02:44:25 -0700`, or null where it is
/// missing or not in that form.
///
/// Not the Date header's format, so not something enough_mail's date
/// decoder reads: the parts are joined by hyphens, and the day may be
/// padded with a space.
DateTime? parseInternalDate(String? raw) {
  if (raw == null) return null;
  final match = RegExp(
    r'^\s*(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\s*$',
  ).firstMatch(raw.replaceAll('"', ''));
  if (match == null) return null;
  const months = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];
  final month = months.indexOf(match.group(2)!.toLowerCase()) + 1;
  if (month == 0) return null;
  int at(int group) => int.parse(match.group(group)!);
  final offset = Duration(hours: at(8), minutes: at(9));
  final utc = DateTime.utc(at(3), month, at(1), at(4), at(5), at(6));
  // The time given is local to the zone after it: back to UTC, then to this
  // device's time, as the Date header's decoder gives it.
  return (match.group(7) == '+' ? utc.subtract(offset) : utc.add(offset))
      .toLocal();
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

/// [safePathSegment] undone: the name as the server has it.
///
/// For whatever goes back to the server as a name. Sending the stand-in
/// renamed "AP/AR" to a look-alike that matched nothing on the web, with no
/// way to type the real slash back.
String nameFromPathSegment(String segment) => segment.replaceAll('∕', '/');

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

/// The mailboxes that are folders. Gmail's `[Gmail]` is a container marked
/// \Noselect: it holds folders and cannot be opened itself.
List<em.Mailbox> selectableMailboxes(Iterable<em.Mailbox> boxes) =>
    [for (final b in boxes) if (!b.isNotSelectable) b];

MailAddress addressFromMime(em.MailAddress a) =>
    MailAddress(email: a.email, name: a.personalName);

/// The readable body: the plain-text part if the sender supplied one, else a
/// text rendering of the HTML so the browser preview and any text-only view
/// still show something. The HTML travels alongside for the WebView.
MailBody bodyFromMime(em.MimeMessage m) => _body(
      text: m.decodeTextPlainPart(),
      html: m.decodeTextHtmlPart(),
      calendar: calendarPartOf(m),
    );

MailBody _body({String? text, String? html, String? calendar}) => MailBody(
      text: (text != null && text.trim().isNotEmpty)
          ? text
          : html != null
              ? htmlToText(html)
              : '',
      html: html,
      calendar: calendar,
    );

/// The parts of a message its body is read from, chosen by [bodyPartsOf].
class BodyParts {
  const BodyParts({this.text, this.html, this.calendar = const []});

  final em.BodyPart? text;
  final em.BodyPart? html;

  /// Every part that may be the invitation, in the order they are tried.
  final List<em.BodyPart> calendar;

  /// What each is fetched as, `BODY[n]`, once each.
  List<String> get ids =>
      {for (final p in [?text, ?html, ...calendar]) _partId(p)}.toList();
}

/// The parts of a message [bodyFromParts] reads its body from, found in
/// its BODYSTRUCTURE alone so that nothing else need be fetched: the first
/// plain-text and the first HTML part that are its own, not an attached
/// file or an attached message, and whatever may be its invitation, in the
/// order [calendarPartOf] tries them.
///
/// Null for a message of one part, which is its body and nothing else, so
/// is fetched whole.
BodyParts? bodyPartsOf(em.MimeMessage structure) {
  final body = structure.body;
  if (body == null || (body.parts?.isEmpty ?? true)) return null;

  // Depth first, as enough_mail finds them in a whole message, but past
  // attached files and attached messages: their text is not this one's,
  // and a log file attached to a message of HTML alone would be its text.
  em.BodyPart? own(List<em.BodyPart>? parts, em.MediaSubtype subtype) {
    for (final part in parts ?? const <em.BodyPart>[]) {
      if (part.contentDisposition?.disposition ==
          em.ContentDisposition.attachment) {
        continue;
      }
      final type = part.contentType?.mediaType;
      if (type?.sub == subtype) return part;
      if (type?.isMessage ?? false) continue;
      final inside = own(part.parts, subtype);
      if (inside != null) return inside;
    }
    return null;
  }

  final calendar = <em.BodyPart>[
    ?body.findFirst(em.MediaSubtype.textCalendar),
  ];
  for (final disposition in [
    em.ContentDisposition.attachment,
    em.ContentDisposition.inline,
  ]) {
    for (final info in structure.findContentInfo(disposition: disposition)) {
      final type = info.contentType?.mediaType.toString() ?? '';
      if (!isCalendarFile(type, info.fileName ?? '')) continue;
      final part = body.getChildPart(info.fetchId);
      if (part != null) calendar.add(part);
    }
  }
  return BodyParts(
    text: own(body.parts, em.MediaSubtype.textPlain),
    html: own(body.parts, em.MediaSubtype.textHtml),
    calendar: calendar,
  );
}

/// [bodyFromMime] for a message fetched as its structure and the parts
/// [bodyPartsOf] chose: [fetched] holds them by id, as `BODY[n]` brought
/// them, each decoded here with the encoding and charset its structure
/// gives (see [decodePart]).
MailBody bodyFromParts(BodyParts parts, Map<String, List<int>> fetched) {
  String? read(em.BodyPart? part) {
    if (part == null) return null;
    final raw = fetched[_partId(part)];
    if (raw == null) return null;
    // 8bit, as what is left once the transfer encoding is undone: the
    // bytes of the text in its charset.
    return em.MailCodec.decodeAsText(
      decodePart(raw, part.encoding),
      '8bit',
      part.contentType?.charset,
    );
  }

  String? calendar;
  for (final part in parts.calendar) {
    final text = read(part);
    if (text != null && text.trim().isNotEmpty) {
      calendar = text;
      break;
    }
  }
  return _body(text: read(parts.text), html: read(parts.html), calendar: calendar);
}

/// A part's id as IMAP takes it. enough_mail numbers the parts of a message
/// attached as part 2 `2.TEXT.1` and on, which IMAP calls `2.1`; `TEXT`
/// there means that message's text, not a step on the way to a part.
///
/// Every part but the message itself has an id, and [bodyPartsOf] never
/// chooses the message itself.
String _partId(em.BodyPart part) => part.fetchId!.replaceAll('.TEXT', '');

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
          contentId: bareContentId(info.cid),
        ),
      );
    }
  }
  // A picture the HTML shows is not always marked inline: some senders give
  // it a Content-ID and no disposition at all, and the body finds it by
  // that alone. Such a part is inline, whatever it forgot to say.
  final listed = {for (final a in found) a.id};
  void walk(em.BodyPart part) {
    final id = part.fetchId;
    final type = part.contentType?.mediaType;
    final contentId = bareContentId(part.cid);
    if (id != null &&
        contentId != null &&
        part.contentDisposition == null &&
        type?.top == em.MediaToptype.image &&
        listed.add(id)) {
      final mime = '$type';
      found.add(
        MailAttachment(
          id: id,
          name: safeFileName(
            part.contentType?.parameters['name'] ?? _nameFromType(mime, id),
          ),
          mimeType: mime,
          sizeBytes: part.size ?? 0,
          isInline: true,
          contentId: contentId,
        ),
      );
    }
    for (final child in part.parts ?? const <em.BodyPart>[]) {
      walk(child);
    }
  }

  final body = message.body;
  if (body != null) walk(body);
  return found;
}

/// The files a row names under the message: [attachmentsOf] less what is
/// inline, so the same parts the paperclip stands for, by the same names
/// the message's own list gives them. See [MailMessage.attachmentNames].
List<String> attachmentNamesOf(em.MimeMessage message) => [
      for (final a in attachmentsOf(message))
        if (!a.isInline) a.name,
    ];

/// A part fetched on its own, `BODY[n]`, decoded from the
/// Content-Transfer-Encoding its BODYSTRUCTURE gives ([encoding]).
///
/// Such a part comes without its headers, so nothing in it says how it was
/// encoded, and enough_mail, told nothing, handed it back as it came with
/// every line break taken out: a PDF was its base64 text, a signature logo
/// base64 of base64, an attached email one run-on line that did not parse.
/// Nor does enough_mail turn quoted-printable into bytes at all. Unencoded
/// parts (7bit, 8bit, binary) are already the bytes they stand for.
Uint8List decodePart(List<int> raw, String? encoding) {
  switch (encoding?.trim().toLowerCase()) {
    case 'base64':
      final text = String.fromCharCodes(raw).replaceAll(RegExp(r'\s+'), '');
      return em.MailCodec.base64.decodeData(text);
    case 'quoted-printable':
      return _quotedPrintableBytes(raw);
    default:
      return raw is Uint8List ? raw : Uint8List.fromList(raw);
  }
}

/// RFC 2045's quoted-printable, back to bytes: `=XX` is the byte XX, and an
/// `=` at the end of a line joins it to the next. Anything else, a stray
/// `=` included, is kept as it is rather than failing the whole file.
Uint8List _quotedPrintableBytes(List<int> raw) {
  int hex(int c) => switch (c) {
        >= 0x30 && <= 0x39 => c - 0x30,
        >= 0x41 && <= 0x46 => c - 0x41 + 10,
        >= 0x61 && <= 0x66 => c - 0x61 + 10,
        _ => -1,
      };
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (c != 0x3D) {
      out.addByte(c);
      continue;
    }
    final next = i + 1 < raw.length ? raw[i + 1] : -1;
    if (next == 0x0A) {
      i += 1;
    } else if (next == 0x0D && i + 2 < raw.length && raw[i + 2] == 0x0A) {
      i += 2;
    } else if (i + 2 < raw.length && hex(next) >= 0 && hex(raw[i + 2]) >= 0) {
      out.addByte(hex(next) * 16 + hex(raw[i + 2]));
      i += 2;
    } else {
      out.addByte(c);
    }
  }
  return out.takeBytes();
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
/// search box to do, or only the one [field] names. Words are ANDed, since
/// IMAP's default is to combine criteria with AND and each word narrows the
/// result the way a search box should. Quotes in the query are escaped so
/// they cannot close the string and inject further criteria.
///
/// IMAP has no key for an attachment's name. Gmail, the one IMAP server
/// this app talks to, takes its own search language under `X-GM-RAW`, and
/// `filename:` there is the file's name.
///
/// [unlabelledOnly] narrows it, in that language, to [gmailUnlabelledMail].
String buildSearchCriteria(
  String query, {
  SearchField field = SearchField.all,
  bool unlabelledOnly = false,
}) {
  final words = query
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'ALL';
  return [
    'CHARSET UTF-8',
    for (final word in words)
      switch (field) {
        // OR takes exactly two arguments, so three fields nest as
        // OR OR <a> <b> <c>.
        SearchField.all => 'OR OR ${_term('SUBJECT', word)} '
            '${_term('FROM', word)} ${_term('BODY', word)}',
        SearchField.from => _term('FROM', word),
        SearchField.to => _term('TO', word),
        SearchField.subject => _term('SUBJECT', word),
        SearchField.body => _term('BODY', word),
        SearchField.attachment => _term('X-GM-RAW', 'filename:$word'),
      },
    if (unlabelledOnly) _term('X-GM-RAW', gmailUnlabelledMail),
  ].join(' ');
}

/// IMAP SEARCH criteria for what [filter] keeps of a folder.
///
/// IMAP has no key for "has a file". Gmail, the one IMAP server this app
/// talks to, answers its own `has:attachment` under `X-GM-RAW`. To me is on
/// the To line: [ownAddress] is the account's address.
String buildFilterCriteria(MessageFilter filter, {required String ownAddress}) =>
    switch (filter) {
      MessageFilter.all => 'ALL',
      MessageFilter.unread => 'UNSEEN',
      MessageFilter.flagged => 'FLAGGED',
      MessageFilter.attachments => _term('X-GM-RAW', 'has:attachment'),
      MessageFilter.toMe => _term('TO', ownAddress.trim()),
    };

/// The mail in Gmail's All Mail that no other folder a search looks in
/// holds: out of the Inbox, Sent and Drafts, with no label of Ron's on it.
/// Starred and Important are Gmail's own labels, not his, and are not
/// searched, so what is only under them is still here.
const gmailUnlabelledMail = 'has:nouserlabels -in:inbox -in:sent -in:drafts';

/// One search key and its word.
///
/// A word with anything past ASCII in it goes as a literal, its length in
/// bytes and then the bytes: IMAP allows only 7-bit text between quotes,
/// and Gmail answered a Hebrew or accented word there with BAD. The line
/// break is where enough_mail waits for the server's go-ahead before
/// sending the word, which is how its own search builder does it.
String _term(String key, String word) {
  if (word.codeUnits.every((c) => c < 0x80)) return '$key ${_quote(word)}';
  return '$key {${utf8.encode(word).length}}\n$word';
}

/// A folder path as a command that takes it as text should carry it.
///
/// enough_mail sends such a path as it stands, in quotes, to a server that
/// advertises UTF-8 as Gmail does. But a server holds a client to UTF-8
/// only after ENABLE UTF8=ACCEPT, which the app never sends, so a Hebrew or
/// accented name went to Gmail as raw bytes, and moving mail into that
/// folder, creating it or renaming to it was refused. Here it is put the way
/// every server reads a name, as Modified UTF-7, one part at a time. For a
/// server without UTF-8, enough_mail does that itself.
String imapCommandPath(
  String modelPath,
  String delimiter, {
  required bool serverTakesUtf8,
}) {
  final server = toServerPath(modelPath, delimiter);
  if (!serverTakesUtf8) return server;
  return [
    for (final part in server.split(delimiter))
      em.Mailbox.encode(part, delimiter),
  ].join(delimiter);
}

/// The line of an APPEND that files a message from another account
/// (RFC 3501 6.3.11), up to the literal that carries it: the folder as the
/// server named it in its list, the flags, and the time it arrived, so it
/// is listed where it was rather than at the top as if it came today.
String appendCommand(
  String encodedMailbox, {
  required List<String> flags,
  DateTime? arrived,
  required int length,
}) {
  final line = StringBuffer('APPEND ')..write(_quote(encodedMailbox));
  if (flags.isNotEmpty) line.write(' (${flags.join(' ')})');
  if (arrived != null) line.write(' "${imapDateTime(arrived)}"');
  line.write(' {$length}');
  return line.toString();
}

/// An IMAP date-time, `05-Oct-2026 14:03:09 +0000`, in UTC.
String imapDateTime(DateTime when) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final t = when.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}-${months[t.month - 1]}-${t.year} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)} +0000';
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
