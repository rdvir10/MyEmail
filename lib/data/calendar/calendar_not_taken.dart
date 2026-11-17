import '../mail_engine.dart' show ConnectionFailed;

/// A calendar's answer that certainly did nothing: a refusal (an HTTP 4xx
/// other than the sign-in's and "gone"), or a throttle (429) that turned
/// the request away before it was carried out. Thrown by both calendars'
/// readings of a failed answer.
///
/// Still a [ConnectionFailed] for every caller that read it as one, and
/// read the same: try again later. What tells it apart is that an answer
/// came. I am away (calendar idea #53) says "Did not go" with its reason
/// for one, and keeps "May have gone" for a request that got no answer at
/// all, or a server in trouble (a 5xx), after which it may have been
/// carried out.
class CalendarNotTaken extends ConnectionFailed {
  const CalendarNotTaken(super.message);
}
