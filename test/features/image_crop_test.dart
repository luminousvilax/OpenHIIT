import 'dart:io';
import 'dart:typed_data';

import 'package:background_hiit_timer/media_files.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/background_crop.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/start_save_toggle.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/tabs/background_tab/background_tab.dart';
import 'package:openhiit/shared/ui/widgets/image_crop_screen.dart';
import 'package:openhiit/shared/ui/widgets/media_browser_screen.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';
import 'package:provider/provider.dart';

import '../helpers/crop_image.dart';
import '../helpers/media_browser_channel.dart';

class _Picker extends FilePicker {
  _Picker(this.source);
  File? source;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (source == null) return null;
    return FilePickerResult([
      PlatformFile(
          name: '背景.png', path: source!.path, size: await source!.length())
    ]);
  }
}

// Flush real filesystem/codec work as well as route animations. The condition
// makes slow CI fail with a useful assertion instead of relying on a fixed wait.
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
  }
  expect(ready(), isTrue);
}

void main() {
  late Directory temporary;
  late MediaStore originalStore;
  late _Picker picker;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('openhiit-crop-test-');
    final image = await stripedImage();
    try {
      final source = File('${temporary.path}/背景.png');
      await source.writeAsBytes(await imagePng(image));
      picker = _Picker(source);
    } finally {
      image.dispose();
    }
    FilePicker.platform = picker;
    originalStore = MediaStore.instance;
    MediaStore.instance = MediaStore(
      directory: Directory('${temporary.path}/media'),
      loadSavedReferences: () async => {},
      isWorkoutRunning: () async => false,
    );
  });

  tearDown(() async {
    MediaStore.instance = originalStore;
    PaintingBinding.instance.imageCache.clear();
    await temporary.delete(recursive: true);
  });

  Future<TimerCreationProvider> showBackgrounds(WidgetTester tester,
      {ValueChanged<StartSaveState>? onEdited}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final draft = TimerCreationProvider()..clear();
    draft.setBackground('getReady', 'local:images/existing.png');
    draft.setBackground('work', 'local:images/other.png');
    final controller = ScrollController();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: draft,
      child: MaterialApp(
          home: Scaffold(
              body: BackgroundTab(
        onEdited: onEdited ?? (_) {},
        scrollController: controller,
      ))),
    ));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      draft.dispose();
    });
    return draft;
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.runAsync(() =>
        tester.tap(find.byKey(const ValueKey('background-getReady-choose'))));
    await tester.pumpAndSettle();
    if (find.byType(MediaBrowserScreen).evaluate().isNotEmpty) {
      await tester.runAsync(() => tester.tap(find.text('背景.png')));
    }
    await _until(
        tester, () => find.byType(ImageCropScreen).evaluate().isNotEmpty);
  }

  testWidgets(
      'Android image selection uses the browser and removes cache after crop cancel',
      (tester) async {
    late File cached;
    mockBrowserSelection(
        audio: false,
        select: () async {
          final cache = await temporary.createTemp('picker-cache-');
          cached = await picker.source!.copy('${cache.path}/背景.png');
          return cached.path;
        });
    addTearDown(clearBrowserChannel);
    final draft = await showBackgrounds(tester);
    await choose(tester);
    expect(await tester.runAsync(() => cached.exists()), isTrue);
    await tester.tap(find.byTooltip('Cancel'));
    await _until(tester, () {
      final choose = find.byKey(const ValueKey('background-getReady-choose'));
      return choose.evaluate().isNotEmpty &&
          tester.widget<TextButton>(choose).onPressed != null;
    });
    expect(await tester.runAsync(() => cached.parent.exists()), isFalse);
    expect(await tester.runAsync(() => picker.source!.exists()), isTrue);
    expect(draft.timer.backgrounds['getReady'], 'local:images/existing.png');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'canceling picker or crop preserves assignments and writes no files',
      (tester) async {
    var edits = 0;
    final draft = await showBackgrounds(tester, onEdited: (_) => edits++);
    final source = picker.source;
    picker.source = null;
    await tester.runAsync(() =>
        tester.tap(find.byKey(const ValueKey('background-getReady-choose'))));
    await tester.pumpAndSettle();
    expect(find.byType(ImageCropScreen), findsNothing);
    picker.source = source;
    await choose(tester);
    expect(
        find.byKey(const ValueKey('crop-resolution-warning')), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await _until(tester, () {
      final choose = find.byKey(const ValueKey('background-getReady-choose'));
      return choose.evaluate().isNotEmpty &&
          tester.widget<TextButton>(choose).onPressed != null;
    });
    expect(draft.timer.backgrounds['getReady'], 'local:images/existing.png');
    expect(draft.timer.backgrounds['work'], 'local:images/other.png');
    expect(edits, 0);
    expect(
        await tester.runAsync(() => MediaStore.instance.scanUnused()), isEmpty);
    expect(
        await tester
            .runAsync(() => Directory('${temporary.path}/media').exists()),
        isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
      'dragged low-resolution crop applies and only the result is stored',
      (tester) async {
    var edits = 0;
    final draft = await showBackgrounds(tester, onEdited: (state) {
      expect(state, StartSaveState.save);
      edits++;
    });
    await choose(tester);
    final viewport = find.byKey(const ValueKey('crop-viewport'));
    final size = tester.getSize(viewport);
    expect(size.aspectRatio, closeTo(0.5, 1e-6));
    await tester.drag(viewport, Offset(-size.width * 2, 0));
    await tester
        .runAsync(() => tester.tap(find.byKey(const ValueKey('crop-apply'))));
    await _until(tester,
        () => MediaFiles.isCroppedImage(draft.timer.backgrounds['getReady']!));
    expect(edits, 1);
    expect(draft.timer.backgrounds['work'], 'local:images/other.png');
    final reference = draft.timer.backgrounds['getReady']!;
    final image = await tester.runAsync(() async {
      final file = await MediaStore.instance.file(reference);
      return BackgroundCrop.decode(await file.readAsBytes());
    });
    expect(image!.width, 40);
    expect(image.height, 80);
    expect(await tester.runAsync(() => centerPixel(image)), [0, 0, 255, 255]);
    image.dispose();
    expect(
        await tester.runAsync(
            () => Directory('${temporary.path}/media/images').list().toList()),
        hasLength(1));
    expect(await tester.runAsync(() => picker.source!.exists()), isTrue);
    expect(MediaFiles.displayName(reference), '背景.png');
    // The editor card fills its wide preview with a centered detail of the crop.
    await _until(
        tester,
        () => find
            .descendant(
                of: find.byType(ManagedBackground).first,
                matching: find.byType(Image))
            .evaluate()
            .isNotEmpty);
    expect(
        tester
            .widget<Image>(find.descendant(
                of: find.byType(ManagedBackground).first,
                matching: find.byType(Image)))
            .fit,
        BoxFit.cover);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
      'pinch zooms, rotation preserves crop ratio, and Reset restores it',
      (tester) async {
    final draft = await showBackgrounds(tester);
    await choose(tester);
    final viewport = find.byKey(const ValueKey('crop-viewport'));
    final center = tester.getCenter(viewport);
    final first =
        await tester.startGesture(center - const Offset(15, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(15, 0), pointer: 2);
    for (var i = 1; i <= 4; i++) {
      await first.moveTo(center - Offset(15 + i * 10, 0));
      await second.moveTo(center + Offset(15 + i * 10, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    // Export the zoomed crop before testing Reset in a new selection.
    await tester
        .runAsync(() => tester.tap(find.byKey(const ValueKey('crop-apply'))));
    await _until(tester,
        () => MediaFiles.isCroppedImage(draft.timer.backgrounds['getReady']!));
    final result = await tester.runAsync(() async {
      final file =
          await MediaStore.instance.file(draft.timer.backgrounds['getReady']!);
      return BackgroundCrop.decode(await file.readAsBytes());
    });
    expect(result!.width, lessThan(40));
    expect(result.height, lessThan(80));
    result.dispose();
    final before = draft.timer.backgrounds['getReady'];
    await choose(tester);
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).aspectRatio, closeTo(0.5, 1e-6));
    await tester.drag(viewport, const Offset(-200, 0));
    await tester.tap(find.text('Reset'));
    await tester
        .runAsync(() => tester.tap(find.byKey(const ValueKey('crop-apply'))));
    await _until(tester, () => draft.timer.backgrounds['getReady'] != before);
    final reset = await tester.runAsync(() async {
      final file =
          await MediaStore.instance.file(draft.timer.backgrounds['getReady']!);
      return BackgroundCrop.decode(await file.readAsBytes());
    });
    expect(reset!.width, 40);
    expect(reset.height, 80);
    expect(await tester.runAsync(() => centerPixel(reset)), [0, 255, 0, 255]);
    reset.dispose();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('failed image decode preserves previous assignment',
      (tester) async {
    final draft = await showBackgrounds(tester);
    await tester.runAsync(
        () => picker.source!.writeAsBytes(Uint8List.fromList([1, 2, 3])));
    await tester.runAsync(() =>
        tester.tap(find.byKey(const ValueKey('background-getReady-choose'))));
    await _until(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    expect(find.byType(ImageCropScreen), findsNothing);
    expect(draft.timer.backgrounds['getReady'], 'local:images/existing.png');
    expect(
        await tester.runAsync(() => MediaStore.instance.scanUnused()), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
