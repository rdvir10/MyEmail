import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/error_report.dart';
import 'package:myemail/ui/common/problem_view.dart';

/// The way out of an error, wherever one appears.
///
/// Before this, an error was red text and nothing else: it could not be acted
/// on and could not be passed on without a screenshot. These check that the
/// ways out are actually there, and — more importantly — that they are not
/// offered where they cannot work.
void main() {
  const account = Account(
    id: 'acct-1',
    displayName: 'Work',
    emailAddress: 'me@work.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF107C41,
  );

  Widget app(ProblemReport problem, {VoidCallback? onRemedy}) => ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ProblemView(problem: problem, onRemedy: onRemedy),
          ),
        ),
      );

  ProblemReport problem({Object? error}) => ProblemReport(
        doing: 'Sending a message',
        error: error ?? const SendFailedLike('The server would not take it.'),
        account: account,
      );

  testWidgets('the message is shown', (tester) async {
    await tester.pumpWidget(app(problem()));

    expect(find.text('The server would not take it.'), findsOneWidget);
  });

  testWidgets('reporting is always offered', (tester) async {
    // Whatever went wrong and whether or not anything can be done about it,
    // it can always be sent somewhere. That is the part that was missing.
    await tester.pumpWidget(app(problem()));

    expect(find.text('Copy details'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
  });

  testWidgets('a screen with somewhere to go offers to go there',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(app(
      problem(error: const AuthenticationFailed('Sign in again.')),
      onRemedy: () => tapped++,
    ));

    await tester.tap(find.text('Sign in again'));
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('a screen with nowhere to go offers only reporting',
      (tester) async {
    // Add account already has its own Sign in button a few lines below, so a
    // second one in the error would be the same action twice.
    await tester.pumpWidget(
      app(problem(error: const AuthenticationFailed('Sign in again.'))),
    );

    expect(find.text('Sign in again'), findsNothing);
    expect(find.text('Copy details'), findsOneWidget);
  });

  testWidgets('no remedy is offered for something a remedy cannot fix',
      (tester) async {
    // Even where the screen could act, the failure decides. A button that
    // cannot work is worse than none: it gets tried, it fails, and then there
    // is nothing left to try.
    await tester.pumpWidget(app(
      problem(error: StateError('a bug')),
      onRemedy: () {},
    ));

    expect(find.text('Sign in again'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Report'), findsOneWidget);
  });

  testWidgets('a failure with no sentence of its own still reads',
      (tester) async {
    // A bug rather than a condition. It shows as itself rather than being
    // dressed up as something the person did wrong.
    await tester.pumpWidget(app(problem(error: StateError('a bug'))));

    expect(find.textContaining('a bug'), findsOneWidget);
  });
}

/// A failure that carries its own sentence, as everything thrown on purpose
/// does. Declared here rather than reaching for a real one so the test does
/// not depend on which layer happens to own it.
class SendFailedLike implements Exception, ReadableError {
  const SendFailedLike(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}
