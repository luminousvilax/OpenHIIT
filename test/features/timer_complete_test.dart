import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/features/run_timer/widgets/timer_complete.dart';

void main() {
  Future<void> showCompletion(WidgetTester tester,
      {VoidCallback? onRestart, bool visible = true}) async {
    final controller = ConfettiController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      initialRoute: '/complete',
      routes: {
        '/': (_) => const Scaffold(body: Text('Home')),
        '/complete': (_) => Scaffold(
              body: TimerComplete(
                controller: controller,
                visible: visible,
                onRestart: onRestart,
                timerName: 'Test workout',
              ),
            ),
      },
    ));
  }

  Future<void> doubleTapAt(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
  }

  for (final size in [const Size(400, 800), const Size(800, 400)]) {
    testWidgets('double taps outside buttons restart in $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var restarts = 0;
      await showCompletion(tester, onRestart: () => restarts++);

      final title = tester.getRect(find.text('Nice job!'));
      final name = tester.getRect(find.text('Completed: Test workout'));
      final back = tester.getRect(find.byKey(const Key('timer-end-back')));
      final restart = tester.getRect(find.byKey(const Key('restart')));
      final positions = [
        const Offset(1, 1),
        Offset(size.width - 1, size.height - 1),
        Offset(1, size.height / 2),
        Offset(size.width - 1, size.height / 2),
        title.center,
        name.center,
        Offset(size.width / 2, (name.bottom + back.top) / 2),
        Offset(size.width / 2, (back.bottom + restart.top) / 2),
        size.center(Offset.zero),
      ];
      for (final position in positions) {
        final before = restarts;
        await doubleTapAt(tester, position);
        expect(restarts, before + 1, reason: 'Double tap at $position');
      }
    });
  }

  testWidgets('single taps outside buttons do not restart', (tester) async {
    var restarts = 0;
    await showCompletion(tester, onRestart: () => restarts++);
    for (final position in [
      const Offset(10, 10),
      tester.getCenter(find.text('Nice job!')),
      tester.getCenter(find.text('Completed: Test workout')),
    ]) {
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 350));
    }
    expect(restarts, 0);
  });

  testWidgets('Restart button keeps immediate single tap behavior',
      (tester) async {
    var restarts = 0;
    await showCompletion(tester, onRestart: () => restarts++);
    final position = tester.getCenter(find.byKey(const Key('restart')));
    await tester.tapAt(position);
    expect(restarts, 1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(position);
    expect(restarts, 2);
    await tester.pump(const Duration(milliseconds: 350));
    expect(restarts, 2, reason: 'No additional background double tap callback');
  });

  testWidgets('Back button pops the page without restarting', (tester) async {
    var restarts = 0;
    await showCompletion(tester, onRestart: () => restarts++);
    final position = tester.getCenter(find.byKey(const Key('timer-end-back')));
    await tester.tapAt(position);
    expect(Navigator.of(tester.element(find.byType(TimerComplete))).canPop(),
        isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Home'), findsOneWidget);
    expect(restarts, 0);
  });

  testWidgets('hidden completion page does not handle double taps',
      (tester) async {
    var restarts = 0;
    await showCompletion(tester, onRestart: () => restarts++, visible: false);
    await doubleTapAt(tester, const Offset(10, 10));
    expect(restarts, 0);
  });
}
