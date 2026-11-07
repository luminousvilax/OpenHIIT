import 'package:background_hiit_timer/models/interval_stage.dart';
import 'package:background_hiit_timer/media_files.dart';
import 'package:background_hiit_timer/models/interval_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/models/timer_sound_settings.dart';
import 'package:openhiit/core/models/timer_type.dart';
import 'package:openhiit/core/utils/interval_calculation.dart';

void main() {
  const sound = 'local:audio/fixture_cue.wav';
  const image = 'local:images/fixture_background.png';

  test('database maps preserve media while portable JSON omits local media',
      () {
    final timer = TimerType.empty();
    timer.backgrounds['work'] = image;
    timer.soundSettings.workSound = sound;
    timer.soundSettings.restSound = '';
    final persisted = TimerType.fromMap(timer.toMap());
    persisted.soundSettings =
        TimerSoundSettings.fromMap(timer.soundSettings.toMap());
    expect(persisted.backgrounds['work'], image);
    expect(persisted.soundSettings.workSound, sound);
    final exported = timer.toJson();
    expect(exported.toString(), isNot(contains('local:')));
    final imported = TimerType.fromJson(exported);
    expect(imported.backgrounds, isEmpty);
    expect(imported.soundSettings.workSound,
        TimerSoundSettings.defaults['workSound']);
    expect(imported.soundSettings.restSound, '');
  });

  test('imports do not trust media references from another installation', () {
    final json = TimerType.empty().toJson();
    (json['soundSettings'] as Map<String, dynamic>)['countdownSound'] = sound;
    json['backgrounds'] = {'work': image};
    final imported = TimerType.fromJson(json);
    expect(imported.soundSettings.countdownSound, 'countdown-beep');
    expect(imported.backgrounds, isEmpty);
  });

  test('cropped display policy survives persistence and timer copies', () {
    const cropped =
        'local:images/crop1-01234567-89ab-cdef-0123-456789abcdef_photo.png';
    final timer = TimerType.empty()..backgrounds['work'] = cropped;
    final loaded = TimerType.fromMap(timer.toMap());
    expect(MediaFiles.isCroppedImage(loaded.backgrounds['work']!), isTrue);
    final copy = loaded.copyNew();
    copy.backgrounds.clear();
    expect(loaded.backgrounds['work'], cropped);
    expect(timer.toJson().toString(), isNot(contains('local:')));
  });

  test('copies retain media references with independent background maps', () {
    final timer = TimerType.empty()..backgrounds['work'] = image;
    timer.soundSettings.workSound = sound;
    final copy = timer.copyNew();
    expect(copy.backgrounds, timer.backgrounds);
    expect(copy.soundSettings.workSound, sound);
    copy.backgrounds.clear();
    expect(timer.backgrounds['work'], image);
  });

  test('stage identity does not depend on the user supplied Work name', () {
    final timer = TimerType.empty();
    timer.activeIntervals = 2;
    timer.activities = ['Rest', 'Squat'];
    timer.timeSettings.workTime = 4;
    timer.timeSettings.restTime = 2;
    timer.timeSettings.warmupTime = 2;
    timer.timeSettings.cooldownTime = 2;
    timer.timeSettings.breakTime = 3;
    timer.timeSettings.restarts = 1;
    final intervals = generateIntervalsFromTimer(timer);
    expect(intervals.where((i) => i.stageType == IntervalStage.work.name),
        hasLength(4));
    expect(intervals.first.stageType, 'getReady');
    expect(intervals.last.stageType, 'cooldown');
    expect(intervals.where((i) => i.stageType == 'breakTime'), hasLength(1));
    for (final interval in intervals) {
      expect(
          IntervalType.fromMap(interval.toMap()).stageType, interval.stageType);
    }
  });
}
