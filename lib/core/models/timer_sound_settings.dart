import 'package:background_hiit_timer/media_files.dart';
import 'package:uuid/uuid.dart';

class TimerSoundSettings {
  static const defaults = {
    'workSound': 'short-whistle',
    'restSound': 'short-rest-beep',
    'halfwaySound': 'short-halfway-beep',
    'endSound': 'long-bell',
    'countdownSound': 'countdown-beep',
    'breakSound': 'horn',
  };

  String id;
  String timerId;
  String workSound;
  String restSound;
  String halfwaySound;
  String endSound;
  String countdownSound;
  String breakSound;

  TimerSoundSettings(
      {required this.id,
      required this.timerId,
      required this.workSound,
      required this.restSound,
      required this.halfwaySound,
      required this.endSound,
      required this.countdownSound,
      required this.breakSound});

  TimerSoundSettings.empty()
      : id = "",
        timerId = "",
        workSound = "short-whistle",
        restSound = "short-rest-beep",
        halfwaySound = "short-halfway-beep",
        endSound = "long-bell",
        countdownSound = "countdown-beep",
        breakSound = "horn";

  TimerSoundSettings copyWith(
    Map<String, String> map, {
    Map<String, dynamic>? updates,
  }) {
    return TimerSoundSettings(
      id: updates?['id'] ?? id,
      timerId: updates?['timerId'] ?? timerId,
      workSound: updates?['workSound'] ?? workSound,
      restSound: updates?['restSound'] ?? restSound,
      halfwaySound: updates?['halfwaySound'] ?? halfwaySound,
      endSound: updates?['endSound'] ?? endSound,
      countdownSound: updates?['countdownSound'] ?? countdownSound,
      breakSound: updates?['breakSound'] ?? breakSound,
    );
  }

  TimerSoundSettings copyWithTimerId(String newTimerId) {
    String newId = Uuid().v4();

    return TimerSoundSettings(
      id: newId,
      timerId: newTimerId,
      workSound: workSound,
      restSound: restSound,
      halfwaySound: halfwaySound,
      endSound: endSound,
      countdownSound: countdownSound,
      breakSound: breakSound,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timerId': timerId,
      'workSound': workSound,
      'restSound': restSound,
      'halfwaySound': halfwaySound,
      'endSound': endSound,
      'countdownSound': countdownSound,
      'breakSound': breakSound,
    };
  }

  TimerSoundSettings.fromMap(Map<String, dynamic> map)
      : id = map['id'] ?? "",
        timerId = map['timerId'] ?? "",
        workSound = map['workSound'] ?? "",
        restSound = map['restSound'] ?? "",
        halfwaySound = map['halfwaySound'] ?? "",
        endSound = map['endSound'] ?? "",
        countdownSound = map['countdownSound'] ?? "",
        breakSound = _resolveBreakSound(map.containsKey('breakSound'),
            map['breakSound'], map['restSound'] ?? "");

  /// Portable configuration exports never contain installation-local media.
  Map<String, dynamic> toJson() {
    final map = toMap();
    for (final key in defaults.keys) {
      if (MediaFiles.isLocal(map[key] as String)) map[key] = defaults[key];
    }
    return map;
  }

  factory TimerSoundSettings.fromJson(Map<String, dynamic> json) {
    json = Map.of(json);
    for (final key in defaults.keys) {
      final value = json[key];
      if (value is String && MediaFiles.isLocal(value)) {
        json[key] = defaults[key];
      }
    }
    return TimerSoundSettings(
      id: json['id'] ?? "",
      timerId: json['timerId'] ?? "",
      workSound: json['workSound'] ?? "",
      restSound: json['restSound'] ?? "",
      halfwaySound: json['halfwaySound'] ?? "",
      endSound: json['endSound'] ?? "",
      countdownSound: json['countdownSound'] ?? "",
      breakSound: _resolveBreakSound(json.containsKey('breakSound'),
          json['breakSound'], json['restSound'] ?? ""),
    );
  }

  static String _resolveBreakSound(
      bool breakSoundPresent, dynamic rawBreakSound, String restSound) {
    if (!breakSoundPresent) {
      return restSound.isNotEmpty ? restSound : '';
    }

    final String breakSoundValue =
        rawBreakSound is String ? rawBreakSound.trim() : "";
    if (breakSoundValue.isEmpty || breakSoundValue.toLowerCase() == 'none') {
      return "";
    }
    return breakSoundValue;
  }

  @override
  String toString() {
    return 'TimerSoundSettings{id: $id, timerId: $timerId, workSound: $workSound, restSound: $restSound, halfwaySound: $halfwaySound, endSound: $endSound, countdownSound: $countdownSound, breakSound: $breakSound}';
  }
}
