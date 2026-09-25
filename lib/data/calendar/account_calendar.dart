import 'package:flutter/foundation.dart' show debugPrint;
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
/// Held for the engine's life: what a Microsoft calendar said about where
/// it holds meetings online is remembered here, asked once rather than
/// every time the screen opens.
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

  /// Where each Microsoft calendar holds a meeting online, by account, as
  /// Graph answered. Only answers are kept: a calendar that could not be
  /// asked is asked again next time, so one allowed to the app after a
  /// sign-in is not remembered as having said nowhere.
  final Map<String, GraphOnlineMeetings?> _graphOnline = {};

  /// Where [account]'s calendar holds a meeting online, or null where it
  /// holds none or would not say; see `MailEngine.onlineMeetingsFor`.
  Future<OnlineMeetingKind?> onlineMeetingsFor(Account account) async {
    switch (account.provider) {
      case MailProvider.outlook:
        return (await _graphOnlineMeetings(account))?.kind;
      case MailProvider.gmail when account.authMethod == AuthMethod.oauth:
        // Every Google calendar has Meet; there is nothing to ask.
        return OnlineMeetingKind.googleMeet;
      case MailProvider.gmail:
        return null;
    }
  }

  Future<GraphOnlineMeetings?> _graphOnlineMeetings(Account account) async {
    if (_graphOnline.containsKey(account.id)) return _graphOnline[account.id];
    final api = _graphApi(account);
    try {
      return _graphOnline[account.id] = await api.onlineMeetings();
    } catch (e) {
      // Said, never thrown: the switch simply stays off the screen, and the
      // meeting can still be made. No consent yet and no connection both
      // land here, and neither is a reason to stop a meeting.
      debugPrint(
        "[myemail] could not ask ${account.emailAddress}'s calendar where it "
        'holds online meetings: $e',
      );
      return null;
    } finally {
      api.close();
    }
  }

  GraphCalendarApi _graphApi(Account account) => GraphCalendarApi(
        accessToken: ({bool force = false}) => accessToken(
          account.id,
          force: force,
          scopes: MicrosoftOAuth.calendarScopes,
        ),
        httpClient: _http,
        sleep: sleep,
      );

  /// Put [meeting] on [account]'s calendar; see `MailEngine.createMeeting`.
  Future<CreatedMeeting> createMeeting(
    Account account,
    MeetingDraft meeting,
  ) async {
    // The screen checks this first; reaching here with it wrong is a bug.
    final problem = meeting.problem;
    if (problem != null) throw ArgumentError(problem);

    switch (account.provider) {
      case MailProvider.outlook:
        // Held where the calendar said it holds them. Where it would not
        // say, Graph is left to the calendar's default.
        final provider = meeting.online
            ? (await _graphOnlineMeetings(account))?.provider
            : null;
        final api = _graphApi(account);
        try {
          return await api.createEvent(
            meeting,
            onlineMeetingProvider: provider,
          );
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
          return await api.createEvent(meeting);
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
