import 'package:background_hiit_timer/latest_cue.dart';
import 'package:background_hiit_timer/media_files.dart';
import 'package:background_hiit_timer/utils/log.dart';
import 'package:openhiit_audioplayers/openhiit_audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CuePlayer {
  CuePlayer({this.onPlayed}) {
    _latest = LatestCue(_stopCurrent);
  }

  final void Function(String source, bool fallback)? onPlayed;
  final AudioCache _cache =
      AudioCache(prefix: 'packages/background_hiit_timer/assets/');
  AudioPlayer? _current;
  late final LatestCue _latest;

  Future<void> play(String sound, SharedPreferences preferences,
      {required String fallback}) async {
    if (sound.isEmpty || sound == 'none') return;
    try {
      await _latest.replace((isCurrent) async {
        // A canceled preparation must never resume a newer cue's player.
        final player = AudioPlayer()..audioCache = _cache;
        _current = player;
        await preferences.reload();
        if (!isCurrent()) return;
        await player.setVolume(
            ((preferences.getDouble('volume') ?? 80) / 100).clamp(0, 1));
        if (!isCurrent()) return;
        if (MediaFiles.isLocal(sound)) {
          try {
            final file = await MediaFiles.file(sound);
            if (!await file.exists()) {
              throw StateError('Audio file is missing.');
            }
            if (!isCurrent()) return;
            await player.play(DeviceFileSource(file.path));
            if (!isCurrent()) return;
            onPlayed?.call(sound, false);
            await preferences.remove(MediaFiles.failureKey(sound));
            return;
          } catch (error) {
            if (!isCurrent()) return;
            await preferences.setString(MediaFiles.failureKey(sound),
                'Unable to play this file. Choose another audio file.');
            logger.e('Custom audio failed: $error');
            if (!isCurrent()) return;
            await player.stop();
          }
          if (isCurrent()) {
            await player.play(AssetSource('audio/$fallback.mp3'));
            if (isCurrent()) onPlayed?.call(fallback, true);
          }
        } else if (isCurrent()) {
          await player.play(AssetSource('audio/$sound.mp3'));
          if (isCurrent()) onPlayed?.call(sound, false);
        }
      });
    } catch (error) {
      logger.e('Unable to play cue: $error');
    }
  }

  Future<void> stop() => _latest.stop();

  Future<void> _stopCurrent() async {
    final player = _current;
    _current = null;
    if (player != null) await player.dispose();
  }

  Future<void> dispose() => stop();
}
