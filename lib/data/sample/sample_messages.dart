import 'dart:math';

import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';

/// Deterministic sample messages for one folder.
///
/// Seeded from the folder id so the same folder always shows the same mail,
/// which keeps screenshots and widget tests stable. The counts follow the
/// folder: the first [MailFolder.unreadCount] messages are unread, and no
/// more than [maxPerFolder] are generated, mirroring a real client that pages
/// rather than loading a 9,000-message folder.
List<MailMessage> generateSampleMessages(
  MailFolder folder, {
  DateTime? now,
  int maxPerFolder = 60,
}) {
  final rng = Random(folder.id.hashCode);
  final count = min(folder.totalCount, maxPerFolder);
  final base = now ?? DateTime.now();
  final isOutgoing =
      folder.role == FolderRole.sent || folder.role == FolderRole.drafts;

  var cursor = base.subtract(Duration(minutes: rng.nextInt(90)));
  final messages = <MailMessage>[];
  for (var i = 0; i < count; i++) {
    final sender = _people[rng.nextInt(_people.length)];
    final subject = _subjects[rng.nextInt(_subjects.length)]
        .replaceAll('{n}', (1000 + rng.nextInt(9000)).toString());
    final preview = _previews[rng.nextInt(_previews.length)];
    final uid = folder.totalCount - i;
    messages.add(
      MailMessage(
        id: MailMessage.idFor(folder.id, uid),
        accountId: folder.accountId,
        folderId: folder.id,
        uid: uid,
        subject: subject,
        from: isOutgoing ? _me : sender,
        to: isOutgoing ? [sender] : const [_me],
        date: cursor,
        preview: preview,
        isRead: isOutgoing || i >= folder.unreadCount,
        isFlagged: i % 7 == 3,
        hasAttachments: i % 5 == 1,
      ),
    );
    // Gaps of a few hours, with occasional multi-day silences so the date
    // column exercises "today", "this year" and "older" formats.
    cursor = cursor.subtract(
      Duration(
        hours: 2 + rng.nextInt(6),
        minutes: rng.nextInt(60),
        days: rng.nextInt(9) == 0 ? 1 + rng.nextInt(20) : 0,
      ),
    );
  }
  return messages;
}

/// A body to go with a generated message.
///
/// Two messages in three get an HTML body as well as the plain-text
/// alternative, because real mail is overwhelmingly HTML and sample data that
/// is all plain text never exercises the WebView, its remote-image blocking,
/// or the text fallback. Some of those carry a remote image so that the
/// "Images are blocked" path shows up.
MailBody generateSampleBody(MailMessage message) {
  final rng = Random(message.id.hashCode);
  final paragraphs = [
    for (var i = 0; i < 1 + rng.nextInt(3); i++)
      _paragraphs[rng.nextInt(_paragraphs.length)],
  ];

  final text = StringBuffer('Hi,\n\n${message.preview}\n');
  for (final p in paragraphs) {
    text.write('\n$p\n');
  }
  text.write('\nThanks,\n${message.from.display}');

  if (rng.nextInt(3) == 0) return MailBody(text: text.toString());

  final hasRemoteImage = rng.nextBool();
  final html = StringBuffer()
    ..write('<div style="font-family:sans-serif">')
    ..write('<p>Hi,</p>')
    ..write('<p>${_escape(message.preview)}</p>');
  for (final p in paragraphs) {
    html.write('<p>${_escape(p)}</p>');
  }
  if (hasRemoteImage) {
    // A tracking pixel and a banner, the two things the blocker exists for.
    html
      ..write('<img src="https://tracker.example/open/${message.uid}.gif" '
          'width="1" height="1" alt="">')
      ..write('<p><img src="https://cdn.example/banner-${message.uid}.png" '
          'alt="Banner" width="480"></p>');
  }
  html
    ..write('<blockquote>Sent from the ${_escape(message.from.display)} '
        'mailing system.</blockquote>')
    ..write('<p>Thanks,<br>${_escape(message.from.display)}</p>')
    ..write('<p><a href="https://example.com/unsubscribe">Unsubscribe</a></p>')
    ..write('</div>');

  return MailBody(text: text.toString(), html: html.toString());
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

const _me = MailAddress(email: 'me@example.com', name: 'Me');

const _people = <MailAddress>[
  MailAddress(email: 'dana.levi@example.com', name: 'Dana Levi'),
  MailAddress(email: 'amit.cohen@example.com', name: 'Amit Cohen'),
  MailAddress(email: 'billing@northwind.example', name: 'Northwind Billing'),
  MailAddress(email: 'support@acme.example', name: 'Acme Support'),
  MailAddress(email: 'noa.friedman@example.com', name: 'Noa Friedman'),
  MailAddress(email: 'events@citylibrary.example', name: 'City Library'),
  MailAddress(email: 'legal@globex.example', name: 'Globex Legal'),
  MailAddress(email: 'yael.shapiro@example.com', name: 'Yael Shapiro'),
  MailAddress(email: 'no-reply@parcelrun.example'),
];

const _subjects = <String>[
  'Invoice #{n} is ready',
  'Re: Dinner on Thursday?',
  'Your order #{n} has shipped',
  "Minutes from today's meeting",
  'Photos from the trip',
  'Reminder: appointment tomorrow at 10:30',
  'Q3 numbers, first look',
  'This week in the newsletter',
  'Re: Re: Contract draft v3',
  'Receipt for your payment',
  'Can you take a look at this before Friday?',
  'School trip permission form',
  'Fwd: Flight confirmation {n}',
  'Password changed successfully',
];

const _previews = <String>[
  'Just following up on the message from last week. Let me know if',
  'Attached is the signed copy. The one change is in section 4, where',
  'Your parcel is on its way and should arrive within two working days.',
  'Thanks for sending those over. A couple of small comments inline:',
  'Are we still on for Thursday? I can do 7 or 8, whichever suits.',
  'This is an automated message. Please do not reply to this address.',
  'Here are the photos from Saturday. The ones from the top were the best,',
  'Quick reminder that the form needs to be back by Monday morning.',
  'The numbers look better than expected, mostly on the services side.',
  'We noticed a sign-in from a new device. If this was you, no action is',
];

const _paragraphs = <String>[
  'I went through everything again this morning and I think we are in good '
      'shape. The only open point is timing, which depends on the other side '
      'getting back to us.',
  'If it helps, I can put together a short summary with the options and '
      'what each one would cost. Say the word and I will send it over.',
  'One more thing: the address on the previous version was out of date. '
      'The new one is in the footer below.',
  'Let me know if any of this is unclear. Happy to jump on a quick call, '
      'but email is fine too.',
  'Please keep this message for your records. You can view the details at '
      'any time from your account page.',
];
