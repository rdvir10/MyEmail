import 'package:flutter/foundation.dart';

import '../../domain/folder_role.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../../domain/calendar_invite.dart';

/// The wire-level operations the cache needs from a mail server, for one
/// account, with no enough_mail types in sight.
///
/// [EnoughMailTransport] implements this over a real IMAP connection; the
/// tests implement it with an in-memory server they can mutate between
/// calls. Everything above this line (sync, cache, engine) is therefore
/// testable without a network.
///
/// Paths are in the domain's slash form; the transport converts to the
/// server's delimiter itself.
abstract class ImapTransport {
  /// Selectable folders only; containers such as Gmail's `[Gmail]` are
  /// already filtered out.
  Future<List<RemoteFolder>> listFolders();

  /// SELECT the folder and report its current state.
  Future<FolderStatus> selectFolder(String path);

  /// Headers for sequence numbers [start]..[end] (1-based, inclusive) of the
  /// currently selected folder, as the server orders them (oldest first).
  Future<List<RemoteHeader>> fetchHeadersBySequence(
    String path,
    int start,
    int end,
  );

  /// Headers for `UID fromUid:*`. Note IMAP returns at least the highest
  /// existing UID even when it is below [fromUid]; callers filter.
  ///
  /// [windowStart], here and on [fetchFlags], [existingUids] and
  /// [refreshHeaders], is the date of the oldest message cached for the
  /// folder: how far back the cached window reaches. IMAP has no use for it,
  /// because its UIDs follow arrival order. Graph's numbers do not always —
  /// a message moved in, or older mail paged in, is numbered when it is
  /// first seen — so a scan there that stopped at a number missed messages,
  /// and it stops at this date instead.
  Future<List<RemoteHeader>> fetchHeadersFromUid(
    String path,
    int fromUid, {
    DateTime? windowStart,
  });

  /// Flags for `UID fromUid:toUid`, optionally only those changed since a
  /// MODSEQ (CONDSTORE). Without CONDSTORE the transport ignores
  /// [changedSinceModSeq] and returns everything in range.
  Future<List<RemoteFlags>> fetchFlags(
    String path,
    int fromUid,
    int toUid, {
    int? changedSinceModSeq,
    DateTime? windowStart,
  });

  /// Which UIDs in the range still exist, so deletions made elsewhere can be
  /// mirrored. `UID SEARCH UID fromUid:toUid`.
  Future<Set<int>> existingUids(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  });

  Future<MailBody> fetchBody(String path, int uid);

  /// The whole message as the server holds it, RFC 822 text.
  Future<String> fetchRaw(String path, int uid);

  /// Answer an invitation the way this server prefers, if it has a way:
  /// Graph can accept on the calendar itself and tell the organiser in
  /// one call. True if it did. False means "send the reply as mail",
  /// which every calendar server also reads.
  ///
  /// [iCalUid] is the UID the invitation itself carries, which is how a
  /// calendar server finds the event when the message does not link to it.
  Future<bool> respondToInvite(
    String path,
    int uid,
    InviteResponse response, {
    String? iCalUid,
  });

  /// Read the headers of messages already known, where the server gives
  /// them cheaply, and nothing otherwise.
  ///
  /// This exists for previews. Graph sends `bodyPreview` with every list
  /// row and pages the folder for its flags anyway, so re-reading a range
  /// costs nothing it was not already spending. IMAP has no preview to
  /// give at any price, so it declines and the caller does not ask twice.
  Future<List<RemoteHeader>> refreshHeaders(
    String path,
    int fromUid,
    int toUid, {
    DateTime? windowStart,
  }) async =>
      const [];

  /// Whether [refreshHeaders] is worth calling at all.
  bool get canRefreshHeaders => false;

  /// What is attached to a message, without downloading any of it.
  ///
  /// One cheap request on both transports — a BODYSTRUCTURE over IMAP, a
  /// metadata list over Graph — so opening a message with a slide deck on it
  /// costs no more than opening any other.
  Future<List<MailAttachment>> listAttachments(String path, int uid);

  /// The bytes of one attachment, by the id [listAttachments] gave it.
  Future<Uint8List> fetchAttachment(String path, int uid, String attachmentId);

  /// UIDs in the folder whose subject, sender or body contain [query].
  ///
  /// Server-side: IMAP SEARCH, so it covers mail that was never cached.
  /// Newest first, capped at [limit].
  Future<List<int>> searchUids(String path, String query, {int limit = 100});

  /// Headers for specific UIDs, for turning search hits into rows.
  Future<List<RemoteHeader>> fetchHeadersByUids(String path, List<int> uids);

  Future<void> storeFlag(
    String path, {
    required List<int> uids,
    required MessageFlag flag,
    required bool set,
  });

  /// Apply to every message in the folder (`1:*`).
  Future<void> storeFlagOnAll(
    String path, {
    required MessageFlag flag,
    required bool set,
  });

  /// Move messages to another folder, returning the UIDs they were given
  /// there when the server says (UIDPLUS / MOVE report it; not every server
  /// does, hence nullable).
  ///
  /// Implementations use UID MOVE where the server offers it and fall back to
  /// COPY, +FLAGS \Deleted, EXPUNGE otherwise.
  Future<List<int>?> moveMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  );

  /// Put a sent message into the Sent folder. Gmail does this itself for
  /// mail sent through its SMTP, so the engine only calls this where the
  /// provider does not.
  /// Put a message into [path]. [draft] sets `\Draft`, which is what makes
  /// other clients offer to keep editing it rather than treating it as
  /// received mail.
  Future<void> appendMessage(
    String path,
    String mimeText, {
    bool seen = true,
    bool draft = false,
  });

  Future<void> expunge(String path);

  Future<void> createFolder(String path);
  Future<void> renameFolder(String oldPath, String newPath);
  Future<void> deleteFolder(String path);

  /// Hold the connection open on [path] and return as soon as the server says
  /// something changed there, or [timeout] passes with nothing.
  ///
  /// This is IMAP IDLE, and it is the only part of the transport that costs
  /// anything while it is doing nothing: the socket stays open and the radio
  /// stays warm. Returns true if the server reported a change, false on
  /// timeout, so the caller can tell "nothing happened" from "time to sync".
  ///
  /// A server without IDLE returns false after [timeout] rather than
  /// throwing, which degrades the caller to a slow poll instead of an error.
  ///
  /// [cancel] ends the wait early, returning false. While a wait is running
  /// the connection can be used for nothing else, so a wait that has lost the
  /// race to another account must be ended, not left to run out.
  Future<bool> awaitChanges(
    String path, {
    required Duration timeout,
    Future<void>? cancel,
  });

  Future<void> close();
}

enum MessageFlag { seen, flagged, deleted, answered }

@immutable
class RemoteFolder {
  const RemoteFolder({
    required this.path,
    required this.role,
    this.isServerManaged = false,
    this.unread = 0,
    this.total = 0,
  });

  /// Slash-separated, e.g. `[Gmail]/Sent Mail` or `Work/Invoices`.
  final String path;
  final FolderRole role;

  /// Gmail's Starred and Important: browsable, but not renamable or
  /// deletable even though they are not special-use system folders.
  final bool isServerManaged;
  final int unread;
  final int total;
}

/// What SELECT tells us. [uidValidity] is the whole basis of the cache: if
/// it changes, every cached UID for the folder is meaningless.
@immutable
class FolderStatus {
  const FolderStatus({
    required this.uidValidity,
    required this.exists,
    this.uidNext,
    this.highestModSeq,
  });

  final int uidValidity;
  final int exists;
  final int? uidNext;

  /// Present when the server supports CONDSTORE (Gmail does).
  final int? highestModSeq;
}

@immutable
class RemoteHeader {
  const RemoteHeader({
    required this.uid,
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.isRead,
    required this.isFlagged,
    required this.hasAttachments,
    this.cc = const [],
    this.attachmentBytes = 0,
    this.isMeeting = false,
    this.preview = '',
    this.messageId,
    this.inReplyTo,
  });

  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;

  /// Everyone copied openly. See [MailMessage.cc].
  final List<MailAddress> cc;
  final DateTime date;
  final bool isRead;
  final bool isFlagged;
  final bool hasAttachments;

  /// What the files on it add up to. See [MailMessage.attachmentBytes].
  final int attachmentBytes;

  /// See [MailMessage.isMeeting].
  final bool isMeeting;

  /// The first line or two of the message, for the list row, where the
  /// server will give it with the header.
  ///
  /// Graph sends `bodyPreview` with every list row and it costs nothing
  /// extra. IMAP has no equivalent: a preview there means fetching a body
  /// part per message, so it stays empty until the message is opened and
  /// the body is cached. That is the whole difference between a work
  /// account showing two lines under each subject and a Gmail one showing
  /// them only for mail that has been read.
  final String preview;

  /// This message's own `Message-ID`, and the id of the message it answers.
  ///
  /// Both come out of the ENVELOPE the header fetch already asks for, so
  /// threading costs nothing extra on the wire. Either can be null: plenty of
  /// mail in the wild has no Message-ID at all, which is why grouping falls
  /// back to the subject rather than relying on these.
  final String? messageId;
  final String? inReplyTo;
}

@immutable
class RemoteFlags {
  const RemoteFlags({
    required this.uid,
    required this.isRead,
    required this.isFlagged,
  });

  final int uid;
  final bool isRead;
  final bool isFlagged;
}
