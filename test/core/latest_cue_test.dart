import 'dart:async';

import 'package:background_hiit_timer/latest_cue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new prompts replace the active cue and repeated cues restart',
      () async {
    final events = <String>[];
    final cues = LatestCue(() async => events.add('stop'));
    await cues.replace((_) async => events.add('play countdown'));
    await cues.replace((_) async => events.add('play countdown'));
    expect(events, ['stop', 'play countdown', 'stop', 'play countdown']);
  });

  test('pause cancels a cue that is still loading and does not replay it',
      () async {
    final prepared = Completer<void>();
    final loading = Completer<void>();
    final events = <String>[];
    final cues = LatestCue(() async => events.add('stop'));
    final cue = cues.replace((isCurrent) async {
      loading.complete();
      await prepared.future;
      if (isCurrent()) events.add('play stale cue');
    });
    await loading.future;
    await cues.stop();
    expect(events, ['stop', 'stop'], reason: 'Pause cannot wait for decoding.');
    prepared.complete();
    await cue;
    expect(events, ['stop', 'stop']);
  });

  test('a new cue can play before obsolete preparation completes', () async {
    final prepared = Completer<void>();
    final loading = Completer<void>();
    final events = <String>[];
    final cues = LatestCue(() async => events.add('stop'));
    final old = cues.replace((isCurrent) async {
      loading.complete();
      await prepared.future;
      if (isCurrent()) events.add('stale');
    });
    await loading.future;
    await cues.replace((_) async => events.add('new cue'));
    expect(events, ['stop', 'stop', 'new cue']);
    prepared.complete();
    await old;
    expect(events, isNot(contains('stale')));
  });

  test('only the latest of several pending prompts is played', () async {
    final events = <String>[];
    final cues = LatestCue(() async => events.add('stop'));
    await Future.wait([
      cues.replace((_) async => events.add('first')),
      cues.replace((_) async => events.add('second')),
      cues.replace((_) async => events.add('latest')),
    ]);
    expect(events, ['stop', 'latest']);
  });

  test('a player failure does not prevent subsequent prompts', () async {
    final cues = LatestCue(() async {});
    await expectLater(
        cues.replace((_) async => throw StateError('decoder failed')),
        throwsStateError);
    var played = false;
    await cues.replace((_) async => played = true);
    expect(played, isTrue);
  });
}
