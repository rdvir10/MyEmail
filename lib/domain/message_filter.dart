import 'mail_message.dart';

/// What a list shows of its folder: everything, or one kind of message.
///
/// Outlook's All / Unread switch over the list, and its Filter menu beside
/// it. A filter narrows the folder on the server as well as on the device
/// (see `MailEngine.filterMessages`), so flagged mail from last spring is
/// found as surely as this morning's.
enum MessageFilter {
  all('All', ''),
  unread('Unread', 'No unread messages'),
  flagged('Flagged', 'No flagged messages'),
  attachments('Has attachments', 'No messages with attachments'),
  toMe('To me', 'Nothing sent to you directly');

  const MessageFilter(this.label, this.empty);

  /// What the filter is called on its button.
  final String label;

  /// What an empty list says while the filter is on.
  final String empty;

  /// Whether [message] is one this filter keeps. [ownAddresses] are the
  /// accounts' addresses in lower case, for [toMe]: on the To line, not
  /// only copied, as Outlook's To Me has it.
  bool matches(MailMessage message, Set<String> ownAddresses) =>
      switch (this) {
        all => true,
        unread => !message.isRead,
        flagged => message.isFlagged,
        attachments => message.hasAttachments,
        toMe => message.to
            .any((a) => ownAddresses.contains(a.email.trim().toLowerCase())),
      };
}
