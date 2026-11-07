import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/features/edit_timer/ui/edit_timer.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('four editor destinations fit a short landscape screen', (tester) async {
    tester.view.physicalSize = const Size(900, 380);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final draft = TimerCreationProvider()..clear();
    addTearDown(draft.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: draft,
      child: const MaterialApp(home: EditTimer()),
    ));
    await tester.pump();
    expect(find.text('Background'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
