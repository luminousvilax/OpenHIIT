import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:openhiit_audioplayers/openhiit_audioplayers.dart';
import 'package:background_hiit_timer/background_timer_controller.dart';
import 'package:background_hiit_timer/models/interval_type.dart';
import 'package:background_hiit_timer/utils/database.dart';
import 'package:background_hiit_timer/utils/log.dart';
import 'package:background_hiit_timer/models/timer_state.dart';
import 'package:background_hiit_timer/cue_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/constants.dart';

class Countdown extends StatefulWidget {
  /// Timer snapshots are observable even when widget frames are suspended.
  static Stream<Map<String, dynamic>?> get stateEvents =>
      FlutterBackgroundService().on('update');

  /// Reports sources accepted by the native player, not proof of audible output.
  static Stream<Map<String, dynamic>?> get cueEvents =>
      FlutterBackgroundService().on('cuePlayed');

  static Future<bool> isServiceRunning() =>
      FlutterBackgroundService().isRunning();
  final List<IntervalType> intervals;
  final Widget Function(BuildContext, TimerState) build;
  final Function? onFinished;
  final CountdownController? controller;

  const Countdown({
    super.key,
    required this.intervals,
    required this.build,
    this.onFinished,
    this.controller,
  });

  @override
  CountdownState createState() => CountdownState();
}

@pragma('vm:entry-point')
class CountdownState extends State<Countdown> with WidgetsBindingObserver {
  bool isActive = false;
  late final Future<SharedPreferences> _preferences;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _initializeController();
    _preferences = SharedPreferences.getInstance();

    if (widget.controller?.autoStart ?? true) {
      _startTimer();
    }
  }

  void _initializeController() {
    widget.controller?.setOnStart(_startTimer);
    widget.controller?.setOnStop(_stopTimer);
    widget.controller?.setOnPause(_onTimerPaused);
    widget.controller?.setOnResume(_onTimerResumed);
    widget.controller?.setOnRestart(_onTimerRestart);
    widget.controller?.setOnSkipNext(_onTimerSkipNext);
    widget.controller?.setOnSkipPrevious(_onTimerSkipPrevious);
    widget.controller?.isCompleted = false;
  }

  @override
  void dispose() {
    if (isActive) {
      FlutterBackgroundService().invoke("stopService");
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onTimerPaused() async {
    logger.d("Pausing timer");
    if (isActive) {
      FlutterBackgroundService().invoke("pause");
      await (await _preferences).setBool("pause", true);
    }
  }

  void _onTimerResumed() async {
    logger.d("Resuming timer");
    if (isActive) {
      FlutterBackgroundService().invoke("resume");
      await (await _preferences).setBool("pause", false);
    }
  }

  void _onTimerRestart() {
    logger.d("Restarting timer");
    FlutterBackgroundService().invoke("restartService");
  }

  void _onTimerSkipNext() {
    logger.d("Skipping to next interval");
    FlutterBackgroundService().invoke("skipNext");
  }

  void _onTimerSkipPrevious() {
    logger.d("Skipping to previous interval");
    FlutterBackgroundService().invoke("skipPrevious");
  }

  void _startTimer() async {
    logger.d("Starting timer");
    setState(() => isActive = true);

    // Ensure the 'pause' shared preference is set to false when the timer starts
    SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setBool("pause", false);

    await _initializeService();
    widget.controller?.isCompleted = false;
  }

  void _stopTimer() {
    logger.d("Stopping timer");
    setState(() => isActive = false);
    FlutterBackgroundService().invoke("stopService");
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: FlutterBackgroundService().on('update'),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final data = snapshot.data!;
        final TimerState timerState = TimerState.fromMap(data);

        return widget.build(context, timerState);
      },
    );
  }

  Future<void> _initializeService() async {
    final service = FlutterBackgroundService();

    // Database setup
    DatabaseManager dbManager = DatabaseManager();
    await dbManager.clearDatabaseIfNotEmpty();
    await dbManager.openIntervalDatabase();
    await dbManager.insertIntervals(widget.intervals);

    // Initialize notification channels for Android/iOS
    await _setupNotifications();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: true,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: 'timer_foreground',
          initialNotificationTitle: 'TIMER',
          initialNotificationContent: 'Initializing',
          foregroundServiceNotificationId: 888,
          foregroundServiceTypes: [AndroidForegroundType.mediaPlayback]),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    service.startService();
  }

  Future<void> _setupNotifications() async {
    const channel = AndroidNotificationChannel(
      'timer_foreground',
      'TIMER',
      description: 'This channel is used for important notifications.',
      importance: Importance.low,
    );

    final notificationsPlugin = FlutterLocalNotificationsPlugin();

    if (Platform.isIOS || Platform.isAndroid) {
      await notificationsPlugin.initialize(
        const InitializationSettings(
          iOS: DarwinInitializationSettings(),
          android: AndroidInitializationSettings('ic_bg_service_small'),
        ),
      );
    }

    await notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    SharedPreferences preferences = await SharedPreferences.getInstance();
    double volume = preferences.getDouble("volume") ?? 80.0;
    bool changeVolume = preferences.getBool("changeVolume") ?? false;

    DatabaseManager dbManager = DatabaseManager();
    List<IntervalType> intervals = await dbManager.getIntervals();

    IntervalType currentInterval = intervals[0];
    TimerState timerState = TimerState(
        false,
        currentInterval.name,
        0,
        currentInterval.time * secondsFactor,
        currentInterval.time * secondsFactor,
        volume,
        changeVolume);

    _registerServiceEvents(service, intervals, preferences, timerState);
  }

  static Future<void> _registerServiceEvents(
    ServiceInstance service,
    List<IntervalType> intervals,
    SharedPreferences preferences,
    TimerState timerState,
  ) async {
    await AudioPlayer.global.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers)
            .build());

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });

      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    final cues = CuePlayer(onPlayed: (source, fallback) {
      service.invoke('cuePlayed', {'source': source, 'fallback': fallback});
    });
    final keepAlive = AudioPlayer();
    keepAlive.audioCache =
        AudioCache(prefix: 'packages/background_hiit_timer/assets/');
    await keepAlive.setPlayerMode(PlayerMode.lowLatency);
    await keepAlive.setVolume(0);
    Timer? ticker;
    bool stopped = false;

    service.on('pause').listen((_) {
      timerState.paused = true;
      unawaited(cues.stop());
    });
    service.on('resume').listen((_) {
      timerState.paused = false;
    });

    service.on('restartService').listen((_) {
      unawaited(cues.stop());
      final paused = timerState.paused;
      timerState.reset(intervals);
      timerState.paused = paused;
    });

    service.on('skipNext').listen((_) {
      unawaited(cues.stop());
      timerState.advanceToNextInterval(intervals);
    });

    service.on('skipPrevious').listen((_) {
      unawaited(cues.stop());
      if (timerState.currentInterval > 0) {
        timerState.currentInterval--;
        timerState.currentMicroSeconds =
            intervals[timerState.currentInterval].time * secondsFactor;
        timerState.intervalMicroSeconds =
            intervals[timerState.currentInterval].time * secondsFactor;
        timerState.status = intervals[timerState.currentInterval].name;
      }
    });

    service.on('stopService').listen((_) async {
      stopped = true;
      ticker?.cancel();
      await cues.dispose();
      await keepAlive.dispose();
      service.stopSelf();
    });

    ticker = Timer.periodic(interval, (timer) {
      if (stopped) return;
      if (timerState.currentMicroSeconds <= 0) {
        timerState.status = "End";
      } else if (!timerState.paused && timerState.currentMicroSeconds > 0) {
        timerState.currentMicroSeconds -= interval.inMicroseconds;

        int intervalIndex = timerState.currentInterval;
        int nextIntervalIndex = intervalIndex + 1;

        if ([1500000, 2500000, 3500000]
            .contains(timerState.currentMicroSeconds)) {
          unawaited(cues.play(
              intervals[intervalIndex].countdownSound, preferences,
              fallback: 'countdown-beep'));
        } else if (timerState.currentMicroSeconds ==
            timerState.intervalMicroSeconds ~/ 2) {
          unawaited(cues.play(
              intervals[intervalIndex].halfwaySound, preferences,
              fallback: 'short-halfway-beep'));
        } else if (timerState.currentMicroSeconds == 700000) {
          if (intervalIndex < intervals.length - 1) {
            String sound = intervals[nextIntervalIndex].startSound;
            if (sound != "" && sound != "none") {
              final stage = intervals[nextIntervalIndex].stageType;
              final fallback = stage == 'breakTime'
                  ? 'horn'
                  : (stage == 'rest' || stage == 'cooldown')
                      ? 'short-rest-beep'
                      : 'short-whistle';
              unawaited(cues.play(sound, preferences, fallback: fallback));
            } else if (intervals[intervalIndex].endSound != "" &&
                intervals[intervalIndex].endSound != "none") {
              unawaited(cues.play(
                  intervals[intervalIndex].endSound, preferences,
                  fallback: 'long-bell'));
            }
          } else {
            unawaited(cues.play(intervals[intervalIndex].endSound, preferences,
                fallback: 'long-bell'));
          }
        } else if (timerState.currentMicroSeconds == 0 &&
            intervalIndex < intervals.length - 1) {
          logger.d("Advancing to next interval");
          timerState.advanceToNextInterval(intervals);
        } else if (timerState.currentMicroSeconds % 1000000 == 0 &&
            timerState.currentMicroSeconds > 700000) {
          unawaited(keepAlive.play(AssetSource('audio/$blankSoundFile.mp3')));
        }
      }

      service.invoke('update', timerState.toMap());
    });
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }
}
