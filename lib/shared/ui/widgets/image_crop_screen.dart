import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:openhiit/core/media/background_crop.dart';

/// The caller owns [image] and keeps it alive until this route is removed.
class ImageCropScreen extends StatefulWidget {
  const ImageCropScreen({
    super.key,
    required this.image,
    required this.portraitPixels,
  });

  final ui.Image image;
  final Size portraitPixels;

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  late Rect _crop;
  late Rect _gestureCrop;
  late Offset _gestureFocal;
  bool _applying = false;

  Size get _imageSize =>
      Size(widget.image.width.toDouble(), widget.image.height.toDouble());
  double get _aspect => widget.portraitPixels.aspectRatio;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() => _crop = BackgroundCrop.centered(_imageSize, _aspect);

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      final bytes = await BackgroundCrop.encode(widget.image, _crop);
      if (mounted) Navigator.of(context).pop<Uint8List>(bytes);
    } catch (_) {
      if (mounted) {
        setState(() => _applying = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Unable to crop this image. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lowResolution = BackgroundCrop.isLowResolution(
        _crop, BackgroundCrop.outputSize(widget.portraitPixels));
    return PopScope(
      canPop: !_applying,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Crop background'),
          leading: IconButton(
            tooltip: 'Cancel',
            onPressed: _applying ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
          actions: [
            TextButton(
              key: const ValueKey('crop-apply'),
              onPressed: _applying ? null : _apply,
              child: _applying
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Apply'),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _aspect,
                    child: LayoutBuilder(builder: (context, constraints) {
                      final viewport = constraints.biggest;
                      return GestureDetector(
                        key: const ValueKey('crop-viewport'),
                        onScaleStart: _applying
                            ? null
                            : (details) {
                                _gestureCrop = _crop;
                                _gestureFocal = details.localFocalPoint;
                              },
                        onScaleUpdate: _applying
                            ? null
                            : (details) {
                                setState(() {
                                  _crop = BackgroundCrop.transform(
                                    start: _gestureCrop,
                                    image: _imageSize,
                                    viewport: viewport,
                                    startFocal: _gestureFocal,
                                    focal: details.localFocalPoint,
                                    scale: details.scale,
                                  );
                                });
                              },
                        child: CustomPaint(
                          painter: _CropPainter(widget.image, _crop),
                          child: const SizedBox.expand(),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Drag to position. Pinch to zoom.'),
                if (lowResolution)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'This crop may look blurry. You can still apply it.',
                      key: const ValueKey('crop-resolution-warning'),
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                TextButton(
                  onPressed: _applying ? null : () => setState(_reset),
                  child: const Text('Reset'),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop);
  final ui.Image image;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = Colors.black);
    canvas.drawImageRect(
        image, crop, bounds, Paint()..filterQuality = FilterQuality.high);
    final grid = Paint()
      ..color = Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(bounds.deflate(0.5), grid);
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0),
          Offset(size.width * i / 3, size.height), grid);
      canvas.drawLine(Offset(0, size.height * i / 3),
          Offset(size.width, size.height * i / 3), grid);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      image != oldDelegate.image || crop != oldDelegate.crop;
}
