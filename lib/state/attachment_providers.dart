import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/files/attachment_files.dart';
import '../data/files/file_bridge.dart';
import '../domain/html_safety.dart';
import '../domain/mail_attachment.dart';
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
    final type = a.mimeType.toLowerCase().startsWith('image/')
        ? a.mimeType.toLowerCase()
        : a.openAs;
    if (!type.startsWith('image/') || a.sizeBytes > room) continue;
    try {
      final bytes = await engine.fetchAttachment(messageId, a.id);
      if (bytes.length > room) continue;
      room -= bytes.length;
      pictures[contentId] = 'data:$type;base64,${base64Encode(bytes)}';
    } catch (_) {
      // Shown as a chip, as before.
    }
  }
  return pictures;
});

/// More than a screenful of screenshots; not a message's worth of photos.
const maxInlinePictureBytes = 15 * 1024 * 1024;

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
    final already = state[key];
    if (already?.file != null) return already!.file;
    if (already?.isWorking ?? false) return null;

    final files = ref.read(attachmentFilesProvider);
    final cached = await files.cached(messageId, attachment);
    if (cached != null) {
      state = {...state, key: AttachmentState.ready(cached)};
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
