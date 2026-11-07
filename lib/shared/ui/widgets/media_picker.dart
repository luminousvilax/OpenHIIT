import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:openhiit/core/media/background_crop.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/shared/ui/widgets/image_crop_screen.dart';
import 'package:path/path.dart' as p;

Future<File?> _pickFile({required bool audio}) async {
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
  return File(path);
}

Future<String?> pickAudio() async {
  final source = await _pickFile(audio: true);
  if (source == null) return null;
  return MediaStore.instance.importFile(source, audio: true);
}

Future<String?> pickBackgroundImage(BuildContext context) async {
  // Capture the workout window ratio, rather than the editor card's dimensions.
  final portraitPixels =
      BackgroundCrop.portraitSize(MediaQuery.sizeOf(context)) *
          MediaQuery.devicePixelRatioOf(context);
  final source = await _pickFile(audio: false);
  if (source == null || !context.mounted) return null;
  final extension = p.extension(source.path).toLowerCase();
  if (!{'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
    throw const FormatException('Choose a JPEG, PNG or WebP image.');
  }
  final size = await source.length();
  if (size == 0 || size > MediaStore.maxFileBytes) {
    throw const FormatException(
        'Choose a non-empty image no larger than 20 MB.');
  }
  final bytes = await source.readAsBytes();
  if (bytes.length > MediaStore.maxFileBytes) {
    throw const FormatException('Image exceeds 20 MB.');
  }
  final image = await BackgroundCrop.decode(bytes);
  try {
    if (!context.mounted) return null;
    final route = MaterialPageRoute<Uint8List>(
      builder: (_) =>
          ImageCropScreen(image: image, portraitPixels: portraitPixels),
    );
    final result = await Navigator.of(context).push(route);
    // Keep the native image alive while the closing route is still painting.
    await route.completed;
    if (result == null || !context.mounted) return null;
    return await MediaStore.instance
        .importCroppedImage(result, name: p.basename(source.path));
  } finally {
    image.dispose();
  }
}
