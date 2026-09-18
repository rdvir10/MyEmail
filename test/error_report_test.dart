import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/error_report.dart';

/// Turning a failure into something a person can act on, or send on.
void main() {
  const account = Account(
    id: 'acct-1',
    displayName: 'Work',
    emailAddress: 'me@work.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF107C41,
  );

  group('what the app offers to do', () {
    test('a stale credential offers a fresh sign-in', () {
      expect(
        remedyFor(const SignInExpired('Sign in again.')),
        ErrorRemedy.signInAgain,
      );
      expect(
        remedyFor(const AuthenticationFailed('The password was refused.')),
        ErrorRemedy.signInAgain,
      );
    });

    test('something that may pass on its own offers another try', () {
      expect(
        remedyFor(const ConnectionFailed('Could not reach the server.')),
        ErrorRemedy.retry,
      );
    });

    test('a consent only an administrator can give offers nothing', () {
      // Signing in again would loop without ever succeeding, and a button
      // that cannot work is worse than none: it is tried, it fails, and now
      // there is nothing else to try.
      expect(
        remedyFor(const SignInNeedsConsent(
          'An administrator has to approve the app.',
          needsAdministrator: true,
        )),
        ErrorRemedy.none,
      );
    });

    test('a consent the person can give themselves offers a sign-in', () {
      expect(
        remedyFor(const SignInNeedsConsent('Sign in again.')),
        ErrorRemedy.signInAgain,
      );
    });

    test('an unrecognised failure offers nothing rather than guessing', () {
      expect(remedyFor(StateError('a bug')), ErrorRemedy.none);
      expect(ErrorRemedy.none.isOffered, isFalse);
    });

    test('the offer follows the type, not the wording', () {
      // Matching on message text would mean a remedy silently stops being
      // offered the day someone rewords a sentence.
      expect(
        remedyFor(const AuthenticationFailed('anything at all')),
        ErrorRemedy.signInAgain,
      );
    });
  });

  group('filing it on GitHub', () {
    test('the address is masked, because the repository is public', () {
      // The clipboard keeps the whole address: that goes wherever the person
      // puts it. This one is published the moment they press submit.
      final url = IssueTracker.newIssueUrl(
        title: 'Loading folders — AuthenticationFailed',
        report: buildErrorReport(
          doing: 'Loading the folders for Work',
          error: const AuthenticationFailed('Refused.'),
          account: account,
          redactAddress: true,
        ),
      );

      expect(url.toString(), isNot(contains('me@work.example')));
      expect(Uri.decodeFull(url.toString()), contains('m***@work.example'));
    });

    test('masking keeps enough to tell two accounts apart', () {
      expect(maskAddress('ron.dvir@outlook.com'), 'r***@outlook.com');
      expect(maskAddress('ron@myhomestudio.club'), 'r***@myhomestudio.club');
    });

    test('something that is not an address masks to nothing', () {
      expect(maskAddress('not-an-address'), '***');
      expect(maskAddress('@only-a-domain'), '***');
    });

    test('it points at the repository the app is released from', () {
      final url = IssueTracker.newIssueUrl(title: 't', report: 'r');

      expect(url.host, 'github.com');
      expect(url.path, '/rdvir10/MyEmail/issues/new');
    });

    test('the report is fenced, so its shape survives Markdown', () {
      // A Microsoft error is a paragraph with trace IDs on their own lines.
      // Unfenced, Markdown reflows it into one run-on line.
      final url = IssueTracker.newIssueUrl(
        title: 't',
        report: 'line one\nline two',
      );

      expect(url.queryParameters['body'], contains('```'));
      expect(
        url.queryParameters['body'],
        contains('line one\nline two'),
      );
    });

    test('nothing secret can reach it, because the report holds none', () {
      final url = IssueTracker.newIssueUrl(
        title: 'x',
        report: buildErrorReport(
          doing: 'Loading the folders for Work',
          error: const AuthenticationFailed('Refused.'),
          account: account,
          redactAddress: true,
        ),
      );
      final text = Uri.decodeFull(url.toString()).toLowerCase();

      for (final forbidden in ['bearer ', 'refresh_token', 'access_token']) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('the title says what failed and what it was', () {
      expect(
        IssueTracker.titleFor(
          doing: 'Loading the folders for Work',
          error: const AuthenticationFailed('Refused.'),
        ),
        'Loading the folders for Work — AuthenticationFailed',
      );
    });
  });

  group('the report', () {
    String report({Object? error}) => buildErrorReport(
          doing: 'Loading the folders for Work',
          error: error ?? const ConnectionFailed('Could not reach Microsoft.'),
          account: account,
          appVersion: '2.1.1',
          build: 18,
          at: DateTime.utc(2026, 9, 18, 14, 30),
        );

    test('carries the build, which is what identifies the code', () {
      expect(report(), contains('2.1.1'));
      expect(report(), contains('build 18'));
    });

    test('says which account and how it signs in', () {
      expect(report(), contains('me@work.example'));
      expect(report(), contains('Outlook'));
    });

    test('says what the app was doing', () {
      // Usually the part that identifies the problem. The same sentence can
      // come from a sync, a send or a folder load.
      expect(report(), contains('Loading the folders for Work'));
    });

    test('carries the type as well as the message', () {
      // Two different failures often read the same to a person and are
      // nothing alike underneath.
      final text = report(error: const AuthenticationFailed('Refused.'));

      expect(text, contains('AuthenticationFailed'));
      expect(text, contains('Refused.'));
    });

    test('holds no secret', () {
      // Nothing here reads the Keystore, and the report is meant to be pasted
      // into a chat window. This is the check that it stays that way.
      final text = report().toLowerCase();

      for (final forbidden in ['bearer ', 'refresh_token', 'access_token']) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('an account it does not know still produces a report', () {
      // A failure with no account attached — a send with nothing selected, a
      // bug — must still be reportable.
      final text = buildErrorReport(
        doing: 'Something',
        error: StateError('oops'),
      );

      expect(text, contains('Something'));
      expect(text, contains('oops'));
    });
  });
}
