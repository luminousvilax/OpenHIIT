import 'dart:io';

import 'package:background_hiit_timer/media_files.dart';
import 'package:flutter/material.dart';
import 'package:openhiit/core/media/background_crop.dart';
import 'package:openhiit/core/media/media_store.dart';

class ManagedBackground extends StatefulWidget {
  const ManagedBackground(
      {super.key, required this.reference, required this.color, this.fit});
  final String? reference;
  final Color color;
  final BoxFit? fit;

  @override
  State<ManagedBackground> createState() => _ManagedBackgroundState();
}

class _ManagedBackgroundState extends State<ManagedBackground> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = _resolve();
  }

  @override
  void didUpdateWidget(ManagedBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reference != oldWidget.reference) _file = _resolve();
  }

  Future<File?> _resolve() async {
    if (widget.reference == null) return null;
    try {
      final file = await MediaStore.instance.file(widget.reference!);
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: widget.color,
        child: FutureBuilder<File?>(
          // A new reference clears the previous image while its file resolves.
          key: ValueKey(widget.reference),
          future: _file,
          builder: (context, snapshot) {
            final file = snapshot.data;
            if (file == null) return const SizedBox.expand();
            final cropped = MediaFiles.isCroppedImage(widget.reference!);
            return LayoutBuilder(builder: (context, constraints) {
              final size =
                  cropped ? constraints.biggest : MediaQuery.sizeOf(context);
              // Integer crop/decode dimensions can slightly change the aspect
              // ratio. Fill portrait backgrounds to avoid stage-color seams;
              // landscape still shows the complete crop with colored margins.
              final fit = widget.fit ??
                  (cropped && size.width > size.height
                      ? BoxFit.contain
                      : BoxFit.cover);
              final coverCrop = cropped && fit == BoxFit.cover;
              final scale = MediaQuery.devicePixelRatioOf(context);
              final decodeWidth =
                  ((coverCrop ? size.longestSide : size.width) * scale)
                      .round()
                      .clamp(1, cropped ? BackgroundCrop.maxWidth : 2048);
              final decodeHeight = (size.height * scale)
                  .round()
                  .clamp(1, cropped ? BackgroundCrop.maxHeight : 2048);
              return Image(
                image: ResizeImage(FileImage(file),
                    width: decodeWidth,
                    // A portrait crop filling a wide card needs its width's
                    // pixels. Fitting decoding to the card height would shrink
                    // it first, then stretch that small image back across it.
                    height: coverCrop ? null : decodeHeight,
                    policy: ResizeImagePolicy.fit),
                width: double.infinity,
                height: double.infinity,
                fit: fit,
                filterQuality:
                    cropped ? FilterQuality.medium : FilterQuality.low,
                alignment: Alignment.center,
                color: Colors.black.withValues(alpha: 0.45),
                colorBlendMode: BlendMode.darken,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              );
            });
          },
        ),
      );
}
