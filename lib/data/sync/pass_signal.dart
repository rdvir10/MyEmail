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
