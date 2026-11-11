import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:background_hiit_timer/media_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openhiit/core/media/background_crop.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/core/media/media_browser.dart';
import 'package:openhiit/core/providers/interval_provider/interval_provider.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/core/providers/timer_provider/timer_provider.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/tabs/background_tab/background_tab.dart';
import 'package:openhiit/shared/ui/widgets/image_crop_screen.dart';
import 'package:openhiit/shared/ui/widgets/media_browser_screen.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late TimerProvider timers;
  late TimerCreationProvider draft;
  late String legacy;
  final lease = Object();

  void retain() =>
      MediaStore.instance.retain(lease, MediaStore.referencesFor(draft.timer));

  setUpAll(() async {
    final info = await PackageInfo.fromPlatform();
    if (info.packageName != 'com.codepup.workout_timer.media_test') {
      throw StateError('Run through tool/test_android_media.py --crop.');
    }
    debugPrint(
        '[CROP-TEST] APP ${info.version}+${info.buildNumber} ${info.packageName}');
    GoogleFonts.config.allowRuntimeFetching = false;
    await WakelockPlus.enable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    final source = File('${(await getTemporaryDirectory()).path}/legacy.png');
    await source.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNQSJgARAwQCgAcDgRBIqsFewAAAABJRU5ErkJggg=='));
    legacy = await MediaStore.instance.importFile(source, audio: false);
    await source.delete();
    timers = TimerProvider()..setIntervalProvider(IntervalProvider());
    await timers.loadTimers();
    draft = TimerCreationProvider()..clear();
    draft.setTimerName('Image crop device fixture');
    draft.setBackground('getReady', legacy);
    draft.setBackground('work', legacy);
    draft.addListener(retain);
    retain();
    await timers.pushTimer(draft.timer);
    MediaStore.instance.releasePending(legacy);
  });

  tearDownAll(() async {
    draft.removeListener(retain);
    MediaStore.instance.release(lease);
    await timers.deleteTimer(draft.timer);
    timers.dispose();
    draft.dispose();
    await SystemChrome.setPreferredOrientations([]);
    await WakelockPlus.disable();
  });

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 100));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue,
        reason: 'Timed out waiting for the device crop flow.');
  }

  Future<void> showBackgrounds(WidgetTester tester) async {
    // A fresh route and State per case prevent pending navigation and scroll
    // layout from the previous native-picker interaction leaking into a test.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    final controller = ScrollController();
    addTearDown(() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      controller.dispose();
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: draft,
      child: MaterialApp(
          home: Scaffold(
              body: BackgroundTab(
        onEdited: (_) {},
        scrollController: controller,
      ))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester, String action) async {
    final button = find.byKey(const ValueKey('background-getReady-choose'));
    await until(
        tester,
        () =>
            button.evaluate().isNotEmpty &&
            tester.widget<TextButton>(button).onPressed != null);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    final access = await MediaBrowser().state(false);
    if (access['permission'] == 'denied') {
      debugPrint('[CROP-TEST] PERMISSION ALLOW');
    }
    await tester.tap(button);
    await until(
        tester,
        () =>
            find.byType(MediaBrowserScreen).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await tester.pumpAndSettle();
    if (action == 'CANCEL') {
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      return;
    }
    if (find.text(action).evaluate().isEmpty) {
      for (final part in [
        'Internal storage',
        'Download',
        const String.fromEnvironment('MEDIA_CROP_FOLDER')
      ]) {
        await until(
            tester, () => find.text(part).hitTestable().evaluate().isNotEmpty);
        await tester.tap(find.text(part).hitTestable().first);
        await until(tester,
            () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
        await tester.pumpAndSettle();
      }
    }
    await tester.tap(find.text(action));
  }

  Future<void> choose(WidgetTester tester, String action) async {
    await openPicker(tester, action);
    await until(
        tester, () => find.byType(ImageCropScreen).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    // Flutter can finish layout before Android's window rotation animation has
    // settled. Wait before asking the host to capture the physical display.
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    debugPrint('[CROP-TEST] CAPTURE $name');
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  Future<ui.Image> readImage(String reference) async => BackgroundCrop.decode(
      await (await MediaStore.instance.file(reference)).readAsBytes());

  testWidgets('real picker cancellation preserves the saved background',
      (tester) async {
    await showBackgrounds(tester);
    await openPicker(tester, 'CANCEL');
    // Closing the application browser must re-enable Choose without changing media.
    await Future<void>.delayed(const Duration(seconds: 2));
    await until(tester, () {
      final button = find.byKey(const ValueKey('background-getReady-choose'));
      return button.evaluate().isNotEmpty &&
          tester.widget<TextButton>(button).onPressed != null;
    });
    expect(draft.timer.backgrounds['getReady'], legacy);
    expect(find.byType(ImageCropScreen), findsNothing);
    expect(MediaFiles.isCroppedImage(legacy), isFalse);
  });

  testWidgets('real picker, pinch, drag, and low-resolution apply',
      (tester) async {
    await showBackgrounds(tester);
    await choose(tester, 'crop-large.png');
    final viewport = find.byKey(const ValueKey('crop-viewport'));
    final window = MediaQuery.sizeOf(tester.element(viewport));
    expect(tester.getSize(viewport).aspectRatio,
        closeTo(BackgroundCrop.portraitSize(window).aspectRatio, 1e-6));
    await capture(tester, 'crop_initial');
    final center = tester.getCenter(viewport);
    final first =
        await tester.startGesture(center - const Offset(15, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(15, 0), pointer: 2);
    for (var i = 1; i <= 4; i++) {
      await first.moveTo(center - Offset(15 + i * 10, 0));
      await second.moveTo(center + Offset(15 + i * 10, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await first.up();
    await second.up();
    await tester.drag(viewport, Offset(-tester.getSize(viewport).width * 2, 0));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('crop-resolution-warning')), findsOneWidget);
    await capture(tester, 'crop_zoomed');
    await tester.tap(find.byKey(const ValueKey('crop-apply')));
    await until(tester,
        () => MediaFiles.isCroppedImage(draft.timer.backgrounds['getReady']!));
    final result = await readImage(draft.timer.backgrounds['getReady']!);
    try {
      expect(result.width, lessThan(1440));
      expect(result.height, lessThan(3200));
      final rgba = (await result.toByteData())!;
      final offset =
          (result.height ~/ 2 * result.width + result.width ~/ 2) * 4;
      expect(
          List.generate(4, (i) => rgba.getUint8(offset + i)), [0, 0, 255, 255]);
      debugPrint(
          '[CROP-TEST] ZOOMED ${result.width}x${result.height} blue-center verified');
    } finally {
      result.dispose();
    }
    expect(draft.timer.backgrounds['work'], legacy);
  });

  testWidgets('full crop persists at output bounds and contains in landscape',
      (tester) async {
    await showBackgrounds(tester);
    final previous = draft.timer.backgrounds['getReady'];
    await choose(tester, 'crop-large.png');
    expect(find.byKey(const ValueKey('crop-resolution-warning')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('crop-apply')));
    await until(tester, () => draft.timer.backgrounds['getReady'] != previous);
    final reference = draft.timer.backgrounds['getReady']!;
    final result = await readImage(reference);
    try {
      expect(result.width, lessThanOrEqualTo(1440));
      expect(result.height, 3200);
      debugPrint(
          '[CROP-TEST] FULL ${result.width}x${result.height} output bounds verified');
    } finally {
      result.dispose();
    }
    await timers.updateTimer(draft.timer);
    final loaded =
        (await timers.loadTimers()).singleWhere((t) => t.id == draft.timer.id);
    expect(loaded.backgrounds['getReady'], reference);
    debugPrint('[CROP-TEST] REMOVE_SOURCE');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await (await MediaStore.instance.file(reference)).exists(), isTrue);
    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ManagedBackground(
      reference: reference,
      color: Colors.orange,
    ))));
    await until(
        tester,
        () =>
            find.byType(Image).evaluate().isNotEmpty &&
            MediaQuery.sizeOf(tester.element(find.byType(ManagedBackground)))
                    .width >
                MediaQuery.sizeOf(
                        tester.element(find.byType(ManagedBackground)))
                    .height);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    await capture(tester, 'landscape_full');
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await until(
        tester,
        () =>
            MediaQuery.sizeOf(tester.element(find.byType(ManagedBackground)))
                .height >
            MediaQuery.sizeOf(tester.element(find.byType(ManagedBackground)))
                .width);
    await capture(tester, 'portrait_full');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('small real image warns, Reset and cancel preserve saved crop',
      (tester) async {
    await showBackgrounds(tester);
    final previous = draft.timer.backgrounds['getReady'];
    await choose(tester, 'crop-small.png');
    expect(
        find.byKey(const ValueKey('crop-resolution-warning')), findsOneWidget);
    await tester.drag(
        find.byKey(const ValueKey('crop-viewport')), const Offset(-100, 0));
    await tester.tap(find.text('Reset'));
    await capture(tester, 'small_warning');
    await tester.tap(find.byTooltip('Cancel'));
    await until(tester, () => find.byType(ImageCropScreen).evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(draft.timer.backgrounds['getReady'], previous);
    expect(await (await MediaStore.instance.file(previous!)).exists(), isTrue);
    expect(tester.takeException(), isNull);
    debugPrint('[CROP-TEST] Saved crop retained after cancellation');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
