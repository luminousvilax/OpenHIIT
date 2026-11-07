import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:background_hiit_timer/background_timer.dart';
import 'package:background_hiit_timer/media_files.dart';
import 'package:openhiit/core/db/repositories/timer_repository.dart';
import 'package:openhiit/core/models/timer_sound_settings.dart';
import 'package:openhiit/core/models/timer_type.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class CleanupItem {
  const CleanupItem(this.reference, this.file, this.bytes);
  final String reference;
  final File file;
  final int bytes;
}

class CleanupResult {
  const CleanupResult(this.deleted, this.bytes, this.failed);
  final int deleted;
  final int bytes;
  final int failed;
}

class MediaBusyException implements Exception {
  const MediaBusyException();
  @override
  String toString() => 'Finish your workout before cleaning unused media.';
}

/// Owns imported files. All media imports, timer writes and cleanup use one queue.
class MediaStore {
  MediaStore({
    Directory? directory,
    Future<Set<String>> Function()? loadSavedReferences,
    Future<bool> Function()? isWorkoutRunning,
    Future<void> Function(Uint8List)? validateImage,
  })  : _directory = directory,
        _loadSavedReferences = loadSavedReferences ?? _savedReferences,
        _isWorkoutRunning = isWorkoutRunning ?? Countdown.isServiceRunning,
        _validateImage = validateImage ?? _decodeImage;

  static MediaStore instance = MediaStore();
  static const maxFileBytes = 20 * 1024 * 1024;
  final Directory? _directory;
  final Future<Set<String>> Function() _loadSavedReferences;
  final Future<bool> Function() _isWorkoutRunning;
  final Future<void> Function(Uint8List) _validateImage;
  final Map<Object, Set<String>> _leases = {};
  final Set<String> _pending = {};
  Future<void> _tail = Future.value();

  static Set<String> referencesFor(TimerType timer) => {
        ...timer.backgrounds.values.where(MediaFiles.isLocal),
        for (final key in TimerSoundSettings.defaults.keys)
          if (MediaFiles.isLocal(timer.soundSettings.toMap()[key] as String))
            timer.soundSettings.toMap()[key] as String,
      };

  static Future<Set<String>> _savedReferences() async => {
        for (final timer in await TimerRepository().getAllTimers())
          ...referencesFor(timer),
      };

  Future<Directory> get directory async =>
      _directory ?? await MediaFiles.root();

  void retain(Object owner, Iterable<String> references) {
    _leases[owner] = references.where(MediaFiles.isLocal).toSet();
  }

  void release(Object owner) => _leases.remove(owner);
  void releasePending(String reference) => _pending.remove(reference);

  Set<String> get _liveReferences => {
        ..._pending,
        for (final references in _leases.values) ...references,
      };

  Future<T> exclusive<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<File> file(String reference) async =>
      MediaFiles.file(reference, directory: await directory);

  Future<String?> audioIssue(String reference) async {
    if (!MediaFiles.isLocal(reference)) return null;
    try {
      if (!await (await file(reference)).exists()) {
        return 'Audio file is missing. Choose another file.';
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      return preferences.getString(MediaFiles.failureKey(reference));
    } catch (_) {
      return 'Audio file is unavailable. Choose another file.';
    }
  }

  Future<String> importFile(File source, {required bool audio}) =>
      exclusive(() async {
        final extension = p.extension(source.path).toLowerCase();
        final allowed =
            audio ? {'.mp3', '.wav'} : {'.jpg', '.jpeg', '.png', '.webp'};
        if (!allowed.contains(extension)) {
          throw FormatException(audio
              ? 'Choose an MP3 or WAV file.'
              : 'Choose a JPEG, PNG or WebP image.');
        }
        final size = await source.length();
        if (size == 0 || size > maxFileBytes) {
          throw const FormatException(
              'Choose a non-empty file no larger than 20 MB.');
        }
        final bytes = await source.readAsBytes();
        if (bytes.length > maxFileBytes) {
          throw const FormatException('File exceeds 20 MB.');
        }
        if (audio) {
          final mp3 = bytes.length >= 3 &&
              ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
                  (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0));
          final wav = bytes.length >= 12 &&
              String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
              String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE';
          if (!(extension == '.mp3' ? mp3 : wav)) {
            throw const FormatException(
                'The file does not contain the selected audio format.');
          }
        } else {
          await _validateImage(bytes);
        }
        var name = p
            .basenameWithoutExtension(source.path)
            .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_');
        if (name.isEmpty) name = audio ? 'audio' : 'image';
        final limitedName = StringBuffer();
        var nameBytes = 0;
        // Leave room for the UUID, extension and temporary .part suffix within
        // a 255-byte filename, without splitting Unicode code points.
        for (final rune in name.runes.take(80)) {
          final character = String.fromCharCode(rune);
          final bytes = utf8.encode(character).length;
          if (nameBytes + bytes > 200) break;
          limitedName.write(character);
          nameBytes += bytes;
        }
        name = limitedName.toString();
        final reference =
            'local:${audio ? 'audio' : 'images'}/${const Uuid().v4()}_$name$extension';
        final target = await file(reference);
        await target.parent.create(recursive: true);
        final temporary = File('${target.path}.part');
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(target.path);
          _pending.add(reference);
          return reference;
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      });

  static Future<void> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes,
        targetWidth: 256, targetHeight: 256, allowUpscaling: false);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<List<CleanupItem>> scanUnused() => exclusive(_scanUnused);

  Future<List<CleanupItem>> _scanUnused() async {
    if (await _isWorkoutRunning()) throw const MediaBusyException();
    // A repository failure aborts cleanup; an empty UI timer list is not evidence.
    final used = {...await _loadSavedReferences(), ..._liveReferences};
    final root = await directory;
    final candidates = <CleanupItem>[];
    for (final kind in ['audio', 'images']) {
      // Resolve a safe sentinel to reject linked roots or media folders.
      await MediaFiles.file('local:$kind/sentinel', directory: root);
      final folder = Directory(p.join(root.path, kind));
      if (!await folder.exists()) continue;
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is! File) continue;
        final reference = 'local:$kind/${p.basename(entity.path)}';
        if (!used.contains(reference)) {
          candidates.add(CleanupItem(reference, entity, await entity.length()));
        }
      }
    }
    return candidates;
  }

  /// Always rescans after confirmation; the dialog's counts are only estimates.
  Future<CleanupResult> cleanUnused() => exclusive(() async {
        final candidates = await _scanUnused();
        var deleted = 0;
        var bytes = 0;
        var failed = 0;
        for (final item in candidates) {
          if (_liveReferences.contains(item.reference)) continue;
          try {
            if (await FileSystemEntity.type(item.file.path,
                    followLinks: false) !=
                FileSystemEntityType.file) {
              continue;
            }
            await item.file.delete();
            deleted++;
            bytes += item.bytes;
          } on FileSystemException {
            failed++;
          }
        }
        return CleanupResult(deleted, bytes, failed);
      });
}
