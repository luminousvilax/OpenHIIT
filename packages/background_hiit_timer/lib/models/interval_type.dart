import 'interval_stage.dart';

class IntervalType {
  String id;
  String workoutId;
  int time;
  String name;
  int color;
  int intervalIndex;
  String startSound;
  String halfwaySound;
  String countdownSound;
  String endSound;
  String stage;

  String get stageType =>
      stage.isEmpty ? IntervalStage.fromLegacyName(name) : stage;

  IntervalType(
      {this.stage = '',
      required this.id,
      required this.workoutId,
      required this.time,
      required this.name,
      required this.color,
      required this.intervalIndex,
      required this.startSound,
      required this.halfwaySound,
      required this.countdownSound,
      required this.endSound});

  // Convert an Interval object to a Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'workoutId': workoutId,
      'time': time,
      'name': name,
      'color': color,
      'intervalIndex': intervalIndex,
      'startSound': startSound,
      'halfwaySound': halfwaySound,
      'countdownSound': countdownSound,
      'endSound': endSound,
      'stage': stage,
    };
  }

  // Copy an Interval object with optional new values
  IntervalType copy(
      {String? id,
      String? workoutId,
      int? time,
      String? name,
      int? color,
      int? intervalIndex,
      String? startSound,
      String? halfwaySound,
      String? countdownSound,
      String? endSound,
      String? stage}) {
    return IntervalType(
      id: id ?? this.id,
      workoutId: workoutId ?? this.workoutId,
      time: time ?? this.time,
      name: name ?? this.name,
      color: color ?? this.color,
      intervalIndex: intervalIndex ?? this.intervalIndex,
      startSound: startSound ?? this.startSound,
      halfwaySound: halfwaySound ?? this.halfwaySound,
      countdownSound: countdownSound ?? this.countdownSound,
      endSound: endSound ?? this.endSound,
      stage: stage ?? this.stage,
    );
  }

  // Create an Interval object from a Map
  factory IntervalType.fromMap(Map<String, dynamic> map) {
    return IntervalType(
      id: map['id'],
      workoutId: map['workoutId'],
      time: map['time'],
      name: map['name'],
      color: map['color'],
      intervalIndex: map['intervalIndex'],
      startSound: map['startSound'],
      halfwaySound: map['halfwaySound'],
      countdownSound: map['countdownSound'],
      endSound: map['endSound'],
      stage: map['stage'] ?? '',
    );
  }

  @override
  String toString() {
    return 'IntervalType{id: $id, workoutId: $workoutId, time: $time, name: $name, color: $color, intervalIndex: $intervalIndex, startSound: $startSound, halfwaySound: $halfwaySound, countdownSound: $countdownSound, endSound: $endSound}';
  }
}
