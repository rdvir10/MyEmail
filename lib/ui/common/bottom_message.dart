/// How long a message along the bottom of the screen stays.
///
/// Flutter's default is four seconds, which is not quite enough to read a
/// sentence and reach for Undo. Five is, and one number in one place means
/// every message in the app behaves the same rather than each one being
/// whatever its author happened to leave.
///
/// A message with a button (Undo) needs `persist: false` beside it as well.
/// Flutter keeps such a message until it is dismissed otherwise, so
/// "Deleted — Undo" sat over the list for good, and a stray tap an hour
/// later put the message back.
const kBottomMessage = Duration(seconds: 5);
