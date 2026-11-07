import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Pixel geometry shared by the crop preview and the saved result.
abstract final class BackgroundCrop {
  static const maxWidth = 1440;
  static const maxHeight = 3200;
  static const maxDecodeEdge = 8192;
  static const maxDecodePixels = 16 * 1024 * 1024;

  static ui.Size portraitSize(ui.Size size) =>
      ui.Size(size.shortestSide, size.longestSide);

  static ui.Size outputSize(ui.Size size) {
    final scale =
        math.min(1.0, math.min(maxWidth / size.width, maxHeight / size.height));
    return ui.Size(math.max(1, (size.width * scale).floor()).toDouble(),
        math.max(1, (size.height * scale).floor()).toDouble());
  }

  static ui.Size decodeSize(ui.Size size) {
    final scale = math.min(
        1.0,
        math.min(maxDecodeEdge / size.longestSide,
            math.sqrt(maxDecodePixels / (size.width * size.height))));
    return ui.Size(math.max(1, (size.width * scale).floor()).toDouble(),
        math.max(1, (size.height * scale).floor()).toDouble());
  }

  static ui.Rect centered(ui.Size image, double aspectRatio) {
    final width = math.min(image.width, image.height * aspectRatio);
    final height = width / aspectRatio;
    return ui.Rect.fromLTWH(
        (image.width - width) / 2, (image.height - height) / 2, width, height);
  }

  /// Keep the source pixel under the gesture's initial focal point under its
  /// current focal point while scaling, then constrain the crop to the image.
  static ui.Rect transform({
    required ui.Rect start,
    required ui.Size image,
    required ui.Size viewport,
    required ui.Offset startFocal,
    required ui.Offset focal,
    required double scale,
  }) {
    final aspect = start.width / start.height;
    final maximum = centered(image, aspect).width;
    final minimum = math.min(maximum, 1.0);
    final width = (start.width / scale).clamp(minimum, maximum);
    final height = width / aspect;
    final anchor = ui.Offset(
        start.left + startFocal.dx / viewport.width * start.width,
        start.top + startFocal.dy / viewport.height * start.height);
    final left = (anchor.dx - focal.dx / viewport.width * width)
        .clamp(0.0, math.max(0.0, image.width - width))
        .toDouble();
    final top = (anchor.dy - focal.dy / viewport.height * height)
        .clamp(0.0, math.max(0.0, image.height - height))
        .toDouble();
    return ui.Rect.fromLTWH(left, top, width, height);
  }

  static bool isLowResolution(ui.Rect crop, ui.Size target) =>
      crop.width + 1 < target.width || crop.height + 1 < target.height;

  static Future<ui.Image> decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final size = decodeSize(
            ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble()));
        final codec = await descriptor.instantiateCodec(
            targetWidth: size.width.toInt(), targetHeight: size.height.toInt());
        try {
          return (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  static Future<Uint8List> encode(ui.Image image, ui.Rect crop) async {
    final size = outputSize(crop.size);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(image, crop, ui.Offset.zero & size,
        ui.Paint()..filterQuality = ui.FilterQuality.high);
    final picture = recorder.endRecording();
    try {
      final result =
          await picture.toImage(size.width.toInt(), size.height.toInt());
      try {
        final data = await result.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('Unable to encode the cropped image.');
        }
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        result.dispose();
      }
    } finally {
      picture.dispose();
    }
  }
}
