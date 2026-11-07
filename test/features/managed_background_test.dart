import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';

void main() {
  late Directory temporary;
  late MediaStore originalStore;
  const cropped =
      'local:images/crop1-01234567-89ab-cdef-0123-456789abcdef_photo.png';
  const legacy = 'local:images/01234567-89ab-cdef-0123-456789abcdef_photo.png';

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
      {Size? preview, BoxFit? fit}) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
      width: preview?.width ?? window.width,
      height: preview?.height ?? window.height,
      child: ManagedBackground(
          reference: reference, color: Colors.orange, fit: fit),
    )))));
    for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    return tester.widget<Image>(find.byType(Image));
  }

  testWidgets('new crops contain in workouts and can cover card previews',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var image = await render(tester, cropped, const Size(1440, 3200));
    expect(image.fit, BoxFit.contain);
    expect((image.image as ResizeImage).width, 1440);
    expect((image.image as ResizeImage).height, 3200);
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
