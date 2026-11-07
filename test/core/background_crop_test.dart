import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/background_crop.dart';

import '../helpers/crop_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('output respects both bounds, preserves aspect, and never upscales', () {
    expect(BackgroundCrop.outputSize(const ui.Size(2160, 4800)),
        const ui.Size(1440, 3200));
    expect(BackgroundCrop.outputSize(const ui.Size(2000, 5000)),
        const ui.Size(1280, 3200));
    expect(BackgroundCrop.outputSize(const ui.Size(2000, 3000)),
        const ui.Size(1440, 2160));
    expect(BackgroundCrop.outputSize(const ui.Size(400, 900)),
        const ui.Size(400, 900));
    expect(BackgroundCrop.portraitSize(const ui.Size(2400, 1080)),
        const ui.Size(1080, 2400));
  });

  test('source decoding bounds memory and extremely wide images', () {
    for (final source in const [
      ui.Size(120, 80),
      ui.Size(12000, 9000),
      ui.Size(100000, 1000),
      ui.Size(1000, 100000),
      ui.Size(20000, 20000)
    ]) {
      final size = BackgroundCrop.decodeSize(source);
      expect(size.longestSide, lessThanOrEqualTo(8192));
      expect(size.width * size.height, lessThanOrEqualTo(16 * 1024 * 1024));
      expect(size.width, lessThanOrEqualTo(source.width));
      expect(size.height, lessThanOrEqualTo(source.height));
      expect(size.width / size.height,
          closeTo(source.aspectRatio, (1 + source.aspectRatio) / size.height));
    }
  });

  test('pan and zoom preserve the focal pixel and cannot reveal empty space',
      () {
    const image = ui.Size(120, 80);
    final start = BackgroundCrop.centered(image, 0.5);
    expect(start, const ui.Rect.fromLTWH(40, 0, 40, 80));
    ui.Rect transform(double scale, ui.Offset focal) =>
        BackgroundCrop.transform(
            start: start,
            image: image,
            viewport: const ui.Size(200, 400),
            startFocal: const ui.Offset(100, 200),
            focal: focal,
            scale: scale);
    expect(transform(2, const ui.Offset(100, 200)),
        const ui.Rect.fromLTWH(50, 20, 20, 40));
    expect(transform(2, const ui.Offset(150, 300)),
        const ui.Rect.fromLTWH(45, 10, 20, 40));
    expect(transform(1, const ui.Offset(-500, -500)),
        const ui.Rect.fromLTWH(80, 0, 40, 80));
    expect(transform(0.01, const ui.Offset(100, 200)), start);
    for (final scale in [0.01, 1.0, 2.0, 1000000.0]) {
      for (final focal in const [
        ui.Offset(-10000, -10000),
        ui.Offset(10000, 10000)
      ]) {
        final crop = transform(scale, focal);
        expect(crop.left, greaterThanOrEqualTo(0));
        expect(crop.top, greaterThanOrEqualTo(0));
        expect(crop.right, lessThanOrEqualTo(image.width));
        expect(crop.bottom, lessThanOrEqualTo(image.height));
        expect(crop.width / crop.height, closeTo(0.5, 1e-8));
      }
    }
  });

  test('PNG export uses the selected source region without upscaling',
      () async {
    final image = await stripedImage();
    addTearDown(image.dispose);
    final bytes = await BackgroundCrop.encode(
        image, const ui.Rect.fromLTWH(80, 0, 40, 80));
    final result = await BackgroundCrop.decode(bytes);
    addTearDown(result.dispose);
    expect(result.width, 40);
    expect(result.height, 80);
    expect(await centerPixel(result), [0, 0, 255, 255]);
  });

  test('low resolution uses the capped display target', () {
    final target = BackgroundCrop.outputSize(const ui.Size(2160, 4800));
    expect(
        BackgroundCrop.isLowResolution(
            const ui.Rect.fromLTWH(0, 0, 1440, 3200), target),
        isFalse);
    expect(
        BackgroundCrop.isLowResolution(
            const ui.Rect.fromLTWH(0, 0, 720, 1600), target),
        isTrue);
  });
}
