import 'dart:convert';

import 'package:openhiit/core/models/timer_sound_settings.dart';
import 'package:openhiit/core/models/timer_time_settings.dart';
import 'package:uuid/uuid.dart';

class TimerType {
  String id;
  String name;
  int timerIndex;
  int totalTime;
  int intervals;
  int activeIntervals;
  List<String> activities;
  int showMinutes;
  int color;
  TimerTimeSettings timeSettings;
  TimerSoundSettings soundSettings;
  Map<String, String> backgrounds;

  TimerType({
    required this.id,
    required this.name,
    required this.timerIndex,
    required this.timeSettings,
    required this.soundSettings,
    Map<String, String>? backgrounds,
    this.totalTime = 0,
    this.intervals = 0,
    this.activeIntervals = 0,
    this.activities = const [],
    this.showMinutes = 0,
    this.color = 4280391411, // blue
  }) : backgrounds = Map.of(backgrounds ?? {});

  TimerType.empty()
      : id = "",
        name = "",
        timerIndex = 0,
        timeSettings = TimerTimeSettings.empty(),
        soundSettings = TimerSoundSettings.empty(),
        backgrounds = {},
        totalTime = 0,
        intervals = 0,
        activeIntervals = 0,
        activities = [],
        showMinutes = 0,
        color = 4280391411; // blue

  TimerType copy() {
    return TimerType(
      id: id,
      name: name,
      timerIndex: timerIndex,
      timeSettings: timeSettings,
      soundSettings: soundSettings,
      backgrounds: backgrounds,
      totalTime: totalTime,
      intervals: intervals,
      activeIntervals: activeIntervals,
      activities: activities,
      showMinutes: showMinutes,
      color: color,
    );
  }

  TimerType copyNew() {
    String newId = Uuid().v1();

    return TimerType(
      id: newId,
      name: name,
      timerIndex: timerIndex,
      timeSettings: timeSettings.copyWithTimerId(newId),
      soundSettings: soundSettings.copyWithTimerId(newId),
      backgrounds: backgrounds,
      totalTime: totalTime,
      intervals: intervals,
      activeIntervals: activeIntervals,
      activities: activities,
      showMinutes: showMinutes,
      color: color,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'timerIndex': timerIndex,
      'totalTime': totalTime,
      'intervals': intervals,
      'activeIntervals': activeIntervals,
      'activities': jsonEncode(activities),
      'backgrounds': jsonEncode(backgrounds),
      'showMinutes': showMinutes,
      'color': color,
    };
  }

  TimerType.fromMap(Map<String, dynamic> map)
      : id = map['id'] ?? "",
        name = map['name'] ?? "",
        timerIndex = map['timerIndex'] ?? 0,
        timeSettings = TimerTimeSettings.fromMap(map),
        soundSettings = TimerSoundSettings.fromMap(map),
        backgrounds =
            Map<String, String>.from(jsonDecode(map['backgrounds'] ?? '{}')),
        totalTime = map['totalTime'] ?? 0,
        intervals = map['intervals'] ?? 0,
        activeIntervals = map['activeIntervals'] ?? 0,
        activities = map['activities'] != null
            ? List<String>.from(jsonDecode(map['activities']))
            : [],
        showMinutes = map['showMinutes'] ?? 0,
        color = map['color'] ?? 4280391411;

  TimerType copyWith(Map<String, dynamic> updates) {
    return TimerType(
      id: updates['id'] ?? id,
      name: updates['name'] ?? name,
      timerIndex: updates['timerIndex'] ?? timerIndex,
      timeSettings: updates['timeSettings'] is TimerTimeSettings
          ? updates['timeSettings']
          : updates['timeSettings'] != null
              ? TimerTimeSettings.fromJson(updates['timeSettings'])
              : timeSettings,
      soundSettings: updates['soundSettings'] is TimerSoundSettings
          ? updates['soundSettings']
          : updates['soundSettings'] != null
              ? TimerSoundSettings.fromJson(updates['soundSettings'])
              : soundSettings,
      backgrounds: updates['backgrounds'] ?? backgrounds,
      totalTime: updates['totalTime'] ?? totalTime,
      intervals: updates['intervals'] ?? intervals,
      activeIntervals: updates['activeIntervals'] ?? activeIntervals,
      activities: updates['activities'] ?? activities,
      showMinutes: updates['showMinutes'] ?? showMinutes,
      color: updates['color'] ?? color,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'timerIndex': timerIndex,
      'totalTime': totalTime,
      'intervals': intervals,
      'activeIntervals': activeIntervals,
      'activities': activities,
      'showMinutes': showMinutes,
      'color': color,
      'timeSettings': timeSettings.toJson(),
      'soundSettings': soundSettings.toJson(),
    };
  }

  factory TimerType.fromJson(Map<String, dynamic> json) {
    final timeSettings = json['timeSettings'];
    final soundSettings = json['soundSettings'];

    return TimerType(
      id: json['id'] ?? "",
      name: json['name'] ?? "",
      timerIndex: json['timerIndex'] ?? 0,
      totalTime: json['totalTime'] ?? 0,
      intervals: json['intervals'] ?? 0,
      activeIntervals: json['activeIntervals'] ?? 0,
      activities: (json['activities'] != null && json['activities'] is List)
          ? List<String>.from(json['activities'])
          : [],
      showMinutes: json['showMinutes'] ?? 0,
      color: json['color'] ?? 4280391411,
      timeSettings: timeSettings is String
          ? TimerTimeSettings.fromJson(
              jsonDecode(timeSettings) as Map<String, dynamic>)
          : TimerTimeSettings.fromJson(timeSettings),
      soundSettings: soundSettings is String
          ? TimerSoundSettings.fromJson(
              jsonDecode(soundSettings) as Map<String, dynamic>)
          : TimerSoundSettings.fromJson(soundSettings),
    );
  }

  @override
  String toString() {
    return 'TimerType{id: $id, name: $name, totalTime: $totalTime, intervals: $intervals, showMinutes: $showMinutes, activeIntervals: $activeIntervals, activities: $activities, color: $color, timerIndex: $timerIndex}';
  }
}
