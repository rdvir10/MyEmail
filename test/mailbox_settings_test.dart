import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/graph/graph_settings_api.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/mailbox_settings/gmail_settings_api.dart';
import 'package:myemail/data/mailbox_settings/server_settings.dart';
import 'package:myemail/domain/mailbox_settings.dart';

/// Automatic replies (#52) and server rules (#37) on the wire: Graph's
/// mailboxSettings and messageRules, Gmail's vacation and filters.
void main() {
  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  group("Graph's automatic replies", () {
    test('a scheduled setting reads back in local time, as text', () {
      final reply = GraphSettingsApi.autoReplyFrom({
        'status': 'scheduled',
        'externalAudience': 'contactsOnly',
        'scheduledStartDateTime': {
          'dateTime': '2026-11-02T07:00:00.0000000',
          'timeZone': 'UTC',
        },
        'scheduledEndDateTime': {
          'dateTime': '2026-11-06T16:00:00.0000000',
          'timeZone': 'UTC',
        },
        'internalReplyMessage':
            '<html><body><div>Away this week.</div></body></html>',
        'externalReplyMessage': '<p>Back on Monday.</p>',
      });
      expect(reply.on, isTrue);
      expect(reply.start, DateTime.utc(2026, 11, 2, 7).toLocal());
      expect(reply.end, DateTime.utc(2026, 11, 6, 16).toLocal());
      expect(reply.message, 'Away this week.');
      expect(reply.outsideMessage, 'Back on Monday.');
      expect(reply.audience, ReplyAudience.contacts);
    });

    test('off is off, and one message for both reads as one', () {
      final reply = GraphSettingsApi.autoReplyFrom({
        'status': 'disabled',
        'externalAudience': 'none',
        'internalReplyMessage': '<p>Away</p>',
        'externalReplyMessage': '<p>Away</p>',
        'scheduledStartDateTime': {'dateTime': '2026-11-02T07:00:00', 'timeZone': 'UTC'},
        'scheduledEndDateTime': {'dateTime': '2026-11-06T16:00:00', 'timeZone': 'UTC'},
      });
      expect(reply.on, isFalse);
      expect(reply.scheduled, isFalse, reason: 'a schedule left behind');
      expect(reply.outsideMessage, isEmpty);
      expect(reply.audience, ReplyAudience.insideOnly);
    });

    test('what is sent: the status, the times in UTC, both messages', () {
      final start = DateTime(2026, 11, 2, 9);
      final end = DateTime(2026, 11, 6, 18);
      final body = GraphSettingsApi.automaticRepliesJson(AutoReply(
        on: true,
        start: start,
        end: end,
        message: 'Away.\nBack Monday.',
        audience: ReplyAudience.everyone,
      ));
      expect(body['status'], 'scheduled');
      expect(body['externalAudience'], 'all');
      expect((body['scheduledStartDateTime'] as Map)['timeZone'], 'UTC');
      expect(
        DateTime.parse('${(body['scheduledStartDateTime'] as Map)['dateTime']}Z'),
        start.toUtc(),
      );
      expect(body['internalReplyMessage'], contains('Away.<br>Back Monday.'));
      expect(body['externalReplyMessage'], body['internalReplyMessage'],
          reason: 'no message of their own: the same one');

      final always = GraphSettingsApi.automaticRepliesJson(const AutoReply(
        on: true,
        message: 'Away',
        outsideMessage: 'מחוץ למשרד',
        audience: ReplyAudience.insideOnly,
      ));
      expect(always['status'], 'alwaysEnabled');
      expect(always.containsKey('scheduledStartDateTime'), isFalse);
      expect(always['externalAudience'], 'none');
      expect(always['externalReplyMessage'], contains('dir="rtl"'),
          reason: 'Hebrew reads from the right');
      expect(
        GraphSettingsApi.automaticRepliesJson(const AutoReply())['status'],
        'disabled',
      );
    });

    test('read and saved over Graph, with a token for the settings',
        () async {
      final requests = <http.Request>[];
      final api = GraphSettingsApi(
        accessToken: ({bool force = false}) async => 'settings-token',
        httpClient: MockClient((request) async {
          requests.add(request);
          return request.method == 'GET'
              ? json({'status': 'alwaysEnabled', 'internalReplyMessage': 'Hi'})
              : json({});
        }),
      );
      expect((await api.automaticReplies()).on, isTrue);
      await api.setAutomaticReplies(const AutoReply(message: 'Away'));
      expect(requests.first.url.path,
          '/v1.0/me/mailboxSettings/automaticRepliesSetting');
      expect(requests.last.method, 'PATCH');
      expect(requests.last.url.path, '/v1.0/me/mailboxSettings');
      expect(requests.last.headers['Authorization'], 'Bearer settings-token');
      final sent = jsonDecode(requests.last.body) as Map;
      expect((sent['automaticRepliesSetting'] as Map)['status'], 'disabled');
    });

    test('a refusal reads as one', () async {
      final api = GraphSettingsApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: MockClient((_) async => json({
              'error': {'code': 'ErrorAccessDenied', 'message': 'Access is denied.'},
            }, 403)),
      );
      expect(api.automaticReplies(), throwsA(isA<AuthenticationFailed>()));
    });
  });

  group("Graph's rules", () {
    String? pathOf(String id) => {'f-receipts': 'Receipts'}[id];

    test('a rule this app can say all of', () {
      final rule = GraphSettingsApi.ruleFrom({
        'id': 'r1',
        'displayName': 'Receipts',
        'sequence': 1,
        'isEnabled': true,
        'conditions': {
          'senderContains': ['shop@example.com'],
          'subjectContains': ['receipt', 'order'],
        },
        'actions': {
          'moveToFolder': 'f-receipts',
          'markAsRead': true,
          'stopProcessingRules': true,
        },
      }, pathOf)!;
      expect(rule.id, 'r1');
      expect(rule.from, ['shop@example.com']);
      expect(rule.subjectContains, ['receipt', 'order']);
      expect(rule.moveTo, 'Receipts');
      expect(rule.markRead, isTrue);
      expect(rule.partly, isFalse);
      expect(rule.summary,
          'From shop@example.com, subject has "receipt" or "order": '
          'move to Receipts, mark read');
    });

    test('one that does more is partly read, and left to Outlook', () {
      MailRule read(Map<String, Object?> extra) => GraphSettingsApi.ruleFrom({
            'id': 'r2',
            'displayName': 'More',
            'conditions': {
              'senderContains': ['a@example.com'],
              'isAutomaticReply': false,
              'bodyContains': <String>[],
            },
            'actions': {'markAsRead': true},
            ...extra,
          }, pathOf)!;
      expect(read({}).partly, isFalse,
          reason: 'false and empty are nothing set');
      expect(
        read({
          'conditions': {
            'senderContains': ['a@example.com'],
            'bodyContains': ['urgent'],
          },
        }).partly,
        isTrue,
      );
      expect(
        read({
          'actions': {
            'forwardTo': [
              {'emailAddress': {'address': 'b@example.com'}},
            ],
          },
        }).partly,
        isTrue,
      );
      expect(
        read({
          'exceptions': {'subjectContains': ['x']},
        }).partly,
        isTrue,
      );
      expect(read({'isReadOnly': true}).partly, isTrue);
      expect(
        read({
          'actions': {'moveToFolder': 'f-unknown'},
        }).partly,
        isTrue,
        reason: 'a folder the app does not know',
      );
    });

    test('what is sent for a new one', () {
      final body = GraphSettingsApi.ruleJson(
        const MailRule(from: ['shop@example.com'], moveTo: 'Receipts'),
        'f-receipts',
        4,
      );
      expect(body['displayName'], 'From shop@example.com: move to Receipts',
          reason: 'no name: what it does');
      expect(body['sequence'], 4);
      expect(body['conditions'], {
        'senderContains': ['shop@example.com'],
      });
      expect(body['actions'], {
        'moveToFolder': 'f-receipts',
        'stopProcessingRules': true,
      });
      final delete = GraphSettingsApi.ruleJson(
        const MailRule(name: 'Bin it', subjectContains: ['lottery'], delete: true),
        null,
        1,
      );
      expect(delete['actions'], {'delete': true, 'stopProcessingRules': true});
    });

    test('a new rule runs after the others', () async {
      final requests = <http.Request>[];
      final api = GraphSettingsApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return json({
              'value': [
                {'id': 'a', 'displayName': 'A', 'sequence': 3},
                {'id': 'b', 'displayName': 'B', 'sequence': 1},
              ],
            });
          }
          return json({'id': 'new-rule'}, 201);
        }),
      );
      final listed = await api.rules((_) => null);
      expect([for (final r in listed) r.id], ['b', 'a'], reason: 'in order');
      final made = await api.createRule(
          const MailRule(name: 'X', from: ['x@example.com'], markRead: true),
          null);
      expect(made.id, 'new-rule');
      final sent = jsonDecode(requests.last.body) as Map;
      expect(sent['sequence'], 4);
      expect(requests.last.url.path, '/v1.0/me/mailFolders/inbox/messageRules');
    });
  });

  group("Gmail's vacation responder", () {
    test('reads and writes as Gmail keeps it', () {
      final start = DateTime(2026, 11, 2, 9);
      final end = DateTime(2026, 11, 6, 18);
      final reply = GmailSettingsApi.autoReplyFrom({
        'enableAutoReply': true,
        'responseSubject': 'Away',
        'responseBodyPlainText': 'Back on Monday.',
        'responseBodyHtml': '<div>Back on Monday.</div>',
        'restrictToContacts': true,
        'restrictToDomain': false,
        'startTime': '${start.millisecondsSinceEpoch}',
        'endTime': '${end.millisecondsSinceEpoch}',
      });
      expect(reply.on, isTrue);
      expect(reply.subject, 'Away');
      expect(reply.message, 'Back on Monday.');
      expect(reply.audience, ReplyAudience.contacts);
      expect(reply.start, start);
      expect(reply.end, end);

      final back = GmailSettingsApi.vacationJson(reply);
      expect(back['enableAutoReply'], isTrue);
      expect(back['startTime'], '${start.millisecondsSinceEpoch}');
      expect(back['restrictToContacts'], isTrue);
      expect(back['restrictToDomain'], isFalse);
      expect(back['responseBodyHtml'], contains('Back on Monday.'));

      expect(
        GmailSettingsApi.autoReplyFrom({
          'enableAutoReply': false,
          'responseBodyHtml': '<p>Only <b>HTML</b></p>',
        }).message,
        'Only HTML',
      );
      expect(
        GmailSettingsApi.vacationJson(const AutoReply(on: true, message: 'x'))
            .containsKey('startTime'),
        isFalse,
      );
    });

    test('a token without the settings reads as needing consent', () async {
      final api = GmailSettingsApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: MockClient((_) async => json({
              'error': {
                'code': 403,
                'message': 'Request had insufficient authentication scopes.',
                'status': 'PERMISSION_DENIED',
                'details': [
                  {'reason': 'ACCESS_TOKEN_SCOPE_INSUFFICIENT'},
                ],
              },
            }, 403)),
      );
      expect(api.setVacation(const AutoReply()),
          throwsA(isA<SignInNeedsConsent>()));
    });

    test('the API switched off says where to switch it on', () async {
      final api = GmailSettingsApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: MockClient((_) async => json({
              'error': {
                'code': 403,
                'message': 'Gmail API has not been used in project 1 before '
                    'or it is disabled.',
                'details': [
                  {'reason': 'SERVICE_DISABLED'},
                ],
              },
            }, 403)),
      );
      expect(
        api.vacation(),
        throwsA(isA<ConnectionFailed>()
            .having((e) => e.message, 'message', contains('Gmail API'))),
      );
    });
  });

  group("Gmail's filters", () {
    const labels = {'Label_1': 'Receipts', 'Label_2': 'Clients/Hadco'};

    test('move, read, delete and archive read as rules', () {
      final move = GmailSettingsApi.ruleFrom({
        'id': 'f1',
        'criteria': {'from': 'shop@example.com OR orders@example.com'},
        'action': {
          'addLabelIds': ['Label_1'],
          'removeLabelIds': ['INBOX', 'UNREAD'],
        },
      }, labels)!;
      expect(move.from, ['shop@example.com', 'orders@example.com']);
      expect(move.moveTo, 'Receipts');
      expect(move.markRead, isTrue);
      expect(move.partly, isFalse);
      expect(move.title, move.summary, reason: 'filters have no names');

      final delete = GmailSettingsApi.ruleFrom({
        'id': 'f2',
        'criteria': {'subject': '"you have won" OR lottery'},
        'action': {
          'addLabelIds': ['TRASH'],
        },
      }, labels)!;
      expect(delete.subjectContains, ['you have won', 'lottery']);
      expect(delete.delete, isTrue);
      expect(delete.moveTo, isNull);

      final archive = GmailSettingsApi.ruleFrom({
        'id': 'f3',
        'criteria': {'from': 'news@example.com'},
        'action': {
          'removeLabelIds': ['INBOX'],
        },
      }, labels)!;
      expect(archive.moveTo, GmailSettingsApi.archiveName);
      expect(archive.partly, isFalse);
    });

    test('one that does more is partly read', () {
      bool partly(Map<String, Object?> criteria, Map<String, Object?> action) =>
          GmailSettingsApi.ruleFrom(
                  {'id': 'f', 'criteria': criteria, 'action': action}, labels)!
              .partly;
      expect(partly({'from': 'a', 'hasAttachment': true}, {'removeLabelIds': ['UNREAD']}),
          isTrue);
      expect(partly({'query': 'invoice'}, {'removeLabelIds': ['UNREAD']}), isTrue);
      expect(partly({'from': 'a'}, {'forward': 'b@example.com'}), isTrue);
      expect(partly({'from': 'a'}, {'addLabelIds': ['STARRED']}), isTrue);
      expect(partly({'from': 'a'}, {'addLabelIds': ['Label_1']}), isTrue,
          reason: 'labelled and left in the Inbox: not a move');
      expect(partly({'from': 'a', 'excludeChats': false}, {'removeLabelIds': ['UNREAD']}),
          isFalse);
    });

    test('what is sent for a new one', () {
      expect(
        GmailSettingsApi.filterJson(
          const MailRule(
            from: ['shop@example.com', 'orders@example.com'],
            subjectContains: ['your order'],
            moveTo: 'Receipts',
            markRead: true,
          ),
          labelId: 'Label_1',
        ),
        {
          'criteria': {
            'from': 'shop@example.com OR orders@example.com',
            'subject': '"your order"',
          },
          'action': {
            'addLabelIds': ['Label_1'],
            'removeLabelIds': ['INBOX', 'UNREAD'],
          },
        },
      );
      expect(
        GmailSettingsApi.filterJson(
          const MailRule(from: ['news@example.com'], moveTo: 'Archive'),
          archive: true,
        )['action'],
        {
          'removeLabelIds': ['INBOX'],
        },
      );
      expect(
        GmailSettingsApi.filterJson(
          const MailRule(subjectContains: ['lottery'], delete: true),
        )['action'],
        {
          'addLabelIds': ['TRASH'],
        },
      );
    });

    test('a rule is made with the label Gmail calls the folder', () async {
      final posted = <Map<String, Object?>>[];
      final settings = GmailServerSettings(
        api: GmailSettingsApi(
          accessToken: ({bool force = false}) async => 't',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/labels')) {
              return json({
                'labels': [
                  {'id': 'INBOX', 'name': 'INBOX', 'type': 'system'},
                  {'id': 'Label_2', 'name': 'Clients/Hadco', 'type': 'user'},
                ],
              });
            }
            posted.add((jsonDecode(request.body) as Map).cast());
            return json({'id': 'made'});
          }),
        ),
        isArchive: (path) async => path == '[Gmail]/All Mail',
      );

      final made = await settings.addRule(
          const MailRule(from: ['ron@hadco.example'], moveTo: 'Clients/Hadco'));
      expect(made.id, 'made');
      expect((posted.last['action'] as Map)['addLabelIds'], ['Label_2']);

      await settings.addRule(
          const MailRule(from: ['news@example.com'], moveTo: '[Gmail]/All Mail'));
      expect((posted.last['action'] as Map).containsKey('addLabelIds'), isFalse,
          reason: 'All Mail is the Inbox taken off');

      expect(
        settings.addRule(
            const MailRule(from: ['x@example.com'], moveTo: 'Gone')),
        throwsA(isA<ConnectionFailed>()),
      );
    });
  });

  test('a rule needs something to match and something to do', () {
    expect(const MailRule(from: ['a']).isValid, isFalse);
    expect(const MailRule(markRead: true).isValid, isFalse);
    expect(const MailRule(from: ['a'], markRead: true).isValid, isTrue);
    expect(const MailRule(name: ' Named ', from: ['a'], delete: true).title,
        'Named');
  });

  test('the sample keeps what it is given', () async {
    final s = MemoryServerSettings(microsoft: false);
    await s.setAutoReply(const AutoReply(on: true, message: 'Away'));
    expect((await s.autoReply()).message, 'Away');
    final made = await s.addRule(const MailRule(from: ['a'], markRead: true));
    expect((await s.rules()).single.id, made.id);
    await s.deleteRule(made);
    expect(await s.rules(), isEmpty);
    expect(s.rulesCanBeOff, isFalse);
    expect(s.repliesHaveSubject, isTrue);
  });
}
