import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:openhiit/core/media/media_store.dart';

Future<String?> pickMedia({required bool audio}) async {
  final selection = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: audio ? ['mp3', 'wav'] : ['jpg', 'jpeg', 'png', 'webp'],
    withData: false,
  );
  if (selection == null) return null;
  final path = selection.files.single.path;
  if (path == null) {
    throw const FormatException(
        'Unable to read this file. Choose a local file.');
  }
  return MediaStore.instance.importFile(File(path), audio: audio);
}
