import 'dart:convert';
import 'dart:typed_data';

import '../domain/account_calendars.dart';
import '../domain/account.dart';
import '../domain/error_report.dart';
import '../domain/search_field.dart';
import '../domain/message_filter.dart';

export '../domain/search_field.dart';
export '../domain/message_filter.dart';
export '../domain/unsubscribe.dart';
export '../domain/opened_headers.dart';
export '../domain/recoverable_message.dart';
export '../domain/free_busy.dart';
export '../domain/mail_tip.dart';
export '../domain/calendar_reads.dart' show KeptCalendar;
export '../domain/account_calendars.dart' show CalendarInfo;
export '../domain/calendar_change.dart' show EventChange, EventNotes;
export 'contacts/account_people.dart' show PeopleSearchAccess, PeopleSearchState;
import 'auth/oauth_token.dart';
import 'contacts/account_people.dart' show PeopleSearchAccess;
import 'mailbox_settings/server_settings.dart';
import '../domain/draft.dart';
import '../domain/address_suggestions.dart';
import '../domain/calendar_change.dart';
import '../domain/calendar_event.dart';
import '../domain/calendar_invite.dart';
import '../domain/calendar_meeting.dart';
import '../domain/calendar_reads.dart';
import '../domain/mail_attachment.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import '../domain/meeting.dart';
import '../domain/message_move.dart';
import '../domain/recoverable_message.dart';
import '../domain/free_busy.dart';
import '../domain/mail_tip.dart';
import '../domain/opened_headers.dart';

/// Everything the UI is allowed to know about talking to mail.
///
/// The real implementation (enough_mail over IMAP) arrives in milestone 3. Until
/// then [SampleMailEngine] backs the same interface so the folder tree can be
/// built and previewed in a browser. Keeping this seam is also what the tests
/// run against, so it stays after the browser preview lapses.
///
/// Folder identity: a [MailFolder.id] is `<accountId>:<path>`, so renaming or
/// moving a folder changes its id and the ids of every descendant, exactly as
/// it does on IMAP where the path is the only identity a folder has. Callers
/// holding folder ids (expand state, favourites, selection) remap them via the
/// [FolderRename] returned from [renameFolder] and [moveFolder].
abstract class MailEngine {
  Future<List<Account>> loadAccounts();

  /// Check the credentials against the server, then remember the account and
  /// its secret. Throws [AuthenticationFailed] if the server refuses the
  /// login and [ConnectionFailed] if it cannot be reached.
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  });

  /// Same, for a provider that signs in with OAuth rather than a password.
  ///
  /// Separate from [addAccount] because the two take genuinely different
  /// things: a password is a value that works forever, a token is a pair with
  /// an expiry that has to be refreshed. Folding them into one call would
  /// mean a parameter that is a password sometimes and a serialised token
  /// other times, which is exactly the sort of thing that goes wrong quietly.
  ///
  /// [signedInAs] is the address the sign-in itself named, where the provider
  /// says (Google does, in its ID token). It must be the address the account
  /// is added as: signing in as one mailbox while typing another's address
  /// made an account that showed one mailbox under another's name.
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
    String? signedInAs,
  });

  /// Change the name and colour an account is shown under.
  ///
  /// Local only: neither is anything the mail server knows about, so this
  /// never opens a connection and works offline.
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,

    /// The name on mail sent from this account. Empty clears it, which puts
    /// the account back to sending under its folder-list name.
    String? senderName,
  });

  /// Put the accounts in this order, which is the order the folder list and
  /// every other list of them shows: what dragging an account heading in
  /// the folder list does. Ids that name no account are passed over, and
  /// accounts not named keep their place after the named ones. Local only,
  /// like [updateAccount]. See [accountsInOrder].
  Future<void> reorderAccounts(List<String> accountIds);

  /// Replace the app password an account signs in with, keeping the account.
  ///
  /// The point of this over removing and re-adding: the account id stays the
  /// same, so every cached folder, message and body stays where it is. An app
  /// password that has been revoked is otherwise only fixable by throwing the
  /// mailbox's whole local copy away and downloading it again.
  ///
  /// Proved against the server first. Storing a secret that does not work
  /// would replace a broken sign-in with a differently broken one.
  Future<void> updateAppPassword({
    required String accountId,
    required String secret,
  });

  /// The same, for an account that signs in with OAuth — or one that is
  /// moving to it: an account added with an app password signs in with the
  /// token from here on, keeping everything cached under it.
  ///
  /// [signedInAs] as in [addOAuthAccount]: the sign-in must be for this
  /// account's address.
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
  });

  /// Forget the account and its secret. Local caches for it go too.
  Future<void> removeAccount(String accountId);

  /// Every folder for one account, flat. The tree is derived from parent ids.
  Future<List<MailFolder>> loadFolders(String accountId);

  /// Rename a folder in place. The whole subtree's paths and ids change.
  Future<FolderRename> renameFolder(String folderId, String newName);

  /// Reparent a folder, which on IMAP is a RENAME across the delimiter.
  /// A null [newParentId] moves it to the account root.
  Future<FolderRename> moveFolder(String folderId, String? newParentId);

  Future<void> deleteFolder(String folderId);

  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  });

  Future<void> markAllRead(String folderId);

  /// Permanently remove everything in the folder. Only valid where
  /// `capabilities.canEmpty` is set, which in practice means Trash and Junk.
  Future<void> emptyFolder(String folderId);

  /// Messages in one folder, newest first. [offset] and [limit] page through
  /// it; the list never loads a whole folder at once.
  ///
  /// Talks to the server: new mail, changed flags and deletions are all
  /// taken account of before this answers. Use [cachedMessages] for what is
  /// already known, which is the same list a moment earlier.
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  });

  /// The folder list as it was last seen, with no network at all.
  ///
  /// Empty for an account whose folders have never been listed. Shown while
  /// [loadFolders] runs, because a tree that was right a minute ago beats an
  /// empty screen saying "Select a folder" for the two seconds a work
  /// mailbox takes to list itself.
  Future<List<MailFolder>> cachedFolders(String accountId);

  /// What is already stored for a folder, with no network at all.
  ///
  /// The list is shown from this first and corrected when [loadMessages]
  /// comes back. Mail that is on the screen is mail that was on the screen
  /// a minute ago; making someone watch a spinner while the server is asked
  /// to confirm it is time spent showing nothing.
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  });

  /// One message from the cache, by id, with no network at all.
  ///
  /// Null when it is not cached, which for a message that just arrived and
  /// was announced in a notification it will be. For answering a
  /// notification's buttons, where there is a message id and nothing else.
  Future<MailMessage?> cachedMessage(String messageId);

  /// The body of one message, fetched when it is opened.
  Future<MailBody> loadMessageBody(String messageId);

  /// Everyone the cached mail has been to or from, each address once, with
  /// how often it appeared and how often, and how lately, it was written
  /// to from one of the accounts. For suggesting recipients as they are
  /// typed. The whole cache: see `CacheStore.addressHistory`.
  Future<List<AddressSuggestion>> recentAddresses();

  /// Everyone the accounts' own address books online find for [query]:
  /// Microsoft's people and directory, Google's contacts. Only accounts
  /// that have allowed it; empty, never an error, when none has or none
  /// answers. See `AccountPeople`.
  Future<List<AddressSuggestion>> searchPeople(String query);

  /// Ready the online address books for [searchPeople]; called when a
  /// recipient field is first used. Never throws.
  Future<void> warmPeopleSearch();

  /// Whether [accountId]'s address book can be searched online, asked now.
  Future<PeopleSearchAccess> peopleSearchAccess(String accountId);

  /// What is attached to a message. Cheap: no file is downloaded.
  Future<List<MailAttachment>> listAttachments(String messageId);

  /// The bytes of one attachment, by the id [listAttachments] gave it.
  Future<Uint8List> fetchAttachment(String messageId, String attachmentId);

  /// What a message's headers say beyond its list row, read on the server
  /// when it is opened: how its mailing list says to leave it, and whether
  /// a read receipt was asked for. See [OpenedHeaders]. Throws as
  /// [listAttachments] does when the server cannot be asked.
  Future<OpenedHeaders> openedHeaders(String messageId);

  /// [names] of [messageId]'s headers as the server has them, by name in
  /// lower case, the first of each: for Check for threats, which reads the
  /// receiving server's sender checks and spam verdicts. A header the
  /// message lacks is left out. Throws as [openedHeaders] does.
  Future<Map<String, String>> messageHeaders(
    String messageId,
    List<String> names,
  );

  /// Whether the app answers read-receipt requests on [accountId]: a Gmail
  /// account, where nothing else does. Not a Microsoft one for now: whether
  /// Exchange sends a receipt itself when the app marks a message read is
  /// not yet known, and answering there too could send two.
  bool answersReadReceipts(String accountId);

  /// Send the read receipt [messageId]'s sender asked for (RFC 8098), from
  /// the account it came to, and mark the request answered on the server
  /// where it keeps such a mark (IMAP's `$MDNSent`). Throws as [sendDraft]
  /// does.
  Future<void> sendReadReceipt(String messageId);

  /// Mark [messageId]'s receipt request answered without sending one, so
  /// other mail apps do not ask again. Best-effort: never throws.
  Future<void> declineReadReceipt(String messageId);

  /// The message as it arrived: RFC 822 text, headers and all. For saving
  /// as an `.eml`, or attaching one message to another.
  ///
  /// One character per byte, the way the wire has it. Back to bytes with
  /// [rawMessageBytes], never with UTF-8: that turned every byte of a
  /// message sent in 8-bit, Hebrew from Thunderbird say, into two, and the
  /// `.eml` arrived garbled.
  Future<String> rawMessage(String messageId);

  /// Answer the invitation in a message: on the calendar where the server
  /// has one (Microsoft), and as the mail reply every calendar server
  /// reads otherwise, sent from the account the invitation came to.
  ///
  /// [note] goes to the organiser with it, as Outlook's Edit the Response
  /// before Sending. [send] false answers without telling them: on the
  /// calendar on Microsoft, and nothing at all over mail. [proposal] is a
  /// new time, with a tentative or declined answer; only where
  /// [canProposeNewTime].
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  });

  /// Whether an invitation to [accountId] can be answered with a new time:
  /// a Microsoft account. Google Calendar ignores a time proposed by mail.
  bool canProposeNewTime(String accountId);

  /// What Exchange says about each of [emails] before a message from
  /// [accountId] goes to them: see [MailTip]. A Microsoft account only;
  /// empty for any other, and where it could not be asked.
  Future<List<MailTip>> mailTips(String accountId, List<String> emails);

  /// [accountId]'s settings on its server: its automatic replies, and the
  /// rules the server runs on its mail. Null for an account signed in with
  /// an app password, which reaches mail and nothing else, and for a shared
  /// mailbox, whose settings are its owner's to change.
  ServerSettings? serverSettings(String accountId);

  /// Add the shared mailbox at [emailAddress] as an account of its own,
  /// reached through [viaAccountId]'s sign-in: a Microsoft account that has
  /// been given access to it. Its folders are read first, and nothing is
  /// kept if they cannot be. Throws `SignInNeedsConsent` while that
  /// account has not allowed the app into mailboxes shared with it, and
  /// [AuthenticationFailed] when the mailbox does not let it in.
  Future<Account> addSharedMailbox({
    required String viaAccountId,
    required String emailAddress,
    required String displayName,
  });

  /// Every event on [accountId]'s calendars between [start] and [end],
  /// each occurrence on its own: the calendar view's. Its main calendar and
  /// each of [calendarsOf] beside it; one of those that cannot be read just
  /// now gives what was kept of it. Throws `SignInNeedsConsent` while the
  /// account has not allowed its calendar, and [CalendarUnavailable] for
  /// one that cannot have one here.
  ///
  /// What it finds is kept on the device, for [keptCalendarEvents].
  Future<List<CalendarEvent>> calendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  );

  /// What [calendarEvents] last found for [accountId] between [start] and
  /// [end], with no network at all, and when that stretch was read: null
  /// where some of it never was. Shown while [calendarEvents] asks again,
  /// as [cachedMessages] is while [loadMessages] does.
  Future<KeptCalendar> keptCalendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  );

  /// [accountId]'s calendars as its server lists them now: the main one,
  /// and each made or followed beside it, Outlook's My Calendars and
  /// Google's calendar list. Kept, for [keptCalendarsOf]. Throws as
  /// [calendarEvents] does, and `SignInNeedsConsent` for a Google account
  /// signed in before the app asked to list them.
  Future<List<CalendarInfo>> calendarsOf(String accountId);

  /// What [calendarsOf] last found for [accountId], with no network: the
  /// main calendar alone where its calendars were never listed.
  Future<List<CalendarInfo>> keptCalendarsOf(String accountId);

  /// Answer [event], a meeting someone else organised, on its account's
  /// calendar, as Outlook answers one there: with [note], without a word
  /// to the organiser where [send] is false, and with a new time
  /// ([proposal], Microsoft only, see [canProposeNewTime]). [wholeSeries]
  /// answers every meeting of the series it is one of.
  ///
  /// Throws [CalendarUnavailable] for an account whose calendar the app
  /// cannot reach, `SignInNeedsConsent` where the calendar is not allowed
  /// yet, [EventGone] for a meeting no longer there, [CalendarRefused] for
  /// what the calendar will not do, and as [sendDraft] does otherwise.
  Future<void> respondToEvent(
    CalendarEvent event,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
    bool wholeSeries = false,
  });

  /// [event]'s notes in full, for changing them, with what goes back under
  /// new notes unchanged (a Teams meeting's block). Throws as
  /// [respondToEvent] does.
  Future<EventNotes> eventNotes(CalendarEvent event, {bool wholeSeries = false});

  /// Change [event], the account's own (organised by it, or with nobody
  /// else on it), as [change] says: the calendar tells everyone on it. For
  /// [wholeSeries], every meeting of its series, which keep their days.
  /// Refused with an [ArgumentError] for someone else's meeting. Throws as
  /// [respondToEvent] does.
  Future<void> updateEvent(
    CalendarEvent event,
    EventChange change, {
    bool wholeSeries = false,
  });

  /// Cancel [event], the account's own: everyone on it is sent the
  /// cancellation, with [note] where the calendar sends one (Microsoft's
  /// does). One with nobody else on it is deleted. Throws as
  /// [respondToEvent] does.
  Future<void> cancelEvent(
    CalendarEvent event, {
    String note = '',
    bool wholeSeries = false,
  });

  /// Take [event] off its calendar: someone else's meeting declined first,
  /// so its organiser knows, and the account's own only where nobody else
  /// is on it (otherwise it is [cancelEvent]'s, and this refuses it with an
  /// [ArgumentError]). Throws as [respondToEvent] does.
  Future<void> removeEvent(CalendarEvent event, {bool wholeSeries = false});

  /// Forward [event] to [to], with [note]: Microsoft sends them the
  /// invitation and, for someone else's meeting, tells its organiser.
  /// Google has no forward and refuses it with [CalendarRefused]. Throws as
  /// [respondToEvent] does.
  Future<void> forwardEvent(
    CalendarEvent event,
    List<MailAddress> to, {
    String note = '',
  });

  /// When [accountId]'s own calendar is busy between [start] and [end].
  /// Throws as [meetingOnCalendar] does.
  Future<List<TimeSpan>> busyTimes(
    String accountId,
    DateTime start,
    DateTime end,
  );

  /// When each of [emails] is busy between [start] and [end], as far as
  /// [accountId]'s calendar can see, by address in lower case: null for one
  /// it cannot. Throws as [meetingOnCalendar] does.
  Future<Map<String, List<TimeSpan>?>> schedules(
    String accountId,
    List<String> emails,
    DateTime start,
    DateTime end,
  );

  /// The meeting [invite] is about, as the account's own calendar has it
  /// now, or null where it is not on it: removed, or never put there. What
  /// the card under an update, a cancellation or a new time proposed is
  /// checked against, read again each time the message is opened.
  ///
  /// Found the way the account's calendar allows: through the message's own
  /// link to it on Microsoft, then by the invitation's UID, and for one
  /// meeting of a series, by when it was set for in the series.
  ///
  /// Throws [CalendarUnavailable] for an account whose calendar the app
  /// cannot reach, `SignInNeedsConsent` for a Microsoft account that has
  /// not allowed the app its calendar, and [AuthenticationFailed] or
  /// [ConnectionFailed] as [sendDraft] does.
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  );

  /// Take [meeting] off its calendar, as Outlook's Remove from Calendar
  /// does: one its organiser has cancelled. Nobody is told; the organiser
  /// already knows. One gone already is done, not a failure.
  ///
  /// Refused with an [ArgumentError] for a meeting the account organised,
  /// where deleting it would cancel it for everyone. Throws as
  /// [meetingOnCalendar] does.
  Future<void> removeFromCalendar(CalendarMeeting meeting);

  /// Move [meeting], which the account organised, to the time [proposal]
  /// proposes, as Outlook's Accept Proposal does: the calendar sends
  /// everyone invited the new time.
  ///
  /// Refused with an [ArgumentError] for a meeting someone else organised,
  /// or a whole series. Throws as [meetingOnCalendar] does.
  Future<void> moveMeeting(CalendarMeeting meeting, CalendarInvite proposal);

  /// Put the meeting on the account's own calendar with everyone in it
  /// invited. The server sends the invitations and keeps the answers on the
  /// event, so they show in every client the account has.
  ///
  /// Throws [CalendarUnavailable] for an account whose calendar the app
  /// cannot reach, `SignInNeedsConsent` for a Microsoft account that has
  /// not allowed the app its calendar, [MeetLinkNeedsConsent] for a Google
  /// Meet link the Gmail account has not yet allowed the app to make, and
  /// [AuthenticationFailed] or [ConnectionFailed] as [sendDraft] does. What
  /// comes back names the event, and where to join it when it was held
  /// online.
  ///
  /// A meeting that carries [MeetingDraft.prepared] is sent with that
  /// online meeting, the one whose text the screen showed. Where it has
  /// gone meanwhile, or the calendar lost the Teams meeting from it, a new
  /// one is made as though none had been prepared: the invitation still
  /// goes, with a link.
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting);

  /// Make [meeting]'s online meeting now, before anyone is invited, so the
  /// screen can show the text the invitation will carry. For Teams and a
  /// Gmail account's Meet it is an event on the account's calendar with
  /// nobody on it; nothing is sent to anyone. [MeetingDraft.online] says
  /// which kind; the attendees and notes are not used, and no title is
  /// needed yet.
  ///
  /// Null where the calendar made none ahead of time (it would not hold
  /// the meeting online after all): Send then asks for one as it always
  /// did. Throws as [createMeeting] does.
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting);

  /// Undo [prepareOnlineMeeting] for a meeting that was not sent: the event
  /// is deleted, silently, provided nobody is on it. Never throws. True
  /// when there is nothing more to do (deleted, gone already, sent after
  /// all, or nothing to delete); false when it could not be done now, no
  /// connection or no sign-in, and is worth trying again later.
  Future<bool> discardPreparedMeeting(PreparedMeeting prepared);

  /// The kinds of online meeting a meeting from this account can be held
  /// as, the account's own calendar's first: Teams on a Microsoft account,
  /// Google Meet on a Gmail account signed in with Google. Google Meet
  /// follows on a Microsoft account too while a Gmail account signed in
  /// with Google is in the app: that account makes the link, and the
  /// Outlook invitation carries it. Empty where there is none, and the
  /// screen shows no switch. A Microsoft calendar is asked once and
  /// remembered; one that could not be asked (no consent yet, no
  /// connection) holds none for now, said in the log and never thrown, and
  /// is asked again next time.
  Future<List<OnlineMeetingKind>> onlineMeetingsFor(String accountId);

  /// Set or clear \Seen. The folder's unread count follows on next load.
  Future<void> setRead(String messageId, bool isRead);

  /// Set or clear \Flagged.
  Future<void> setFlagged(String messageId, bool isFlagged);

  /// [setRead] on several messages at once, as a selection is marked. Each
  /// folder's go together: one STORE over IMAP, twenty to a request on a
  /// Microsoft account. One at a time, sixty marked on a Microsoft account
  /// were sixty requests end to end.
  ///
  /// Every folder is tried whatever happened to the one before. Where none
  /// changed, the first failure is thrown as it came; where only some did,
  /// a [PartialFlagChange] names the rest.
  Future<void> setMessagesRead(List<String> messageIds, bool isRead);

  /// [setFlagged] on several messages at once, the way [setMessagesRead]
  /// marks them.
  Future<void> setMessagesFlagged(List<String> messageIds, bool isFlagged);

  /// Outlook's Follow Up on [messageIds]: flagged, due on [due] (no date
  /// where it is null), or with [complete] marked complete. A Microsoft
  /// account keeps the day and the check on the server, where Outlook
  /// shows them; anywhere else this is the flag alone, the day being kept
  /// on this device. Fails as [setMessagesFlagged] does.
  Future<void> setFollowUp(
    List<String> messageIds, {
    DateTime? due,
    bool complete = false,
  });

  /// Move messages into [toFolderId], from any account. Within one account
  /// the server moves them. Into another, which no server does, each is
  /// copied there as it is and then deleted here, into Trash: see
  /// [MessageMove.originals].
  ///
  /// Answers with what moved where, one entry per source folder, so the
  /// caller can offer to put it back. See [MessageMove] for why the ids in
  /// it are not the ids that went in.
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  );

  /// Delete messages the way the provider expects: into Trash from anywhere
  /// else, and permanently when already in Trash.
  ///
  /// Answers the same way [moveMessages] does. A delete that was permanent
  /// has nothing to put back and says so with an empty entry.
  Future<List<MessageMove>> deleteMessages(List<String> messageIds);

  /// Put back what [moveMessages] or [deleteMessages] reported.
  ///
  /// Uses the ids the server gave where it gave any. Where it did not, the
  /// destination is synced and searched for the `Message-ID` of each message
  /// instead, which is slower but works against a server that moves mail
  /// without saying where it put it.
  Future<void> undoMoves(List<MessageMove> moves);

  /// Whether [accountId] keeps mail emptied out of Deleted Items where it
  /// can be got back: a Microsoft account, signed in. Gmail keeps deleted
  /// mail in sight, in Trash, for thirty days, and has nothing more.
  bool canRecoverDeleted(String accountId);

  /// Recover Deleted Items: mail emptied out of [accountId]'s Deleted
  /// Items, newest received first, [limit] from [offset]; with a [query],
  /// what the server's search finds among it instead. Throws
  /// [FolderOperationNotSupported] for an account without it (see
  /// [canRecoverDeleted]), and as [loadMessages] does otherwise.
  Future<List<RecoverableMessage>> recoverableMessages(
    String accountId, {
    String query = '',
    int offset = 0,
    int limit = 50,
  });

  /// Put [ids], from [recoverableMessages], back in [accountId]'s Inbox.
  /// Answers how many went back.
  Future<int> recoverMessages(String accountId, List<String> ids);

  /// Snooze: [messageIds] out of sight until [until], waiting in a Snoozed
  /// folder on the server (made the first time), and back in the folder
  /// each came from, unread, once [wakeSnoozed] finds the time has come.
  /// Answers the moves, for Undo. A message with no Message-ID could not be
  /// found again, and is left where it is.
  Future<List<MessageMove>> snooze(List<String> messageIds, DateTime until);

  /// Every snoozed message whose time has come back where it was, unread,
  /// and how many came back. Never throws: one that cannot go back yet is
  /// tried again next time, and one no longer where it waited (moved from
  /// there by hand) is let go.
  Future<int> wakeSnoozed({DateTime? now});

  /// When the next snoozed message is due back, or null for none.
  Future<DateTime?> nextSnoozeWake();

  /// Everything flagged in [accountId], whatever folder it is in, newest
  /// first, as the server has it: Outlook's Flagged email. A Microsoft
  /// account's carry the day each is due. Junk and Deleted Items are left
  /// out, as Outlook leaves them out.
  Future<List<MailMessage>> flaggedMessages(String accountId, {int limit = 100});

  /// The same from what is on this device, with no network.
  Future<List<MailMessage>> cachedFlagged(String accountId, {int limit = 100});

  /// Search the server for [query] within [scope], newest first, looking
  /// in [field]: subject, sender and body together unless one is named.
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  });

  /// The newest [limit] messages in [folderId] that [filter] keeps, asked of
  /// the server, newest first: what a filtered list adds to the matching
  /// mail it already holds, so mail never cached is found too. Empty for
  /// [MessageFilter.all].
  Future<List<MailMessage>> filterMessages(
    String folderId,
    MessageFilter filter, {
    int limit = 100,
  });

  /// Send the draft (over SMTP for Gmail, through Graph for Microsoft), see
  /// that Sent has a copy, and mark what it replied to or forwarded, the
  /// messages it carries as attachments included. A mark that cannot be made
  /// is logged, never thrown: the message has gone either way.
  ///
  /// Throws [SendFailed] when the server refuses, [AuthenticationFailed] when
  /// it refuses the login, and [ConnectionFailed] when it cannot be reached.
  Future<void> sendDraft(Draft draft);

  /// Put [draft] in the Drafts folder, replacing the copy it was opened from.
  ///
  /// Server-side rather than local, so the half-written message is on the
  /// phone, on the web and in every other client, which is the only version
  /// of this feature worth having. Returns the new message id, or null where
  /// the draft was saved but where it landed is not known. Throws
  /// [SendFailed] where the account has no Drafts folder to put it in.
  Future<String?> saveDraft(Draft draft);

  /// Remove a copy [saveDraft] put in Drafts, for good rather than into
  /// Trash: it was only ever a safety copy. Best-effort.
  Future<void> discardDraft(String savedAs);
}

/// Where a search looks.
///
/// [folder] is one folder; [account] is every folder of one account;
/// [everywhere] is every account. Folders that only duplicate mail (Gmail's
/// All Mail) or hold none of the user's own (Spam, Trash) are skipped in the
/// wider scopes, or every hit would appear two or three times.
class SearchScope {
  const SearchScope.folder(String this.folderId)
      : accountId = null,
        isEverywhere = false;

  const SearchScope.account(String this.accountId)
      : folderId = null,
        isEverywhere = false;

  const SearchScope.everywhere()
      : folderId = null,
        accountId = null,
        isEverywhere = true;

  final String? folderId;
  final String? accountId;
  final bool isEverywhere;

  @override
  bool operator ==(Object other) =>
      other is SearchScope &&
      other.folderId == folderId &&
      other.accountId == accountId &&
      other.isEverywhere == isEverywhere;

  @override
  int get hashCode => Object.hash(folderId, accountId, isEverywhere);
}

/// The outcome of a rename or move: the folder as it now is, plus the id
/// prefix change that applies to it and every descendant.
class FolderRename {
  const FolderRename({
    required this.folder,
    required this.oldId,
    required this.newId,
  });

  final MailFolder folder;
  final String oldId;
  final String newId;

  /// Translate an id that may point at the renamed folder or something under
  /// it. Ids elsewhere in the tree come back unchanged.
  String remap(String id) {
    if (id == oldId) return newId;
    if (id.startsWith('$oldId/')) return newId + id.substring(oldId.length);
    return id;
  }
}

/// Raised when the UI asks for something the provider will not allow. Reaching
/// this means a capability check was missed upstream, so it is a bug rather
/// than a condition to show the user.
class FolderOperationNotSupported implements Exception {
  const FolderOperationNotSupported(this.folderId, this.operation);

  final String folderId;
  final String operation;

  @override
  String toString() =>
      'FolderOperationNotSupported: cannot $operation on $folderId';
}

/// The server refused the credentials. Shown to the user as-is.
class AuthenticationFailed implements Exception, NeedsSignIn, ReadableError {
  const AuthenticationFailed(this.message);

  /// Always false: a refused password or token is something the person can
  /// replace themselves. The one case that needs an administrator comes from
  /// Microsoft's consent rules and has its own type.
  @override
  bool get needsAdministrator => false;

  @override
  final String message;

  @override
  String toString() => message;
}

/// The server could not be reached at all: no network, wrong host, TLS.
class ConnectionFailed implements Exception, Retryable, ReadableError {
  const ConnectionFailed(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// A read or flagged change on several messages that reached some of them:
/// the ones in [failed] are as they were, because of [cause], and every
/// other one asked for is as asked. Thrown as the cause alone, a selection
/// whose change had mostly gone was put back on screen whole, and said to
/// have failed for all of it.
class PartialFlagChange implements Exception, ReadableError {
  const PartialFlagChange({required this.failed, required this.cause});

  final List<String> failed;
  final Object cause;

  @override
  String get message =>
      cause is ReadableError ? (cause as ReadableError).message : '$cause';

  @override
  String toString() => message;
}

/// A meeting made ahead of Send ([PreparedMeeting]) that can no longer be
/// sent as it is: deleted meanwhile, or its calendar dropped the Teams
/// meeting from it. The calendars' own to catch: they make a new one in
/// its place, and the screen never sees this.
class PreparedMeetingLost implements Exception {
  const PreparedMeetingLost(this.why);

  final String why;

  @override
  String toString() => 'PreparedMeetingLost: $why';
}

/// Making an online meeting ahead of Send failed after the calendar had
/// made its event, and the event could not be deleted again: [leftover]
/// names it, so it can be put on the ledger for the next start to delete.
/// [cause] is what went wrong.
class PreparedMeetingLeft implements Exception {
  const PreparedMeetingLeft(this.leftover, this.cause);

  final PreparedMeeting leftover;
  final Object cause;

  @override
  String toString() => '$cause';
}

/// The account has no calendar the app can reach: a Gmail account with an
/// app password, which covers its mail and nothing else. Not a failure of
/// anything, and shown as one only when there is nowhere else to go: it is
/// the screen's cue to hand the meeting to the phone's calendar app, which
/// has the account's calendar if anything on the phone does.
class CalendarUnavailable implements Exception, ReadableError {
  const CalendarUnavailable(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// A calendar would not do what was asked of a meeting, for a reason a
/// person can read: Google has no way to forward an invitation, say, or
/// the meeting does not list the account among those invited.
class CalendarRefused implements Exception, ReadableError {
  const CalendarRefused(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// The meeting a change was for is no longer on its calendar: deleted or
/// cancelled elsewhere since the calendar was read.
class EventGone implements Exception, ReadableError {
  const EventGone();

  @override
  String get message =>
      'This meeting is no longer on the calendar: it was deleted or '
      'cancelled somewhere else.';

  @override
  String toString() => message;
}

/// A Google Meet link was asked for on another account's calendar, and the
/// Gmail account that would make it has not allowed the app to: its sign-in
/// is from before the app asked for Meet. Names that account, which is not
/// the meeting's, so the screen offers the right sign-in.
class MeetLinkNeedsConsent implements Exception, ReadableError {
  const MeetLinkNeedsConsent({
    required this.accountId,
    required this.emailAddress,
    required this.message,
  });

  /// The Gmail account to sign in again.
  final String accountId;
  final String emailAddress;

  @override
  final String message;

  @override
  String toString() => message;
}

/// A create or rename would collide with an existing sibling. Unlike
/// [FolderOperationNotSupported] this is a normal user-facing condition: the
/// UI shows it and asks for a different name.
class FolderNameConflict implements Exception {
  const FolderNameConflict(this.accountId, this.path);

  final String accountId;
  final String path;

  @override
  String toString() => 'FolderNameConflict: "$path" already exists';
}

/// [MailEngine.rawMessage]'s text as the bytes it stands for.
///
/// A character past 0xFF means the text was never one character per byte,
/// written out by the app itself say, and then it is UTF-8.
Uint8List rawMessageBytes(String raw) {
  for (final unit in raw.codeUnits) {
    if (unit > 0xFF) return Uint8List.fromList(utf8.encode(raw));
  }
  return Uint8List.fromList(latin1.encode(raw));
}
