import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../domain/mail_attachment.dart';

/// Saving an attachment somewhere it will still be tomorrow.
///
/// The downloaded copy lives in the cache, which Android may clear whenever
/// it wants the space. This puts it where the person chooses, through the
/// system file picker, which is also the only way to write outside the app
/// without asking for storage permission.
Future<bool> saveAttachmentAs(MailAttachment attachment, File file) async {
  final uri = await FilePicker.saveFile(
    fileName: safeFileName(attachment.name),
    bytes: await file.readAsBytes(),
    mimeType: attachment.openAs,
    dialogTitle: 'Save attachment',
  );
  return uri != null;
}
