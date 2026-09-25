import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/account.dart';
import '../../domain/meeting.dart';
import '../auth/google_oauth.dart' show GoogleOAuth;
import '../auth/microsoft_oauth.dart'
    show MicrosoftOAuth, SignInExpired, SignInNeedsConsent;
import '../graph/graph_calendar_api.dart';
import '../mail_engine.dart';
import 'google_calendar_api.dart';
import 'google_meet_api.dart';

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
/// A meeting held on Google Meet from a Microsoft account is the one case
/// that crosses accounts: the Gmail account signed in with Google makes the
/// link, through the Meet API, and the Outlook invitation carries it. Ron
/// asked for it for his Microsoft account at myhomestudio.club.
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
    required this.accounts,
    http.Client? httpClient,
    this.sleep,
  }) : _http = httpClient;

  /// The account's token for [scopes]: the calendar's for a Microsoft
  /// account, the default for a Google one, whose token has the calendar
  /// in it already, and Meet's for the Google account that makes a link
  /// for another account's meeting.
  final Future<String> Function(
    String accountId, {
    bool force,
    List<String>? scopes,
  }) accessToken;

  /// Every account in the app, as it stands: where the Gmail account that
  /// makes Meet links is looked for.
  final Iterable<Account> Function() accounts;

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

  /// The Gmail account signed in with Google that makes Meet links for the
  /// accounts that cannot, or null while there is none. The first such
  /// account, which is the one there is.
  Account? _meetMaker() => accounts()
      .where((a) =>
          a.provider == MailProvider.gmail &&
          a.authMethod == AuthMethod.oauth)
      .firstOrNull;

  /// The kinds a meeting from [account] can be held online as, its own
  /// calendar's first; see `MailEngine.onlineMeetingsFor`.
  Future<List<OnlineMeetingKind>> onlineMeetingsFor(Account account) async {
    switch (account.provider) {
      case MailProvider.outlook:
        final own = (await _graphOnlineMeetings(account))?.kind;
        return [
          ?own,
          if (_meetMaker() != null) OnlineMeetingKind.googleMeet,
        ];
      case MailProvider.gmail when account.authMethod == AuthMethod.oauth:
        // Every Google calendar has Meet; there is nothing to ask.
        return const [OnlineMeetingKind.googleMeet];
      case MailProvider.gmail:
        return const [];
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
        if (meeting.online == OnlineMeetingKind.googleMeet) {
          // Made first, by the Google account, so a link that cannot be
          // had leaves no event behind without one.
          final link = await _meetLink();
          final api = _graphApi(account);
          try {
            return await api.createEvent(meeting, joinUrl: link);
          } finally {
            api.close();
          }
        }
        // Held where the calendar said it holds them. Where it would not
        // say, Graph is left to the calendar's default.
        final provider = meeting.isOnline
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

  /// A Meet link from the Gmail account, on its token for Meet. What goes
  /// wrong with that sign-in is said in that account's name: it is not the
  /// meeting's account, and the screen's remedies would otherwise point at
  /// the wrong one.
  Future<String> _meetLink() async {
    final maker = _meetMaker();
    if (maker == null) {
      // The screen offers Google Meet only while there is one.
      throw ArgumentError(
        'Google Meet was asked for with no Google account to make the link.',
      );
    }
    final api = GoogleMeetApi(
      accessToken: ({bool force = false}) => accessToken(
        maker.id,
        force: force,
        scopes: GoogleOAuth.meetScopes,
      ),
      httpClient: _http,
    );
    try {
      return await api.createSpace();
    } on SignInNeedsConsent catch (e) {
      throw MeetLinkNeedsConsent(
        accountId: maker.id,
        emailAddress: maker.emailAddress,
        message: e.message,
      );
    } on SignInExpired {
      throw AuthenticationFailed(
        'The Google sign-in for ${maker.emailAddress}, which makes the Meet '
        'link, is no longer accepted. Open Settings, Accounts and sign in '
        'to it again.',
      );
    } finally {
      api.close();
    }
  }
}
