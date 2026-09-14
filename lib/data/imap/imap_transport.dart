import 'package:flutter/foundation.dart';

import '../../domain/folder_role.dart';
import '../../domain/mail_message.dart';

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
  Future<List<RemoteHeader>> fetchHeadersFromUid(String path, int fromUid);

  /// Flags for `UID fromUid:toUid`, optionally only those changed since a
  /// MODSEQ (CONDSTORE). Without CONDSTORE the transport ignores
  /// [changedSinceModSeq] and returns everything in range.
  Future<List<RemoteFlags>> fetchFlags(
    String path,
    int fromUid,
    int toUid, {
    int? changedSinceModSeq,
  });

  /// Which UIDs in the range still exist, so deletions made elsewhere can be
  /// mirrored. `UID SEARCH UID fromUid:toUid`.
  Future<Set<int>> existingUids(String path, int fromUid, int toUid);

  Future<MailBody> fetchBody(String path, int uid);

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

  Future<void> expunge(String path);

  Future<void> createFolder(String path);
  Future<void> renameFolder(String oldPath, String newPath);
  Future<void> deleteFolder(String path);

  Future<void> close();
}

enum MessageFlag { seen, flagged, deleted }

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
  });

  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final DateTime date;
  final bool isRead;
  final bool isFlagged;
  final bool hasAttachments;
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
