import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_hiit_timer/media_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_store.dart';

void main() {
  late Directory temporary;
  late MediaStore store;
  late Set<String> saved;
  var running = false;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('openhiit-media-test-');
    saved = {};
    running = false;
    store = MediaStore(
      directory: Directory('${temporary.path}/media'),
      loadSavedReferences: () async => saved,
      isWorkoutRunning: () async => running,
    );
  });
  tearDown(() async => temporary.delete(recursive: true));

  Future<String> importWav(String name) async {
    final source = File('${temporary.path}/$name.wav');
    final bytes = Uint8List(44);
    bytes.setRange(0, 4, 'RIFF'.codeUnits);
    bytes.setRange(8, 12, 'WAVE'.codeUnits);
    await source.writeAsBytes(bytes);
    return store.importFile(source, audio: true);
  }

  test('copies selected media and survives removal of the original', () async {
    final ref = await importWav('cue');
    final original = File('${temporary.path}/cue.wav');
    final imported = await store.file(ref);
    expect(imported.path, isNot(original.path));
    expect(MediaFiles.displayName(ref), 'cue.wav');
    await original.delete();
    expect(await imported.length(), 44);
    expect(await store.scanUnused(), isEmpty,
        reason: 'A pending assignment is protected.');
    store.releasePending(ref);
    expect(await store.scanUnused(), hasLength(1));
  });

  for (final name in ['休息提示', '準備完了', 'café', 'تمرين', '训练 🎵 e\u0301']) {
    test('preserves the imported audio filename "$name"', () async {
      final reference = await importWav(name);
      expect(MediaFiles.displayName(reference), '$name.wav');
      await File('${temporary.path}/$name.wav').delete();
      // Resolve it again through the same path used by preview and playback.
      final reopened = MediaStore(directory: await store.directory);
      expect(await (await reopened.file(reference)).length(), 44);
      store.releasePending(reference);
      saved.add(reference);
      expect(await store.scanUnused(), isEmpty);
    });
  }

  test('bounds long Unicode filenames without splitting a code point',
      () async {
    final reference = await importWav(List.filled(60, '🎵').join());
    final displayed = MediaFiles.displayName(reference);
    expect(displayed, '${List.filled(50, '🎵').join()}.wav');
    expect(
        utf8.encode((await store.file(reference)).uri.pathSegments.last).length,
        lessThanOrEqualTo(255));
    expect(await (await store.file(reference)).length(), 44);
  });

  test('preserves a Unicode MP3 filename', () async {
    final source = File('${temporary.path}/运动提示.mp3');
    await source.writeAsBytes('ID3'.codeUnits);
    final reference = await store.importFile(source, audio: true);
    expect(MediaFiles.displayName(reference), '运动提示.mp3');
    expect(await (await store.file(reference)).readAsBytes(), 'ID3'.codeUnits);
  });

  test('sanitizes unsafe characters while preserving Unicode', () async {
    final reference = await importWav('训练:提示?*');
    expect(MediaFiles.displayName(reference), '训练_提示__.wav');
    expect(await (await store.file(reference)).length(), 44);
  });

  test('keeps every saved reference and deletes only unused private copies',
      () async {
    final work = await importWav('work');
    final rest = await importWav('rest');
    final orphan = await importWav('orphan');
    saved.addAll([work, rest]);
    for (final ref in [work, rest, orphan]) {
      store.releasePending(ref);
    }
    final image = File('${temporary.path}/media/images/unused.png');
    await image.parent.create();
    await image.writeAsBytes([1, 2, 3]);
    final result = await store.cleanUnused();
    expect(result.deleted, 2);
    expect(result.bytes, 47);
    expect(result.failed, 0);
    expect(await (await store.file(work)).exists(), isTrue);
    expect(await (await store.file(rest)).exists(), isTrue);
    expect(await (await store.file(orphan)).exists(), isFalse);
    expect(await File('${temporary.path}/orphan.wav').exists(), isTrue);
  });

  test('rescans saved references after the confirmation preview', () async {
    final ref = await importWav('keep-after-scan');
    store.releasePending(ref);
    expect(await store.scanUnused(), hasLength(1));
    saved.add(ref);
    expect((await store.cleanUnused()).deleted, 0);
    expect(await (await store.file(ref)).exists(), isTrue);
  });

  test('protects drafts and previews until their owners release them',
      () async {
    final ref = await importWav('draft');
    store.releasePending(ref);
    final editor = Object();
    final preview = Object();
    store.retain(editor, [ref]);
    store.retain(preview, [ref]);
    expect((await store.cleanUnused()).deleted, 0);
    store.release(editor);
    expect((await store.cleanUnused()).deleted, 0);
    store.release(preview);
    expect((await store.cleanUnused()).deleted, 1);
  });

  test('a shared file is retained until all saved timer references are gone',
      () async {
    final ref = await importWav('shared');
    store.releasePending(ref);
    final timers = <Set<String>>[
      {ref},
      {ref}
    ];
    store = MediaStore(
      directory: await store.directory,
      loadSavedReferences: () async => timers.expand((refs) => refs).toSet(),
      isWorkoutRunning: () async => false,
    );
    timers.removeAt(0);
    expect((await store.cleanUnused()).deleted, 0);
    timers.clear();
    expect((await store.cleanUnused()).deleted, 1);
  });

  test('does not delete anything when the saved reference query fails',
      () async {
    final ref = await importWav('unreadable-database');
    store.releasePending(ref);
    final broken = MediaStore(
      directory: await store.directory,
      loadSavedReferences: () async => throw StateError('Database unavailable'),
      isWorkoutRunning: () async => false,
    );
    await expectLater(broken.cleanUnused(), throwsStateError);
    expect(await (await store.file(ref)).exists(), isTrue);
  });

  test('blocks cleanup while a background workout is running', () async {
    final ref = await importWav('active-workout');
    store.releasePending(ref);
    running = true;
    await expectLater(store.cleanUnused(), throwsA(isA<MediaBusyException>()));
    expect(await (await store.file(ref)).exists(), isTrue);
  });

  test('does not follow links or visit other app files', () async {
    final outside = File('${temporary.path}/keep.wav');
    await outside.writeAsString('not managed');
    final folder = Directory('${temporary.path}/media/audio');
    await folder.create(recursive: true);
    await Link('${folder.path}/linked.wav').create(outside.path);
    final nested = File('${folder.path}/nested/keep.wav');
    await nested.parent.create();
    await nested.writeAsString('not a managed flat file');
    expect((await store.cleanUnused()).deleted, 0);
    expect(await outside.exists(), isTrue);
    expect(await nested.exists(), isTrue);
  });

  test('rejects a linked media folder rather than cleaning its target',
      () async {
    final root = await store.directory;
    await root.create(recursive: true);
    final outside = Directory('${temporary.path}/outside');
    await outside.create();
    final keep = File('${outside.path}/keep.mp3');
    await keep.writeAsString('keep');
    await Link('${root.path}/audio').create(outside.path);
    await expectLater(store.cleanUnused(), throwsA(isA<FileSystemException>()));
    expect(await keep.exists(), isTrue);
  });

  test('rejects invalid audio without creating a private copy', () async {
    final source = File('${temporary.path}/bad.mp3');
    await source.writeAsString('not an mp3');
    await expectLater(
        store.importFile(source, audio: true), throwsFormatException);
    expect(await store.scanUnused(), isEmpty);
  });

  test('imports and decodes an image before assigning a persistent reference',
      () async {
    final source = File('${temporary.path}/background.png');
    await source.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNQSJgARAwQCgAcDgRBIqsFewAAAABJRU5ErkJggg=='));
    final reference = await store.importFile(source, audio: false);
    expect(reference, startsWith('local:images/'));
    await source.delete();
    expect(await (await store.file(reference)).exists(), isTrue);
  });

  test('rejects images that cannot be decoded without leaving a managed file',
      () async {
    final source = File('${temporary.path}/bad.png');
    await source.writeAsString('not an image');
    await expectLater(
        store.importFile(source, audio: false), throwsA(anything));
    expect(await store.scanUnused(), isEmpty);
  });

  test('cropped PNG keeps its display policy, name, and cleanup protection',
      () async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNQSJgARAwQCgAcDgRBIqsFewAAAABJRU5ErkJggg==');
    final reference = await store.importCroppedImage(bytes, name: '训练背景.webp');
    expect(MediaFiles.isCroppedImage(reference), isTrue);
    expect(MediaFiles.displayName(reference), '训练背景.png');
    expect(await (await store.file(reference)).readAsBytes(), bytes);
    expect(await store.scanUnused(), isEmpty);
    store.releasePending(reference);
    saved.add(reference);
    expect(await store.scanUnused(), isEmpty);
    saved.clear();
    expect((await store.cleanUnused()).deleted, 1);
    expect(await (await store.file(reference)).exists(), isFalse);
    expect(
        MediaFiles.isCroppedImage('local:images/uuid_crop1-name.png'), isFalse);
  });

  test('invalid cropped bytes create no managed file', () async {
    await expectLater(
        store.importCroppedImage(Uint8List.fromList([1, 2, 3]),
            name: 'bad.png'),
        throwsA(anything));
    expect(await store.scanUnused(), isEmpty);
  });

  test('rejects empty files and files exceeding the import limit', () async {
    final source = File('${temporary.path}/large.wav');
    final handle = await source.open(mode: FileMode.write);
    await expectLater(
        store.importFile(source, audio: true), throwsFormatException);
    await handle.truncate(MediaStore.maxFileBytes + 1);
    await handle.close();
    await expectLater(
        store.importFile(source, audio: true), throwsFormatException);
    expect(await store.scanUnused(), isEmpty);
  });

  test('rejects traversal and absolute media references', () async {
    for (final reference in [
      'local:audio/../../keep.wav',
      'local:/tmp/keep.wav',
      'local:audio/..',
      r'local:audio/..\keep.wav',
      'local:audio/id_训练/keep.wav',
      r'local:audio/id_训练\keep.wav',
      'local:audio/id_训练\u0000.wav',
      'local:audio/id_训练\n.wav',
      'local:audio/id_训练.wav\n',
      'local:audio/id_训练:keep.wav',
      'local:other/训练.wav',
    ]) {
      await expectLater(store.file(reference), throwsFormatException);
    }
  });

  test('serializes cleanup with a pending configuration save', () async {
    final ref = await importWav('save-in-progress');
    store.releasePending(ref);
    final save = store.exclusive(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      saved.add(ref);
    });
    final cleanup = store.cleanUnused();
    await save;
    expect((await cleanup).deleted, 0);
  });
}
