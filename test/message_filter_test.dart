import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_filter.dart';
import 'package:myemail/state/list_filter.dart';

/// Outlook's All / Unread and Filter: what each keeps, how the server is
/// asked for the rest, and how the two are put together.
void main() {
  MailMessage m(
    int uid, {
    bool read = true,
    bool flagged = false,
    bool files = false,
    List<MailAddress> to = const [MailAddress(email: 'other@x.com')],
  }) =>
      MailMessage(
        id: 'a:INBOX#$uid',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: 'S$uid',
        preview: '',
        from: const MailAddress(email: 'dana@example.com'),
        to: to,
        date: DateTime(2026, 9, uid),
        isRead: read,
        isFlagged: flagged,
        hasAttachments: files,
      );

  const own = {'ron@hadco.com'};

  group('what each filter keeps', () {
    test('Unread, Flagged and Has attachments', () {
      expect(MessageFilter.unread.matches(m(1, read: false), own), isTrue);
      expect(MessageFilter.unread.matches(m(1), own), isFalse);
      expect(MessageFilter.flagged.matches(m(1, flagged: true), own), isTrue);
      expect(MessageFilter.attachments.matches(m(1, files: true), own), isTrue);
      expect(MessageFilter.all.matches(m(1), own), isTrue);
    });

    test('To me is the To line, not a copy', () {
      final toMe = m(1, to: const [MailAddress(email: 'Ron@Hadco.com')]);
      expect(MessageFilter.toMe.matches(toMe, own), isTrue);
      expect(MessageFilter.toMe.matches(m(2), own), isFalse);
    });
  });

  group('asking the server', () {
    test('Gmail is asked in IMAP SEARCH and its own language', () {
      expect(buildFilterCriteria(MessageFilter.unread, ownAddress: 'x'),
          'UNSEEN');
      expect(buildFilterCriteria(MessageFilter.flagged, ownAddress: 'x'),
          'FLAGGED');
      expect(buildFilterCriteria(MessageFilter.attachments, ownAddress: 'x'),
          'X-GM-RAW "has:attachment"');
      expect(
          buildFilterCriteria(MessageFilter.toMe, ownAddress: 'ron@gmail.com'),
          'TO "ron@gmail.com"');
    });

    Future<Uri> askGraph(MessageFilter filter) async {
      late Uri asked;
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          asked = request.url;
          return http.Response(jsonEncode({'value': []}), 200);
        }),
      );
      await api.filtered('f-inbox', filter, ownAddress: 'ron@hadco.com');
      return asked;
    }

    test('Microsoft is asked with the date first in the filter, sorted by it',
        () async {
      // Graph refuses a sort on a property the filter does not start with.
      final asked = await askGraph(MessageFilter.unread);
      expect(asked.queryParameters[r'$filter'],
          'receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false');
      expect(asked.queryParameters[r'$orderby'], 'receivedDateTime desc');

      final flagged = await askGraph(MessageFilter.flagged);
      expect(flagged.queryParameters[r'$filter'],
          endsWith("flag/flagStatus eq 'flagged'"));
      final files = await askGraph(MessageFilter.attachments);
      expect(files.queryParameters[r'$filter'], endsWith('hasAttachments eq true'));
    });

    test('To me on Microsoft is a search on the To line', () async {
      final asked = await askGraph(MessageFilter.toMe);
      expect(asked.queryParameters[r'$search'], '"to:ron@hadco.com"');
      expect(asked.queryParameters.containsKey(r'$orderby'), isFalse);
    });
  });

  group('putting the list together', () {
    test('the list narrowed, and the server\'s older mail after it', () {
      final shown = filteredMessages(
        [m(5, read: false), m(4)],
        [m(1, read: false)],
        MessageFilter.unread,
        own,
      );
      expect([for (final x in shown) x.uid], [5, 1]);
    });

    test('the list\'s own copy of a message wins over the server\'s', () {
      // Read here a moment ago; the server's answer is from before that.
      final shown = filteredMessages(
        [m(3)],
        [m(3, read: false)],
        MessageFilter.unread,
        own,
      );
      expect(shown, isEmpty);
    });

    test('the message open stays while it is open, read or not', () {
      final shown = filteredMessages(
        [m(3), m(2, read: false)],
        const [],
        MessageFilter.unread,
        own,
        keep: 'a:INBOX#3',
      );
      expect([for (final x in shown) x.uid], [3, 2]);
    });

    test('All is the list as it is', () {
      final list = [m(1), m(2)];
      expect(
        identical(
          filteredMessages(list, [m(9)], MessageFilter.all, own),
          list,
        ),
        isTrue,
      );
    });
  });
}
