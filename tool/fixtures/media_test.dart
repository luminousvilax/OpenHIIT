import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:background_hiit_timer/background_timer.dart';
import 'package:background_hiit_timer/background_timer_controller.dart';
import 'package:background_hiit_timer/cue_player.dart';
import 'package:background_hiit_timer/media_files.dart';
import 'package:background_hiit_timer/models/timer_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/core/providers/interval_provider/interval_provider.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/core/providers/timer_provider/timer_provider.dart';
import 'package:openhiit/features/edit_timer/ui/edit_timer.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/tabs/background_tab/background_tab.dart';
import 'package:openhiit/features/settings/ui/storage_cleanup_tile.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late TimerProvider timers;
  late TimerCreationProvider draft;
  late String audio;
  late String image;

  setUpAll(() async {
    final info = await PackageInfo.fromPlatform();
    if (info.packageName != 'com.codepup.workout_timer.media_test') {
      throw StateError(
          'Run through tool/test_android_media.py so the source manifest, namespace, and built package all use the test identity.');
    }
    await WakelockPlus.enable();
    GoogleFonts.config.allowRuntimeFetching = false;
    final temp = await getTemporaryDirectory();
    const samples = 4000;
    final wave = ByteData(44 + samples * 2);
    wave.buffer.asUint8List().setRange(0, 4, 'RIFF'.codeUnits);
    wave.setUint32(4, wave.lengthInBytes - 8, Endian.little);
    wave.buffer.asUint8List().setRange(8, 16, 'WAVEfmt '.codeUnits);
    wave.setUint32(16, 16, Endian.little);
    wave.setUint16(20, 1, Endian.little);
    wave.setUint16(22, 1, Endian.little);
    wave.setUint32(24, 8000, Endian.little);
    wave.setUint32(28, 16000, Endian.little);
    wave.setUint16(32, 2, Endian.little);
    wave.setUint16(34, 16, Endian.little);
    wave.buffer.asUint8List().setRange(36, 40, 'data'.codeUnits);
    wave.setUint32(40, samples * 2, Endian.little);
    for (var i = 0; i < samples; i++) {
      wave.setInt16(
          44 + i * 2,
          (math.sin(i * 2 * math.pi * 440 / 8000) * 4000).round(),
          Endian.little);
    }
    final wav = File('${temp.path}/media_test_cue.wav');
    await wav.writeAsBytes(wave.buffer.asUint8List());
    audio = await MediaStore.instance.importFile(wav, audio: true);
    final png = File('${temp.path}/media_test_background.png');
    await png.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNQSJgARAwQCgAcDgRBIqsFewAAAABJRU5ErkJggg=='));
    image = await MediaStore.instance.importFile(png, audio: false);
    await wav.delete();
    await png.delete();

    timers = TimerProvider()..setIntervalProvider(IntervalProvider());
    await timers.loadTimers();
    draft = TimerCreationProvider()..clear();
    draft.setTimerName('Media acceptance fixture');
    draft.setActiveIntervals(2);
    draft.setTimerTimeSettingPart(getReadyTime: 5, workTime: 5, restTime: 3);
    draft.setSound('workSound', audio);
    draft.setSound('restSound', audio);
    draft.setBackground('getReady', image);
    draft.setBackground('work', image);
    await timers.pushTimer(draft.timer);
    MediaStore.instance.releasePending(audio);
    MediaStore.instance.releasePending(image);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('volume', 30);
  });

  tearDownAll(() async {
    await WakelockPlus.disable();
    if (timers.timers.any((timer) => timer.id == draft.timer.id)) {
      await timers.deleteTimer(draft.timer);
    }
    timers.dispose();
    draft.dispose();
  });

  Future<void> until(WidgetTester tester, bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!predicate() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(predicate(), isTrue,
        reason: 'Timed out waiting for the native timer service.');
  }

  testWidgets('device persistence, native audio, and confirmed media cleanup',
      (tester) async {
    final loaded = (await timers.loadTimers())
        .singleWhere((timer) => timer.id == draft.timer.id);
    expect(loaded.soundSettings.workSound, audio);
    expect(loaded.backgrounds['work'], image);
    expect(await (await MediaStore.instance.file(audio)).exists(), isTrue);
    expect(await (await MediaStore.instance.file(image)).exists(), isTrue);
    final accepted = <String>[];
    final player =
        CuePlayer(onPlayed: (source, fallback) => accepted.add(source));
    final preferences = await SharedPreferences.getInstance();
    await player.play(audio, preferences, fallback: 'short-whistle');
    expect(accepted, [audio]);
    expect(preferences.getString(MediaFiles.failureKey(audio)), isNull);
    await player.stop();
    await player.play('local:audio/missing.wav', preferences,
        fallback: 'short-whistle');
    expect(accepted.last, 'short-whistle');
    expect(
        preferences.getString(MediaFiles.failureKey('local:audio/missing.wav')),
        isNotNull);
    await player.dispose();

    final orphan = await MediaStore.instance
        .importFile(await MediaStore.instance.file(audio), audio: true);
    MediaStore.instance.releasePending(orphan);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: StorageCleanupTile())));
    await tester.tap(find.byKey(const Key('clean-unused-media')));
    await until(
        tester, () => find.text('Clean unused media?').evaluate().isNotEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await (await MediaStore.instance.file(orphan)).exists(), isTrue);
    await tester.tap(find.byKey(const Key('clean-unused-media')));
    await until(
        tester, () => find.text('Clean unused media?').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('confirm-clean-unused-media')));
    await until(
        tester,
        () =>
            find.textContaining('unused file(s). Freed').evaluate().isNotEmpty);
    expect(await (await MediaStore.instance.file(orphan)).exists(), isFalse);
    expect(await (await MediaStore.instance.file(audio)).exists(), isTrue);
    expect(await (await MediaStore.instance.file(image)).exists(), isTrue);
  });

  testWidgets('Background follows Sound and retains saved stage previews',
      (tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: draft),
        ChangeNotifierProvider.value(value: timers),
      ],
      child: const MaterialApp(home: EditTimer(editing: true)),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    final tabs =
        tester.widget<TabBar>(find.byType(TabBar)).tabs.cast<Tab>().toList();
    expect(tabs.map((tab) => tab.key), [
      const Key('general-tab'),
      const Key('sound-tab'),
      const Key('background-tab'),
      const Key('edit-tab')
    ]);
    await tester.tap(find.byKey(const Key('background-tab')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Background'), findsOneWidget);
    final scrollable = find.descendant(
        of: find.byType(BackgroundTab), matching: find.byType(Scrollable));
    for (final stage in ['getReady', 'work']) {
      final action = find.byKey(ValueKey('background-$stage-clear'));
      await tester.scrollUntilVisible(action, 150, scrollable: scrollable);
      await tester.pump(const Duration(milliseconds: 200));
      final card = find.ancestor(of: action, matching: find.byType(Card)).first;
      final background = tester.widget<ManagedBackground>(
          find.descendant(of: card, matching: find.byType(ManagedBackground)));
      expect(background.reference, image);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('service plays custom sources and preserves timer controls',
      (tester) async {
    final controller = CountdownController(autoStart: true);
    TimerState? state;
    final cues = <Map<String, dynamic>>[];
    final subscription = Countdown.cueEvents.listen((event) {
      if (event != null) cues.add(event);
    });
    addTearDown(subscription.cancel);
    final intervals = await timers.getIntervalsForTimer(draft.timer.id);
    await tester.pumpWidget(MaterialApp(
        home: Countdown(
      controller: controller,
      intervals: intervals,
      build: (_, value) {
        state = value;
        return Text(value.status);
      },
    )));
    await until(tester, () => state != null);
    await controller.pause();
    await until(tester, () => state!.paused);
    final pausedTime = state!.currentMicroSeconds;
    await tester.pump(const Duration(milliseconds: 600));
    expect(state!.currentMicroSeconds, pausedTime);
    controller.restart();
    await until(
        tester,
        () =>
            state!.paused &&
            state!.currentInterval == 0 &&
            state!.currentMicroSeconds == 5000000);
    controller.resume();
    await until(tester,
        () => !state!.paused && state!.currentMicroSeconds < pausedTime);
    controller.skipNext();
    await until(tester, () => state!.currentInterval == 1);
    controller.skipPrevious();
    await until(tester, () => state!.currentInterval == 0);
    controller.restart();
    await until(
        tester,
        () =>
            state!.currentInterval == 0 &&
            state!.currentMicroSeconds > 4000000);
    await until(
        tester,
        () => cues.any(
            (event) => event['source'] == audio && event['fallback'] == false));
    await until(tester, () => state!.currentInterval == 1);
    await expectLater(
        MediaStore.instance.cleanUnused(), throwsA(isA<MediaBusyException>()));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await until(tester, () => state != null); // Yield after disposal.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await Countdown.isServiceRunning() &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(await Countdown.isServiceRunning(), isFalse);
  });

  if (const bool.fromEnvironment('MEDIA_BACKGROUND_CHECKS')) {
    testWidgets(
        'custom cues and timer progress survive background and lock screen',
        (tester) async {
      final controller = CountdownController(autoStart: true);
      TimerState? latest;
      var phase = 'foreground';
      final accepted = <String>[];
      final states = Countdown.stateEvents.listen((data) {
        if (data != null) latest = TimerState.fromMap(data);
      });
      final cueEvents = Countdown.cueEvents.listen((data) {
        if (data?['source'] == audio && data?['fallback'] == false) {
          accepted.add(phase);
        }
      });
      addTearDown(states.cancel);
      addTearDown(cueEvents.cancel);
      await tester.pumpWidget(MaterialApp(
          home: Countdown(
        controller: controller,
        intervals: await timers.getIntervalsForTimer(draft.timer.id),
        build: (_, state) => Text(state.status),
      )));
      await until(tester, () => latest != null);
      phase = 'background';
      debugPrint('[MEDIA-TEST] BACKGROUND_READY');
      await Future<void>.delayed(const Duration(seconds: 6));
      final backgroundAdvanced = latest!.currentInterval >= 1;
      final backgroundInactive =
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
      phase = 'locked';
      debugPrint('[MEDIA-TEST] LOCK_READY');
      await Future<void>.delayed(const Duration(seconds: 8));
      final lockedAdvanced = latest!.currentInterval >= 2;
      final lockedInactive =
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
      controller.stop();
      debugPrint('[MEDIA-TEST] UNLOCK_REQUIRED');
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
              DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(backgroundInactive, isTrue,
          reason: 'The host must actually background the app.');
      expect(lockedInactive, isTrue,
          reason: 'The host must keep the app inactive while locked.');
      expect(backgroundAdvanced, isTrue);
      expect(lockedAdvanced, isTrue);
      expect(accepted, contains('background'));
      expect(accepted, contains('locked'));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  }
}
