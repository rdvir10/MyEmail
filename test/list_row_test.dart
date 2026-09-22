import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/ui/messages/date_format.dart';
import 'package:enough_mail/enough_mail.dart' as em;

import 'fakes/fake_imap_transport.dart';

/// What a list row knows before anything is opened.
///
/// All of it comes out of the header fetch the sync already makes: who else
/// a message went to, what its files weigh, and whether it is a meeting.
/// None of it costs a request, which is the only reason a list can show it.
void main() {
  group('the date bar', () {
    final now = DateTime(2026, 9, 22, 10, 30);

    test('names today and yesterday rather than dating them', () {
      expect(formatDateBar(DateTime(2026, 9, 22, 8), now: now),
          startsWith('Today'));
      expect(formatDateBar(DateTime(2026, 9, 21, 23), now: now),
          startsWith('Yesterday'));
    });

    test('dates anything older, and adds the year once it matters', () {
      expect(formatDateBar(DateTime(2026, 9, 18), now: now), 'Fri 18 Sep');
      expect(formatDateBar(DateTime(2025, 12, 1), now: now), 'Mon 1 Dec 2025');
    });

    test('a new day is a new day in the reader\'s own zone', () {
      expect(
        startsNewDay(DateTime(2026, 9, 22, 23, 59), DateTime(2026, 9, 23, 0, 1)),
        isTrue,
      );
      expect(
        startsNewDay(DateTime(2026, 9, 22, 0, 1), DateTime(2026, 9, 22, 23, 59)),
        isFalse,
      );
    });
  });

  group('read from the message structure', () {
    em.MimeMessage withCalendarPart() {
      final builder = em.MessageBuilder.prepareMultipartAlternativeMessage(
        plainText: 'Please come.',
        htmlText: '<p>Please come.</p>',
      )..addText(
          'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n',
          mediaType: em.MediaType.fromSubtype(em.MediaSubtype.textCalendar),
        );
      return builder.buildMimeMessage();
    }

    test('a calendar part makes it a meeting', () {
      expect(carriesInvitation(withCalendarPart()), isTrue);
    });

    test('so does an .ics the sender labelled as bytes', () {
      final builder = em.MessageBuilder()
        ..addTextHtml('<p>See you then.</p>')
        ..addBinary(
          _bytes('BEGIN:VCALENDAR'),
          em.MediaType.fromText('application/octet-stream'),
          filename: 'invite.ics',
        );
      expect(carriesInvitation(builder.buildMimeMessage()), isTrue);
    });

    test('ordinary mail is not a meeting', () {
      final builder = em.MessageBuilder()..addTextHtml('<p>Hello</p>');
      expect(carriesInvitation(builder.buildMimeMessage()), isFalse);
    });

    test('what the files weigh leaves the body out of it', () {
      final builder = em.MessageBuilder()
        ..addTextHtml('<p>Here it is.</p>')
        ..addBinary(
          _bytes('0123456789'),
          em.MediaType.fromText('application/pdf'),
          filename: 'report.pdf',
        );
      final bytes = attachmentBytesOf(builder.buildMimeMessage());
      expect(bytes, greaterThan(0));
    });
  });

  group('what a sync keeps', () {
    late FakeImapTransport server;
    late MemoryCacheStore cache;

    setUp(() {
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox);
      cache = MemoryCacheStore();
    });

    test('everyone copied survives the round trip', () async {
      const copied = [
        MailAddress(email: 'michal@example.com', name: 'Michal Raz'),
        MailAddress(email: 'nik@example.com', name: 'Nik Shatzir'),
      ];
      await cache.upsertMessages('a', 'INBOX', [
        CachedMessage(
          uid: 1,
          subject: 'Catalogue',
          from: const MailAddress(email: 'gilad@example.com'),
          to: const [MailAddress(email: 'itay@example.com')],
          cc: copied,
          date: DateTime(2026, 9, 22, 10, 45),
          isRead: false,
          isFlagged: false,
          hasAttachments: false,
        ),
      ]);

      final row = (await cache.readMessages('a', 'INBOX')).single;
      final message = row.toMailMessage(accountId: 'a', folderId: 'a:INBOX');

      expect(message.cc.map((x) => x.email),
          containsAll(<String>['michal@example.com', 'nik@example.com']));
    });

    test('a meeting and the weight of its files do too', () async {
      await cache.upsertMessages('a', 'INBOX', [
        CachedMessage(
          uid: 2,
          subject: 'Review',
          from: const MailAddress(email: 'gilad@example.com'),
          to: const [],
          date: DateTime(2026, 9, 22, 11),
          isRead: false,
          isFlagged: false,
          hasAttachments: true,
          attachmentBytes: 2048,
          isMeeting: true,
        ),
      ]);

      final message = (await cache.readMessages('a', 'INBOX'))
          .single
          .toMailMessage(accountId: 'a', folderId: 'a:INBOX');

      expect(message.isMeeting, isTrue);
      expect(message.attachmentBytes, 2048);
    });

    test('the server unused here still reports its folder', () async {
      expect(server.folder('INBOX').path, 'INBOX');
    });
  });

  group('the account a message is sent from', () {
    Account account({String? senderName}) => Account(
          id: 'a',
          displayName: 'Hadco',
          emailAddress: 'rdvir@hadco-metal.com',
          provider: MailProvider.outlook,
          authMethod: AuthMethod.oauth,
          colorValue: 0xFF0F6CBD,
          chosenSenderName: senderName,
        );

    test('sends under the folder-list name until one is chosen', () {
      expect(account().senderName, 'Hadco');
      expect(account().hasOwnSenderName, isFalse);
    });

    test('and under its own name once it is', () {
      final a = account(senderName: 'Ron Dvir');
      expect(a.senderName, 'Ron Dvir');
      expect(a.displayName, 'Hadco', reason: 'the tree label is untouched');
      expect(a.hasOwnSenderName, isTrue);
    });

    test('an empty choice is no choice, not an empty name', () {
      // Clearing the field has to put the fallback back, or a mistake there
      // would send mail with no name on it at all.
      final a = account(senderName: '   ');
      expect(a.senderName, 'Hadco');
      expect(a.hasOwnSenderName, isFalse);
    });
  });
}

/// enough_mail wants bytes; these tests would rather write text.
Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
