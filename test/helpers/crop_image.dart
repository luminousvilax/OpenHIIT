import 'dart:typed_data';
import 'dart:ui' as ui;

Future<ui.Image> stripedImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (final (index, color) in const [
    ui.Color(0xffff0000),
    ui.Color(0xff00ff00),
    ui.Color(0xff0000ff)
  ].indexed) {
    canvas.drawRect(
        ui.Rect.fromLTWH(index * 40, 0, 40, 80), ui.Paint()..color = color);
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(120, 80);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> imagePng(ui.Image image) async {
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

Future<List<int>> centerPixel(ui.Image image) async {
  final rgba = (await image.toByteData())!;
  final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  return List.generate(4, (i) => rgba.getUint8(offset + i));
}
