import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/background_crop.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';

void main() {
  late Directory temporary;
  late MediaStore originalStore;
  const cropped =
      'local:images/crop1-01234567-89ab-cdef-0123-456789abcdef_photo.png';
  const legacy = 'local:images/01234567-89ab-cdef-0123-456789abcdef_photo.png';
  const backgroundKey = ValueKey('background-pixels');

  setUp(() async {
    originalStore = MediaStore.instance;
    temporary =
        await Directory.systemTemp.createTemp('openhiit-background-test-');
    MediaStore.instance = MediaStore(directory: temporary);
    for (final reference in [cropped, legacy]) {
      final file = await MediaStore.instance.file(reference);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNQSJgARAwQCgAcDgRBIqsFewAAAABJRU5ErkJggg=='));
    }
  });
  tearDown(() async {
    MediaStore.instance = originalStore;
    PaintingBinding.instance.imageCache.clear();
    await temporary.delete(recursive: true);
  });

  Future<Image> render(WidgetTester tester, String reference, Size window,
      {Size? preview, BoxFit? fit, double pixelRatio = 1}) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = pixelRatio;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
      width: preview?.width ?? window.width,
      height: preview?.height ?? window.height,
      child: RepaintBoundary(
        key: backgroundKey,
        child: ManagedBackground(
            reference: reference, color: Colors.orange, fit: fit),
      ),
    )))));
    for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    return tester.widget<Image>(find.byType(Image));
  }

  testWidgets(
      'rounded portrait crops cover every edge; landscape keeps margins',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reference = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(500, 901);
      picture.dispose();
      try {
        final crop = BackgroundCrop.centered(const Size(500, 901), 0.45);
        // Saving 405.45 x 901 pixels rounds the width down to 405.
        final bytes = await BackgroundCrop.encode(source, crop);
        final saved = await BackgroundCrop.decode(bytes);
        try {
          expect(Size(saved.width.toDouble(), saved.height.toDouble()),
              const Size(405, 901));
          final rgba = (await saved.toByteData())!;
          for (final x in [0, saved.width - 1]) {
            expect(
                rgba.getUint8(((saved.height ~/ 2) * saved.width + x) * 4 + 3),
                255,
                reason: 'The saved crop must have opaque side edges.');
          }
        } finally {
          saved.dispose();
        }
        return await MediaStore.instance
            .importCroppedImage(bytes, name: 'rounded');
      } finally {
        source.dispose();
      }
    });

    for (final (window, ratio) in const [
      (Size(1080, 2400), 3.0),
      (Size(1080, 2400), 2.75),
      (Size(360, 800), 1.0),
      (Size(2400, 1080), 3.0),
    ]) {
      await render(tester, reference!, window, pixelRatio: ratio);
      for (var i = 0;
          i < 100 &&
              tester.widget<RawImage>(find.byType(RawImage)).image == null;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(backgroundKey));
      final pixels = await tester.runAsync(() async {
        final screenshot = await boundary.toImage(pixelRatio: ratio);
        try {
          return (await screenshot.toByteData())!;
        } finally {
          screenshot.dispose();
        }
      });
      final width = window.width.toInt();
      final height = window.height.toInt();
      List<int> pixel(int x, int y) => List.generate(
          4, (channel) => pixels!.getUint8((y * width + x) * 4 + channel));
      final center = pixel(width ~/ 2, height ~/ 2);
      expect(center, isNot([255, 152, 0, 255]));
      final portrait = height > width;
      for (final x in [0, width - 1]) {
        expect(pixel(x, height ~/ 2), portrait ? center : [255, 152, 0, 255],
            reason: '$window at DPR $ratio: side edges');
      }
      if (portrait) {
        for (final y in [0, height - 1]) {
          expect(pixel(width ~/ 2, y), center,
              reason: '$window at DPR $ratio: top/bottom edges');
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new crops cover portrait workouts and contain landscape',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var image = await render(tester, cropped, const Size(1440, 3200));
    expect(image.fit, BoxFit.cover);
    expect((image.image as ResizeImage).width, 1440);
    expect((image.image as ResizeImage).height, isNull);
    image = await render(tester, cropped, const Size(3200, 1440));
    expect(image.fit, BoxFit.contain);
    image = await render(tester, cropped, const Size(1440, 3200),
        preview: const Size(300, 140), fit: BoxFit.cover);
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.center);
    expect((image.image as ResizeImage).width, 300);
    expect((image.image as ResizeImage).height, isNull,
        reason:
            'Cover previews must not decode a tall crop to the short card height.');
    final background = tester.widget<ColoredBox>(find.descendant(
        of: find.byType(ManagedBackground), matching: find.byType(ColoredBox)));
    expect(background.color, Colors.orange);
    expect(image.colorBlendMode, BlendMode.darken);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('legacy images keep centered cover and 2048 decode bounds',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final window in const [Size(1440, 3200), Size(3200, 1440)]) {
      final image = await render(tester, legacy, window);
      expect(image.fit, BoxFit.cover);
      expect(image.alignment, Alignment.center);
      final provider = image.image as ResizeImage;
      expect(provider.width!, lessThanOrEqualTo(2048));
      expect(provider.height!, lessThanOrEqualTo(2048));
    }
    await tester.pumpWidget(const SizedBox());
  });
}
