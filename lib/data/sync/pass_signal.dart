import 'dart:ui' show IsolateNameServer;

/// Where a background pass says it is done, for the app to hear if it is
/// running.
///
/// The pass runs in the worker's own isolate and writes new mail into the
/// database the app's lists read from, but a list already on screen held
/// what it read last and knew nothing of it: Ron saw the notification, and
/// the open Inbox without the message, until he left the app and came back.
/// The worker is in the app's process, so a port registered by name
/// reaches it, as the notification buttons' does.
const backgroundPassDonePortName = 'myemail.sync.pass-done';

/// Tell the app, if it is open, that a pass has written what it found.
void announceBackgroundPassDone() {
  IsolateNameServer.lookupPortByName(backgroundPassDonePortName)?.send(null);
}

/// Where a background pass says it has read accounts' calendars again for
/// their meeting mail, for the calendar screens the app has open to show
/// what it kept (calendar idea #74). Said after the read, which comes after
/// the pass has said it is done.
const calendarReadAgainPortName = 'myemail.calendar.read-again';

/// Tell the app, if it is open, that [accountIds]' calendars were read
/// again for their meeting mail, and what was found is kept.
void announceCalendarReadAgain(Iterable<String> accountIds) {
  IsolateNameServer.lookupPortByName(calendarReadAgainPortName)
      ?.send([...accountIds]);
}
