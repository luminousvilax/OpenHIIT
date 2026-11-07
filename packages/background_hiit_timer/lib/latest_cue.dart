import 'dart:async';

/// Serializes player operations and cancels queued, superseded cues.
class LatestCue {
  LatestCue(this.stopPlayback);

  final Future<void> Function() stopPlayback;
  Future<void> _tail = Future.value();
  int _generation = 0;
  Completer<void>? _cancel;

  Future<void> replace(Future<void> Function(bool Function() isCurrent) play) {
    _cancel?.complete();
    final cancel = Completer<void>();
    _cancel = cancel;
    final generation = ++_generation;
    return _enqueue(() async {
      if (generation != _generation) return;
      await stopPlayback();
      if (generation == _generation) {
        await Future.any([
          play(() => generation == _generation),
          cancel.future,
        ]);
      }
    });
  }

  Future<void> stop() {
    _cancel?.complete();
    _cancel = null;
    ++_generation;
    return _enqueue(stopPlayback);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object _) {});
    return result;
  }
}
