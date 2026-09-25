import 'package:http/http.dart' as http;

import '../../domain/account.dart';
import '../../domain/meeting.dart';
import '../auth/microsoft_oauth.dart' show MicrosoftOAuth;
import '../graph/graph_calendar_api.dart';
import '../mail_engine.dart';
import 'google_calendar_api.dart';

/// The calendar behind an account, reached the way the account signs in.
///
/// Which calendar, and how, follows from the account alone. A Microsoft
/// account has Exchange's, over Graph, under a consent of its own that the
/// token is asked for by name. A Gmail account signed in with Google has its
/// Google Calendar on the same token as its mail. A Gmail account with an
/// app password has none the app can reach: the password covers IMAP and
/// SMTP and nothing else, and saying so is what lets the screen hand the
/// meeting to the phone's calendar app instead.
///
/// Apart from the engine so it can be proved against a fake server without
/// the engine's stores around it; the engine's part is naming the account.
class AccountCalendar {
  AccountCalendar({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _http = httpClient;

  /// The account's token for [scopes]: the calendar's for a Microsoft
  /// account, the default for a Google one, whose token has the calendar
  /// in it already.
  final Future<String> Function(
    String accountId, {
    bool force,
    List<String>? scopes,
  }) accessToken;

  /// Handed to the clients by tests. Null in the app, where each makes and
  /// closes its own.
  final http.Client? _http;

  /// Overridden by tests, which must not really wait out a throttle.
  final Future<void> Function(Duration)? sleep;

  /// Put [meeting] on [account]'s calendar; see `MailEngine.createMeeting`.
  Future<void> createMeeting(Account account, MeetingDraft meeting) async {
    // The screen checks this first; reaching here with it wrong is a bug.
    final problem = meeting.problem;
    if (problem != null) throw ArgumentError(problem);

    switch (account.provider) {
      case MailProvider.outlook:
        final api = GraphCalendarApi(
          accessToken: ({bool force = false}) => accessToken(
            account.id,
            force: force,
            scopes: MicrosoftOAuth.calendarScopes,
          ),
          httpClient: _http,
          sleep: sleep,
        );
        try {
          await api.createEvent(meeting);
        } finally {
          api.close();
        }
      case MailProvider.gmail when account.authMethod == AuthMethod.oauth:
        final api = GoogleCalendarApi(
          accessToken: ({bool force = false}) =>
              accessToken(account.id, force: force),
          httpClient: _http,
        );
        try {
          await api.createEvent(meeting);
        } finally {
          api.close();
        }
      case MailProvider.gmail:
        throw const CalendarUnavailable(
          "The app cannot reach this account's calendar: an app password "
          'covers its mail and nothing else.',
        );
    }
  }
}
