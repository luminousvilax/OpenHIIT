import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/shared/ui/widgets/media_picker.dart';
import '../helpers/media_browser_channel.dart';

void main() {
  late Directory temporary;
  late MediaStore originalStore;
  File? selected;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('openhiit-picker-test-');
    originalStore = MediaStore.instance;
    MediaStore.instance = MediaStore(
        directory: Directory('${temporary.path}/media'),
        loadSavedReferences: () async => {},
        isWorkoutRunning: () async => false);
    selected = null;
    mockBrowserSelection(audio: true, select: () async => selected?.path);
  });

  tearDown(() async {
    clearBrowserChannel();
    MediaStore.instance = originalStore;
    await temporary.delete(recursive: true);
  });

  Future<File> source(List<int> bytes) async {
    final cache = await temporary.createTemp('native-cache-');
    return File('${cache.path}/声音.mp3').writeAsBytes(bytes);
  }

  Future<String?> choose(WidgetTester tester, {bool cancel = false}) async {
    String? result;
    Object? error;
    bool done = false;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        try {
                          result = await pickAudio(context);
                        } catch (e) {
                          error = e;
                        }
                        done = true;
                      },
                      child: const Text('Choose')),
                ))));
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(cancel ? find.byTooltip('Close') : find.text('声音.mp3'));
    for (var i = 0; i < 80 && !done; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpAndSettle();
    }
    expect(done, isTrue);
    if (error != null) throw error!;
    return result;
  }

  testWidgets('Android selection imports browser cache and removes it',
      (tester) async {
    selected = await tester.runAsync(() => source([0x49, 0x44, 0x33, 1]));
    final reference = await choose(tester);
    expect(reference, startsWith('local:audio/'));
    final imported =
        await tester.runAsync(() => MediaStore.instance.file(reference!));
    expect(await tester.runAsync(() => imported!.readAsBytes()),
        [0x49, 0x44, 0x33, 1]);
    expect(imported!.path, contains('声音.mp3'));
    expect(await tester.runAsync(() => selected!.parent.exists()), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('invalid audio preserves previous media and removes native cache',
      (tester) async {
    selected = await tester.runAsync(() => source([0x49, 0x44, 0x33, 1]));
    final previous = await choose(tester);
    selected = await tester.runAsync(() => source([1, 2, 3]));
    Object? failure;
    try {
      await choose(tester);
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<FormatException>());
    expect(await tester.runAsync(() => selected!.parent.exists()), isFalse);
    expect(
        await tester.runAsync(
            () async => (await MediaStore.instance.file(previous!)).exists()),
        isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('closing browser returns no assignment and writes no media',
      (tester) async {
    expect(await choose(tester, cancel: true), isNull);
    expect(
        await tester
            .runAsync(() => Directory('${temporary.path}/media').exists()),
        isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
