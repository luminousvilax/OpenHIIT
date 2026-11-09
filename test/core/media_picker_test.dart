import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/shared/ui/widgets/media_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('openhiit/media_picker');
  late Directory temporary;
  late MediaStore originalStore;
  File? selected;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    temporary = await Directory.systemTemp.createTemp('openhiit-picker-test-');
    originalStore = MediaStore.instance;
    MediaStore.instance = MediaStore(
      directory: Directory('${temporary.path}/media'),
      loadSavedReferences: () async => {},
      isWorkoutRunning: () async => false,
    );
    selected = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickFile');
      expect(call.arguments, {'audio': true});
      return selected?.path;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    MediaStore.instance = originalStore;
    await temporary.delete(recursive: true);
  });

  Future<File> source(List<int> bytes) async {
    final cache = await temporary.createTemp('native-cache-');
    return File('${cache.path}/声音.mp3').writeAsBytes(bytes);
  }

  test('Android audio selection imports native cache and removes it', () async {
    selected = await source([0x49, 0x44, 0x33, 1]);
    final reference = await pickAudio();
    expect(reference, startsWith('local:audio/'));
    final imported = await MediaStore.instance.file(reference!);
    expect(await imported.readAsBytes(), [0x49, 0x44, 0x33, 1]);
    expect(imported.path, contains('声音.mp3'));
    expect(await selected!.parent.exists(), isFalse);
  });

  test('invalid audio preserves stored media and removes the native cache',
      () async {
    selected = await source([0x49, 0x44, 0x33, 1]);
    final previous = await pickAudio();
    selected = await source([1, 2, 3]);
    await expectLater(pickAudio(), throwsFormatException);
    expect(await selected!.parent.exists(), isFalse);
    expect(await (await MediaStore.instance.file(previous!)).exists(), isTrue);
  });

  test('canceling native selection returns no assignment and writes no media',
      () async {
    expect(await pickAudio(), isNull);
    expect(await Directory('${temporary.path}/media').exists(), isFalse);
  });
}
