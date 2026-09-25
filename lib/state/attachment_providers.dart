import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/files/attachment_files.dart';
import '../data/files/file_bridge.dart';
import '../data/ui_state_store.dart';
import '../domain/html_safety.dart';
import '../domain/mail_attachment.dart';
import 'message_providers.dart';
import 'providers.dart';

/// Opening, saving and carrying attachments about. main() overrides both on
/// a device; everywhere else they record instead of touching the platform.
final fileBridgeProvider = Provider<FileBridge>((ref) => FakeFileBridge());

final attachmentFilesProvider =
    Provider<AttachmentFiles>((ref) => MemoryAttachmentFiles());

/// What is attached to one message.
///
/// Separate from the body: a list of names and sizes costs one small request
/// and arrives while the body is still coming, and a message whose
/// attachments cannot be listed is still a message worth reading.
final attachmentsProvider =
    FutureProvider.family<List<MailAttachment>, String>((ref, messageId) async {
  return ref.watch(mailEngineProvider).listAttachments(messageId);
});

/// The pictures a message's HTML names by Content-ID, as data: URIs keyed
/// by Content-ID in lower case, for [withInlinePictures] to put in place.
///
/// Fetched only for a message that names one (see [watchInlinePictures]),
/// and only up to [maxInlinePictureBytes] between them: past that, the rest
/// stay chips. A picture that cannot be fetched is left out; the body is
/// still worth reading without it.
final inlinePicturesProvider =
    FutureProvider.family<Map<String, String>, String>((ref, messageId) async {
  final attachments = await ref.watch(attachmentsProvider(messageId).future);
  final engine = ref.watch(mailEngineProvider);
  final pictures = <String, String>{};
  var room = maxInlinePictureBytes;
  for (final a in attachments) {
    final contentId = a.contentId?.toLowerCase();
    if (contentId == null || pictures.containsKey(contentId)) continue;
    // The bare type: a declared "image/png; name=logo.png" put whole into
    // a data: link makes a link no WebView can read.
    final declared = a.mimeType.toLowerCase().split(';').first.trim();
    final type = declared.startsWith('image/') ? declared : a.openAs;
    if (!type.startsWith('image/') || a.sizeBytes > room) continue;
    try {
      final bytes = await engine.fetchAttachment(messageId, a.id);
      if (bytes.length > room) continue;
      room -= bytes.length;
      pictures[contentId] = 'data:$type;base64,${base64Encode(bytes)}';
    } catch (e) {
      // Shown as a chip, as before.
      debugPrint('[myemail] inline picture ${a.name} not fetched: $e');
    }
  }
  debugPrint('[myemail] inline pictures: ${pictures.length} of '
      '${attachments.where((a) => a.contentId != null).length} named, '
      '${attachments.length} attached');
  return pictures;
});

/// More than a screenful of screenshots; not a message's worth of photos.
const maxInlinePictureBytes = 15 * 1024 * 1024;

/// Whether the files under a message are folded to their one-line count.
///
/// Remembered, and for every message alike: someone who folds them away
/// wants the room on the next message too, and the count line still says
/// there is something there, so nothing is missed by it.
class AttachmentsFolded extends Notifier<bool> {
  @override
  bool build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.attachmentsFolded,
          next ? 'folded' : 'open',
        ));
    return store.readString(UiStateKeys.attachmentsFolded) == 'folded';
  }

  void toggle() => state = !state;
}

final attachmentsFoldedProvider =
    NotifierProvider<AttachmentsFolded, bool>(AttachmentsFolded.new);

/// The attachments a message's body is already showing: pictures it names
/// by Content-ID that have arrived and been put in place. They are part of
/// the message, and a chip for each (a signature's logo, its icons) was a
/// row of "image.png" above every letter from some senders.
///
/// Held back while the pictures are on their way, so chips do not flash up
/// and vanish; given back for any that could not be fetched, so a picture
/// the body cannot show can still be opened.
Set<String> attachmentsShownInBody(
  WidgetRef ref,
  String messageId,
  List<MailAttachment> attachments,
) {
  // Only a body something is already showing. The reading pane asks for it
  // before it builds this bar; on its own, the bar is no reason to fetch one.
  final body = messageBodyProvider(messageId);
  if (!ref.exists(body)) return const {};
  final html = ref.watch(body).value?.html;
  if (html == null || !namesInlinePictures(html)) return const {};
  final lower = html.toLowerCase();
  final named = {
    for (final a in attachments)
      if (a.contentId case final id?)
        if (lower.contains('cid:${id.toLowerCase()}')) a.id: id.toLowerCase(),
  };
  if (named.isEmpty) return const {};
  return ref.watch(inlinePicturesProvider(messageId)).when(
        loading: () => named.keys.toSet(),
        error: (_, _) => const {},
        data: (pictures) => {
          for (final MapEntry(key: attachmentId, value: contentId)
              in named.entries)
            if (pictures.containsKey(contentId)) attachmentId,
        },
      );
}

/// The pictures [html] names by Content-ID, once they are here: none while
/// they are coming, and none asked for when it names none.
Map<String, String> watchInlinePictures(
  WidgetRef ref,
  String messageId,
  String html,
) =>
    namesInlinePictures(html)
        ? ref.watch(inlinePicturesProvider(messageId)).value ?? const {}
        : const {};

/// One attachment on its way to the disk.
///
/// Downloading is deliberately not part of [attachmentsProvider]: opening a
/// message should not pull down a 12MB slide deck, and two taps on the same
/// file should not fetch it twice.
class AttachmentDownloads extends Notifier<Map<String, AttachmentState>> {
  @override
  Map<String, AttachmentState> build() => const {};

  static String keyFor(String messageId, MailAttachment a) =>
      '$messageId/${a.id}';

  AttachmentState stateOf(String messageId, MailAttachment a) =>
      state[keyFor(messageId, a)] ?? const AttachmentState.idle();

  /// The file, downloading it first if this is the first time it is asked
  /// for. Returns null if it could not be fetched.
  Future<File?> file(String messageId, MailAttachment attachment) async {
    final key = keyFor(messageId, attachment);
    if (state[key]?.isWorking ?? false) return null;

    // Asked of the disk every time, not only the first. The copy is in the
    // cache, which Android clears when it wants the space, so a file
    // remembered from an hour ago may be gone, and Save as then failed on
    // it without a word.
    final files = ref.read(attachmentFilesProvider);
    final cached = await files.cached(messageId, attachment);
    if (cached != null) {
      if (state[key]?.file?.path != cached.path) {
        state = {...state, key: AttachmentState.ready(cached)};
      }
      return cached;
    }

    state = {...state, key: const AttachmentState.working()};
    try {
      final bytes = await ref
          .read(mailEngineProvider)
          .fetchAttachment(messageId, attachment.id);
      final file = await files.write(messageId, attachment, bytes);
      state = {...state, key: AttachmentState.ready(file)};
      return file;
    } catch (e) {
      state = {...state, key: AttachmentState.failed('$e')};
      return null;
    }
  }
}

final attachmentDownloadsProvider =
    NotifierProvider<AttachmentDownloads, Map<String, AttachmentState>>(
  AttachmentDownloads.new,
);

/// Where one attachment has got to.
class AttachmentState {
  const AttachmentState.idle()
      : file = null,
        isWorking = false,
        error = null;
  const AttachmentState.working()
      : file = null,
        isWorking = true,
        error = null;
  const AttachmentState.ready(this.file)
      : isWorking = false,
        error = null;
  const AttachmentState.failed(this.error)
      : file = null,
        isWorking = false;

  final File? file;
  final bool isWorking;
  final String? error;
}
