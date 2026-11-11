import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openhiit/core/media/media_browser.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/shared/ui/widgets/image_crop_screen.dart';
import 'package:openhiit/shared/ui/widgets/media_browser_screen.dart';
import 'package:openhiit/shared/ui/widgets/media_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const fixtureFolder = String.fromEnvironment('MEDIA_PICKER_FOLDER');
const restoreOnly = bool.fromEnvironment('MEDIA_PICKER_RESTORE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final browser = MediaBrowser();
  String? audioReference;
  String? imageReference;
  final imported = <String>[];

  setUpAll(() async {
    final info = await PackageInfo.fromPlatform();
    if (info.packageName != 'com.codepup.workout_timer.media_test' ||
        fixtureFolder.isEmpty) {
      throw StateError('Run through tool/test_android_media.py --picker.');
    }
    GoogleFonts.config.allowRuntimeFetching = false;
    await WakelockPlus.enable();
  });
  tearDownAll(() async {
    for (final reference in imported) {
      MediaStore.instance.releasePending(reference);
    }
    await WakelockPlus.disable();
  });

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 75));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue, reason: 'Timed out in the real media browser.');
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await until(tester, () => finder.hitTestable().evaluate().isNotEmpty);
    await tester.tap(finder.hitTestable().first);
    await tester.pumpAndSettle();
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: Column(children: [
                    TextButton(
                        onPressed: () async {
                          final result = await pickAudio(context);
                          if (result != null) {
                            audioReference = result;
                            imported.add(result);
                          }
                        },
                        child: const Text('Open audio')),
                    TextButton(
                        onPressed: () async {
                          final result = await pickBackgroundImage(context);
                          if (result != null) {
                            imageReference = result;
                            imported.add(result);
                          }
                        },
                        child: const Text('Open image')),
                  ]),
                ))));
    await tester.pumpAndSettle();
  }

  Future<void> ready(WidgetTester tester) async {
    await until(
        tester,
        () =>
            find.byType(MediaBrowserScreen).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, bool audio,
      {String? permission}) async {
    if (permission != null) debugPrint('[PICKER-TEST] PERMISSION $permission');
    await tester.tap(find.text(audio ? 'Open audio' : 'Open image'));
    await ready(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tap(tester, find.byTooltip('Close'));
    await until(
        tester, () => find.byType(MediaBrowserScreen).evaluate().isEmpty);
  }

  Future<void> libraryFixture(WidgetTester tester) async {
    await ready(tester);
    for (final part in ['Internal storage', 'Download', fixtureFolder]) {
      await until(
          tester, () => find.text(part).hitTestable().evaluate().isNotEmpty);
      await tap(tester, find.text(part));
      await ready(tester);
    }
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    debugPrint('[PICKER-TEST] CAPTURE $name');
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  if (restoreOnly) {
    testWidgets(
        'browser preferences and folder grants survive a fresh application process',
        (tester) async {
      final audio = await browser.state(true);
      final image = await browser.state(false);
      expect((audio['location'] as Map)['source'], 'library');
      expect(
          (audio['location'] as Map)['directory'], endsWith('$fixtureFolder/'));
      expect(audio['sort'], 'size');
      expect(audio['grid'], isTrue);
      expect(image['sort'], 'modified');
      expect(image['grid'], isTrue);
      expect(image['showNames'], isTrue);
      expect(image['largePreviews'], isTrue);
      expect(audio['largePreviews'], isFalse);
      expect((audio['folders'] as List).length, 1);
      expect(audio['file'], isNotNull);
      expect(image['file'], isNotNull);
      await show(tester);
      await open(tester, true);
      expect(find.text('声音.wav'), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      await capture(tester, 'restored-audio');
      await close(tester);
      await open(tester, false);
      expect(find.text('picker.png'), findsOneWidget);
      await capture(tester, 'restored-image-preview');
      await tap(tester, find.text('Folders').first);
      await ready(tester);
      await tap(tester, find.text(fixtureFolder));
      await ready(tester);
      expect(find.text('picker.png'), findsOneWidget);
      await close(tester);
    });
    return;
  }

  testWidgets(
      'denial leaves folders usable, shared read grant imports only current-directory audio',
      (tester) async {
    await show(tester);
    await open(tester, true, permission: 'DENY');
    expect(find.text('Allow access'), findsOneWidget);
    await close(tester);
    await open(tester, true);
    expect(find.text('Allow access'), findsOneWidget);
    debugPrint('[PICKER-TEST] AUTHORIZE');
    await tap(tester, find.text('Add folder'));
    await until(
        tester, () => find.text('声音.wav').hitTestable().evaluate().isNotEmpty);
    expect(find.text('unsupported.txt'), findsNothing);
    expect(find.text('nested.wav'), findsNothing);
    expect(find.text('nested'), findsOneWidget);
    await tap(tester, find.text('nested'));
    await ready(tester);
    expect(find.text('nested.wav'), findsOneWidget);
    debugPrint('[PICKER-TEST] BACK');
    await until(
        tester, () => find.text('声音.wav').hitTestable().evaluate().isNotEmpty);
    await ready(tester);
    expect(find.text('声音.wav'), findsOneWidget);
    await capture(tester, 'authorized-audio');
    await tap(tester, find.text('声音.wav'));
    await until(tester, () => audioReference != null);
    final file = await MediaStore.instance.file(audioReference!);
    expect((await file.readAsBytes()).take(4), [82, 73, 70, 70]);
    final audio = await browser.state(true);
    expect((audio['location'] as Map)['source'], 'folders');
    expect((audio['folders'] as List).length, 1);
    expect(audio['permission'], 'denied');
  });

  testWidgets(
      'real media library imports audio and retains preferences after closing',
      (tester) async {
    await show(tester);
    await open(tester, true);
    expect(find.text('声音.wav'), findsOneWidget);
    await tap(tester, find.text('Media library').first);
    await ready(tester);
    debugPrint('[PICKER-TEST] PERMISSION ALLOW');
    await tap(tester, find.text('Allow access'));
    await until(
        tester, () => find.text('Internal storage').evaluate().isNotEmpty);
    await libraryFixture(tester);
    await tap(tester, find.byTooltip('Sort'));
    await tap(
        tester,
        find.byWidgetPredicate(
            (w) => w is CheckedPopupMenuItem<String> && w.value == 'size'));
    await tap(tester, find.byTooltip('Grid view'));
    final previous = audioReference;
    await tap(tester, find.text('声音.wav'));
    await until(
        tester, () => find.byType(MediaBrowserScreen).evaluate().isEmpty);
    await until(tester, () => audioReference != previous);
    await open(tester, true);
    expect(find.text('声音.wav'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    await close(tester);
    final audio = await browser.state(true);
    expect(audio['sort'], 'size');
    expect(audio['grid'], isTrue);
  });

  testWidgets(
      'image library is independent, crop cancel preserves assignment, apply imports a private copy',
      (tester) async {
    await show(tester);
    final audioBefore = await browser.state(true);
    await open(tester, false, permission: 'ALLOW');
    await libraryFixture(tester);
    expect(find.text('声音.wav'), findsNothing);
    await until(tester, () => find.byType(Image).evaluate().isNotEmpty);
    final grid = find.byType(GridView);
    expect(
        (tester.widget<GridView>(grid).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3);
    await capture(tester, 'image-grid-small-named');
    await tap(tester, find.byTooltip('Hide filenames'));
    expect(find.text('picker.png'), findsNothing);
    await capture(tester, 'image-grid-small-unnamed');
    await tap(tester, find.byTooltip('Larger previews'));
    expect(
        (tester.widget<GridView>(grid).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2);
    await capture(tester, 'image-grid-large-unnamed');
    await tap(tester, find.byTooltip('Show filenames'));
    expect(find.text('picker.png'), findsOneWidget);
    await capture(tester, 'image-grid-large-named');
    await tap(tester, find.text('picker.png'));
    await until(
        tester, () => find.byType(ImageCropScreen).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tap(tester, find.byTooltip('Cancel'));
    expect(imageReference, isNull);
    await open(tester, false);
    expect(find.text('picker.png'), findsOneWidget);
    await tap(tester, find.text('Folders').first);
    await ready(tester);
    await tap(tester, find.text(fixtureFolder));
    await ready(tester);
    expect(find.text('picker.png'), findsOneWidget);
    expect(find.text('声音.wav'), findsNothing);
    // Browsing the folder grant then closing must not overwrite the library location.
    await close(tester);
    await open(tester, false);
    expect(find.text('picker.png'), findsOneWidget);
    await tap(tester, find.text('picker.png'));
    await until(
        tester, () => find.byType(ImageCropScreen).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tap(tester, find.text('Apply'));
    await until(tester, () => imageReference != null);
    final image = await MediaStore.instance.file(imageReference!);
    expect(await image.exists(), isTrue);
    expect(image.path, contains('crop1-'));
    final audioAfter = await browser.state(true);
    expect(audioAfter['location'], audioBefore['location']);
    expect(audioAfter['sort'], audioBefore['sort']);
    expect(audioAfter['grid'], audioBefore['grid']);
  });
}
