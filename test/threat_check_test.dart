import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/security/online_checks.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/threat_check.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/threat_check_providers.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/settings/threat_check_settings_screen.dart';

import 'fakes/fake_webview.dart';

/// Check for threats: what the mail server found, the sender, the links and
/// the attachments, on the phone; Google Safe Browsing for the links and
/// VirusTotal for the attachments where their keys are set.
void main() {
  List<String> titles(Iterable<ThreatFinding> found) =>
      [for (final f in found) f.title];

  group('what the mail server found', () {
    test("Microsoft's phishing verdict and failed sender checks", () {
      final found = checkHeaders({
        'authentication-results':
            'spf=fail (sender IP is 203.0.113.9) smtp.mailfrom=paypa1.example; '
                'dkim=none (message not signed) header.d=none;dmarc=fail '
                'action=quarantine header.from=paypal.com;compauth=fail '
                'reason=000',
        'x-forefront-antispam-report':
            'CIP:203.0.113.9;CTRY:RU;LANG:en;SCL:9;SRV:;IPV:NLI;SFV:SPM;'
                'H:mail.example;PTR:;CAT:PHSH;SFS:(13230031);DIR:INB;',
      });
      expect(titles(found), [
        "The sender's domain says this is not from it",
        'Microsoft could not confirm who sent it',
        'It came from a server its domain does not list',
        'Microsoft marked it as phishing',
      ]);
      expect(worstOf(found), ThreatLevel.danger);
    });

    test("Gmail's passes, without its ARC comment's", () {
      final found = checkHeaders({
        'authentication-results': 'mx.google.com;\r\n'
            '       dkim=pass header.i=@partner.example header.s=s1;\r\n'
            '       arc=pass (i=1 spf=fail dkim=fail dmarc=fail);\r\n'
            '       spf=pass (google.com: domain of dana@partner.example '
            'designates 198.51.100.7 as permitted sender) '
            'smtp.mailfrom=dana@partner.example;\r\n'
            '       dmarc=pass (p=REJECT sp=REJECT dis=NONE) '
            'header.from=partner.example',
      });
      expect(titles(found), ["The sender's domain vouches for it"]);
      expect(worstOf(found), ThreatLevel.safe);
    });

    test('spam, bulk and a skipped filter', () {
      expect(
        titles(checkHeaders({'x-ms-exchange-organization-scl': '6'})),
        contains('Microsoft rated it spam'),
      );
      expect(
        checkHeaders({'x-microsoft-antispam': 'BCL:8;'})
            .where((f) => f.level == ThreatLevel.caution)
            .map((f) => f.title),
        ['Bulk mail many people report as junk'],
      );
      expect(
        titles(checkHeaders({'x-ms-exchange-organization-scl': '-1'})),
        contains("Microsoft's spam filter let it through unchecked"),
      );
    });

    test('Received-SPF where there is no Authentication-Results', () {
      final found = checkHeaders({
        'received-spf': 'SoftFail (protection.outlook.com: domain of '
            'transitioning bank.example discourages use of 203.0.113.9 as '
            'permitted sender)',
      });
      expect(found.single.title,
          'It came from a server its domain does not list');
      expect(found.single.level, ThreatLevel.caution);
    });

    test('none at all', () {
      expect(titles(checkHeaders(const {})),
          ['The server did not record its sender checks']);
    });
  });

  group('links', () {
    test("Safe Links and Google's redirects come off; mail, phone and "
        'anchors are not links', () {
      final links = linksIn(html: '''
<p>Hello</p>
<a href="https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fevil.example%2Flogin%3Fid%3D1&amp;data=05%7C02&amp;reserved=0">www.paypal.com</a>
<a href="mailto:help@paypal.com">Write to us</a>
<a href="tel:+15550100">Call</a>
<a href="#top">Top</a>
<a href="https://www.google.com/url?q=https://partner.example/news&amp;sa=D">Our news</a>
<a href="https://www.google.com/url?q=https://partner.example/news&amp;sa=D">Our news</a>
''');
      expect([for (final l in links) l.target.toString()], [
        'https://evil.example/login?id=1',
        'https://partner.example/news',
      ]);
      expect(links.first.text, 'www.paypal.com');

      final found = checkLinks(links, known: {'example.com', 'partner.example'});
      expect(titles(found), ['A link reads paypal.com but goes to evil.example']);
      expect(found.single.level, ThreatLevel.danger);
    });

    test("a plain text body's addresses, without the sentence's full stop",
        () {
      final links = linksIn(
          text: 'See https://bit.ly/3xYz and http://203.0.113.9/login.');
      expect([for (final l in links) l.url],
          ['https://bit.ly/3xYz', 'http://203.0.113.9/login']);
      expect(titles(checkLinks(links)), [
        'A shortened link hides where it goes',
        'A link goes to a bare internet address',
      ]);
    });

    test('a hidden address, a script, lookalike letters and a lookalike '
        'domain', () {
      final found = checkLinks(
        linksIn(html: '''
<a href="https://www.paypal.com@evil.example/signin">Sign in</a>
<a href="javascript:alert(1)">Open</a>
<a href="https://xn--pypal-4ve.com/">Pay</a>
<a href="https://hadc0.com/login">Portal</a>
<a href="https://www.hadco.com/news">Our news</a>
'''),
        known: {'hadco.com'},
      );
      expect(titles(found), [
        'A link hides where it goes',
        'A link runs something rather than opening a page',
        "A link's address uses lookalike letters",
        'A link goes to hadc0.com, which looks like hadco.com',
      ]);
      expect(found.first.detail,
          'Everything before the @ is decoration; it goes to evil.example.');
    });

    test('lookalike domains', () {
      expect(lookalikeOf('rnicrosoft.com', {'microsoft.com'}), 'microsoft.com');
      expect(lookalikeOf('paypai.com', {'paypal.com'}), 'paypal.com');
      expect(lookalikeOf('mail.hadco.com', {'hadco.com'}), isNull);
      expect(lookalikeOf('hadco.com', {'hadco.com'}), isNull);
      // Short names are not compared letter by letter: too many are real.
      expect(lookalikeOf('king.com', {'bing.com'}), isNull);
      expect(baseDomain('www.example.co.uk'), 'example.co.uk');
      expect(baseDomain('mail.hadco.com'), 'hadco.com');
    });
  });

  group('the sender', () {
    MailMessage from(
      String email, {
      String? name,
      List<MailAddress> replyTo = const [],
    }) =>
        MailMessage(
          id: 'acct-personal:INBOX#900',
          accountId: 'acct-personal',
          folderId: 'acct-personal:INBOX',
          uid: 900,
          subject: 'Your account',
          from: MailAddress(email: email, name: name),
          to: const [MailAddress(email: 'personal@example.com')],
          date: DateTime(2026, 10, 26, 9),
          preview: '',
          replyTo: replyTo,
        );

    test('a name showing another address', () {
      expect(
        titles(checkSender(
          from('alerts@evil.example', name: 'support@paypal.com'),
          knownAddresses: {'alerts@evil.example'},
        )),
        ['Its name shows support@paypal.com, but it comes from '
            'alerts@evil.example'],
      );
      expect(
        checkSender(
          from('dana@partner.example',
              name: 'Dana Levi (dana@partner.example)'),
          knownAddresses: {'dana@partner.example'},
        ),
        isEmpty,
      );
    });

    test('replies that go to another domain', () {
      expect(
        titles(checkSender(
          from('billing@partner.example', replyTo: const [
            MailAddress(email: 'collect@other.example'),
          ]),
          knownAddresses: {'billing@partner.example'},
        )),
        ['Replies go to collect@other.example, not to the sender'],
      );
      expect(
        checkSender(
          from('billing@partner.example', replyTo: const [
            MailAddress(email: 'noreply@mail.partner.example'),
          ]),
          knownAddresses: {'billing@partner.example'},
        ),
        isEmpty,
      );
    });

    test('a lookalike domain, and a first mail', () {
      final found = checkSender(from('ceo@hadc0.com'), known: {'hadco.com'});
      expect(titles(found), [
        'It comes from hadc0.com, which looks like hadco.com',
        'The first mail from this address',
      ]);
      expect(worstOf(found), ThreatLevel.danger);
    });
  });

  test('attachments, by what they are', () {
    MailAttachment file(String name, {bool inline = false}) => MailAttachment(
          id: name,
          name: name,
          mimeType: 'application/octet-stream',
          sizeBytes: 1000,
          isInline: inline,
        );
    final found = checkAttachments([
      file('Invoice.pdf.exe'),
      file('setup.exe'),
      file('Budget.xlsm'),
      file('Sign in.html'),
      file('Photos.zip'),
      file('Report.pdf'),
      file('logo.exe', inline: true),
    ]);
    expect([for (final f in found) (f.title, f.level)], [
      ('Invoice.pdf.exe hides what it is', ThreatLevel.danger),
      ('setup.exe runs when opened', ThreatLevel.danger),
      ('Budget.xlsm carries macros', ThreatLevel.caution),
      ('Sign in.html is a web page', ThreatLevel.caution),
      ('Photos.zip is an archive', ThreatLevel.safe),
    ]);
    expect(found.first.detail,
        'It reads as a pdf but is a .exe, which runs when opened.');
    expect(isRiskyAttachment(file('a.docm')), isTrue);
    expect(isRiskyAttachment(file('a.pdf')), isFalse);
    expect(threatTypeName('SOCIAL_ENGINEERING'), 'phishing');
    expect(threatTypeName('THREAT_TYPE_UNSPECIFIED'), 'dangerous');
  });

  group('the check', () {
    final message = MailMessage(
      id: 'acct-personal:INBOX#901',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 901,
      subject: 'Your mailbox is full',
      from: const MailAddress(email: 'alerts@exarnple.com', name: 'IT'),
      to: const [MailAddress(email: 'personal@example.com')],
      date: DateTime(2026, 10, 26, 9),
      preview: '',
      hasAttachments: true,
    );
    MailAttachment file(String name, {int size = 1000, bool inline = false}) =>
        MailAttachment(
          id: name,
          name: name,
          mimeType: 'application/octet-stream',
          sizeBytes: size,
          isInline: inline,
        );
    String fingerprint(String id) =>
        sha256.convert(utf8.encode('file $id')).toString();

    Future<ProviderContainer> container(
      _ThreatEngine engine, {
      String? safeBrowsingKey,
      String? virusTotalKey,
      SafeBrowsing? safeBrowsing,
      VirusTotal? virusTotal,
    }) async {
      final secrets = MemoryCredentialStore();
      if (safeBrowsingKey != null) {
        await secrets.writeSecret(safeBrowsingKeyName, safeBrowsingKey);
      }
      if (virusTotalKey != null) {
        await secrets.writeSecret(virusTotalKeyName, virusTotalKey);
      }
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        credentialStoreProvider.overrideWithValue(secrets),
        if (safeBrowsing != null)
          safeBrowsingProvider.overrideWithValue(safeBrowsing),
        if (virusTotal != null) virusTotalProvider.overrideWithValue(virusTotal),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    /// Every report the check gives, to the one it finishes with.
    Future<List<ThreatReport>> check(ProviderContainer c) {
      final seen = <ThreatReport>[];
      final done = Completer<List<ThreatReport>>();
      c.listen(threatCheckProvider(message), (_, next) {
        switch (next) {
          case AsyncData(:final value):
            seen.add(value);
            if (!value.checking && !done.isCompleted) done.complete(seen);
          case AsyncError(:final error) when !done.isCompleted:
            done.completeError(error);
          default:
        }
      }, fireImmediately: true);
      return done.future;
    }

    test('on the phone alone where no key is set', () async {
      final engine = _ThreatEngine(
        html: '<a href="https://evil.example/login">www.paypal.com</a>',
      )..headers[message.id] = {
          'authentication-results': 'spf=pass smtp.mailfrom=exarnple.com; '
              'dkim=none; dmarc=fail header.from=exarnple.com',
        };
      final google = _FakeSafeBrowsing();
      final virusTotal = _FakeVirusTotal();
      final c = await container(engine,
          safeBrowsing: google, virusTotal: virusTotal);

      final report = (await check(c)).single;

      expect(report.checking, isFalse);
      expect(report.safeBrowsing, isFalse);
      expect(report.virusTotal, isFalse);
      expect(report.level, ThreatLevel.danger);
      expect(titles(report.findings), [
        "The sender's domain says this is not from it",
        // The accounts' own domain is example.com.
        'It comes from exarnple.com, which looks like example.com',
        'The first mail from this address',
        'A link reads paypal.com but goes to evil.example',
      ]);
      expect(google.asked, isEmpty);
      expect(virusTotal.asked, isEmpty);
    });

    test("headers that cannot be read are said, and the rest goes on",
        () async {
      final engine = _ThreatEngine(failHeaders: true);
      final c = await container(engine);

      final report = (await check(c)).single;

      expect(titles(report.findings),
          contains("The mail server's verdicts could not be read"));
    });

    test('Google Safe Browsing for the links, VirusTotal for the files, '
        'risky ones first', () async {
      final engine = _ThreatEngine(
        html: '<a href="https://nam12.safelinks.protection.outlook.com/?url='
            'https%3A%2F%2Fevil.example%2Flogin&amp;reserved=0">Sign in</a>'
            '<a href="https://example.com/help">Help</a>',
        files: [file('Invoice.pdf'), file('Invoice.pdf.exe')],
      );
      final google = _FakeSafeBrowsing(
          {'https://evil.example/login': 'SOCIAL_ENGINEERING'});
      final virusTotal = _FakeVirusTotal(verdicts: {
        fingerprint('Invoice.pdf.exe'):
            (malicious: 41, suspicious: 2, clean: 20),
      });
      final c = await container(
        engine,
        safeBrowsingKey: 'sb-key',
        virusTotalKey: 'vt-key',
        safeBrowsing: google,
        virusTotal: virusTotal,
      );

      final reports = await check(c);

      expect([for (final r in reports) r.checking], [true, false]);
      expect(google.asked.single,
          ['https://evil.example/login', 'https://example.com/help']);
      expect(google.key, 'sb-key');
      expect(virusTotal.asked,
          [fingerprint('Invoice.pdf.exe'), fingerprint('Invoice.pdf')]);
      expect(virusTotal.key, 'vt-key');
      final online = [
        for (final f in reports.last.findings)
          if (f.area == ThreatArea.online) (f.title, f.level),
      ];
      expect(online, [
        ('Google lists a link as phishing', ThreatLevel.danger),
        ('Invoice.pdf.exe: 41 of 63 antivirus engines flag it as malicious',
            ThreatLevel.danger),
        ('VirusTotal has not seen Invoice.pdf', ThreatLevel.safe),
      ]);
    });

    test('none listed, and only four files a check', () async {
      final engine = _ThreatEngine(
        html: '<a href="https://example.com/help">Help</a>',
        files: [
          for (final n in ['a', 'b', 'c', 'd', 'e']) file('$n.pdf'),
          file('f.exe'),
          file('logo.png', inline: true),
          file('video.mp4', size: 40 * 1024 * 1024),
        ],
      );
      final virusTotal = _FakeVirusTotal(verdicts: {
        for (final n in ['a', 'b', 'c', 'd', 'e'])
          fingerprint('$n.pdf'): (malicious: 0, suspicious: 0, clean: 60),
      });
      final c = await container(
        engine,
        safeBrowsingKey: 'sb-key',
        virusTotalKey: 'vt-key',
        safeBrowsing: _FakeSafeBrowsing(),
        virusTotal: virusTotal,
      );

      final report = (await check(c)).last;

      expect(virusTotal.asked, hasLength(4));
      expect(virusTotal.asked.first, fingerprint('f.exe'));
      final online = titles(
          report.findings.where((f) => f.area == ThreatArea.online));
      expect(online.first, 'Google Safe Browsing lists none of its links');
      expect(online.last, 'Only 4 of 6 files were checked');
      expect(online, contains('a.pdf: no antivirus engine flags it'));
    });

    test('a key VirusTotal refuses stops it asking', () async {
      final engine = _ThreatEngine(files: [file('a.exe'), file('b.exe')]);
      final virusTotal = _FakeVirusTotal(
        failure: const OnlineCheckFailed('VirusTotal refused the key.'),
      );
      final c = await container(engine,
          virusTotalKey: 'vt-key', virusTotal: virusTotal);

      final report = (await check(c)).last;

      expect(virusTotal.asked, hasLength(1));
      final refused = report.findings.singleWhere(
          (f) => f.title == 'VirusTotal could not check a.exe');
      expect(refused.detail, 'VirusTotal refused the key.');
    });
  });

  group('Google Safe Browsing over HTTP', () {
    test('sends the links with the key, and reads what it lists', () async {
      late http.Request sent;
      final google = HttpSafeBrowsing(
        client: http_testing.MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'matches': [
                {
                  'threatType': 'MALWARE',
                  'platformType': 'ANY_PLATFORM',
                  'threat': {'url': 'http://evil.example/'},
                },
              ],
            }),
            200,
          );
        }),
      );

      final listed = await google.listed(
        ['http://evil.example/', 'https://example.com/'],
        key: 'k1',
      );

      expect(listed, {'http://evil.example/': 'MALWARE'});
      expect(sent.url.host, 'safebrowsing.googleapis.com');
      expect(sent.url.queryParameters['key'], 'k1');
      final entries = (jsonDecode(sent.body) as Map)['threatInfo']
          ['threatEntries'] as List;
      expect([for (final e in entries) (e as Map)['url']],
          ['http://evil.example/', 'https://example.com/']);
    });

    test('an empty answer lists nothing', () async {
      final google = HttpSafeBrowsing(
        client: http_testing.MockClient(
            (_) async => http.Response('{}', 200)),
      );
      expect(await google.listed(['https://example.com/'], key: 'k'), isEmpty);
    });

    test('a refused key says where to put it right', () async {
      final google = HttpSafeBrowsing(
        client: http_testing.MockClient((_) async => http.Response(
              jsonEncode({
                'error': {'code': 400, 'message': 'API key not valid.'},
              }),
              400,
            )),
      );
      await expectLater(
        google.listed(['https://example.com/'], key: 'bad'),
        throwsA(isA<OnlineCheckFailed>().having(
          (e) => e.message,
          'message',
          allOf(contains('Settings, Threat check'),
              contains('API key not valid.')),
        )),
      );
    });
  });

  group('VirusTotal over HTTP', () {
    test('asks by fingerprint with the key, and counts the engines',
        () async {
      late http.Request sent;
      final virusTotal = HttpVirusTotal(
        client: http_testing.MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'data': {
                'attributes': {
                  'last_analysis_stats': {
                    'malicious': 3,
                    'suspicious': 1,
                    'undetected': 58,
                    'harmless': 2,
                    'timeout': 1,
                  },
                },
              },
            }),
            200,
          );
        }),
      );

      final verdict = await virusTotal.file('abc123', key: 'k2');

      expect(verdict, (malicious: 3, suspicious: 1, clean: 60));
      expect(sent.url.toString(),
          'https://www.virustotal.com/api/v3/files/abc123');
      expect(sent.headers['x-apikey'], 'k2');
    });

    test('a file never seen, or not looked at yet, is null', () async {
      final unseen = HttpVirusTotal(
        client: http_testing.MockClient(
            (_) async => http.Response('{"error":{}}', 404)),
      );
      expect(await unseen.file('abc', key: 'k'), isNull);
      final queued = HttpVirusTotal(
        client: http_testing.MockClient((_) async =>
            http.Response('{"data":{"attributes":{}}}', 200)),
      );
      expect(await queued.file('abc', key: 'k'), isNull);
    });

    test('the allowance used up, and a refused key, say so', () async {
      HttpVirusTotal answering(int status) => HttpVirusTotal(
            client: http_testing.MockClient(
                (_) async => http.Response('{}', status)),
          );
      await expectLater(
        answering(429).file('abc', key: 'k'),
        throwsA(isA<OnlineCheckFailed>().having(
            (e) => e.message, 'message', contains('four files a minute'))),
      );
      await expectLater(
        answering(401).file('abc', key: 'k'),
        throwsA(isA<OnlineCheckFailed>().having(
            (e) => e.message, 'message', contains('refused the key'))),
      );
    });
  });

  group('on screen', () {
    testWidgets('Settings, Threat check keeps a key on the device, and '
        'Remove takes it away', (tester) async {
      final secrets = MemoryCredentialStore();
      await tester.pumpWidget(ProviderScope(
        overrides: [credentialStoreProvider.overrideWithValue(secrets)],
        child: const MaterialApp(home: ThreatCheckSettingsScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Set on this device'), findsNothing);

      await tester.tap(find.text('Google Safe Browsing key'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('threat-key-field')), '  AIza-test  ');
      await tester.tap(find.byKey(const ValueKey('threat-key-save')));
      await tester.pumpAndSettle();

      expect(await tester.runAsync(
              () => secrets.readSecret(safeBrowsingKeyName)),
          'AIza-test');
      expect(find.text('Set on this device'), findsOneWidget);

      await tester.tap(find.text('Google Safe Browsing key'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('threat-key-remove')));
      await tester.pumpAndSettle();

      expect(await tester.runAsync(
              () => secrets.readSecret(safeBrowsingKeyName)),
          isNull);
      expect(find.text('Set on this device'), findsNothing);
    });

    testWidgets("from the message's menu; a key set up from the sheet "
        'checks again with it', (tester) async {
      FakeWebViewPlatform.install();
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _ThreatEngine(
        html: '<a href="https://evil.example/login">www.paypal.com</a>',
      );
      final message = (await tester.runAsync(() async {
        final inbox = (await engine.loadFolders('acct-personal'))
            .firstWhere((f) => f.role == FolderRole.inbox);
        return (await engine.loadMessages(inbox.id)).first;
      }))!;
      engine.headers[message.id] = {
        'x-forefront-antispam-report': 'SCL:1;CAT:NONE;',
      };
      final google = _FakeSafeBrowsing(
          {'https://evil.example/login': 'SOCIAL_ENGINEERING'});
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
        safeBrowsingProvider.overrideWithValue(google),
      ]);
      addTearDown(c.dispose);
      c.read(selectedFolderIdProvider.notifier).select(message.folderId);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: ReadingPane(message: message, onPopOut: () {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check for threats…'));
      await tester.pumpAndSettle();

      expect(find.text('This looks dangerous'), findsOneWidget);
      expect(find.text('A link reads paypal.com but goes to evil.example'),
          findsOneWidget);
      expect(find.text("Microsoft's spam filter found nothing"),
          findsOneWidget);
      expect(
          find.text('Checked on the phone. Google Safe Browsing and '
              'VirusTotal are not set up.'),
          findsOneWidget);
      expect(google.asked, isEmpty);

      await tester.tap(find.text('Set up the online checks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Safe Browsing key'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('threat-key-field')), 'AIza-test');
      await tester.tap(find.byKey(const ValueKey('threat-key-save')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(google.asked, hasLength(1));
      expect(find.text('Google lists a link as phishing'), findsOneWidget);
      expect(find.text('Checked on the phone and with Google Safe Browsing.'),
          findsOneWidget);
    });
  });
}

/// The sample engine with a body, files and headers of a test's choosing.
class _ThreatEngine extends SampleMailEngine {
  _ThreatEngine({
    this.html = '',
    this.files = const [],
    this.failHeaders = false,
  });

  final String html;
  final List<MailAttachment> files;
  final bool failHeaders;

  @override
  Future<MailBody> loadMessageBody(String messageId) async =>
      MailBody(text: '', html: html.isEmpty ? null : html);

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async =>
      files;

  @override
  Future<Uint8List> fetchAttachment(
    String messageId,
    String attachmentId,
  ) async =>
      Uint8List.fromList(utf8.encode('file $attachmentId'));

  @override
  Future<Map<String, String>> messageHeaders(
    String messageId,
    List<String> names,
  ) {
    if (failHeaders) throw StateError('The server is away');
    return super.messageHeaders(messageId, names);
  }
}

class _FakeSafeBrowsing implements SafeBrowsing {
  _FakeSafeBrowsing([this.listing = const {}]);

  final Map<String, String> listing;
  final List<List<String>> asked = [];
  String? key;

  @override
  Future<Map<String, String>> listed(
    List<String> urls, {
    required String key,
  }) async {
    asked.add(urls);
    this.key = key;
    return {for (final u in urls) u: ?listing[u]};
  }
}

class _FakeVirusTotal implements VirusTotal {
  _FakeVirusTotal({this.verdicts = const {}, this.failure});

  final Map<String, FileVerdict> verdicts;
  final OnlineCheckFailed? failure;
  final List<String> asked = [];
  String? key;

  @override
  Future<FileVerdict?> file(String sha256, {required String key}) async {
    asked.add(sha256);
    this.key = key;
    if (failure case final f?) throw f;
    return verdicts[sha256];
  }
}
