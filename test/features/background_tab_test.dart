import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/start_save_toggle.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/tabs/background_tab/background_tab.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('scrolls to the Work preview and clears only that stage',
      (tester) async {
    final originalStore = MediaStore.instance;
    MediaStore.instance =
        MediaStore(directory: Directory('/unused-widget-fixture'));
    addTearDown(() => MediaStore.instance = originalStore);
    final draft = TimerCreationProvider()..clear();
    addTearDown(draft.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    const image = 'local:images/fixture.png';
    draft.setBackground('getReady', image);
    draft.setBackground('work', image);
    var edits = 0;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: draft,
      child: MaterialApp(
          home: Scaffold(
              body: BackgroundTab(
        scrollController: controller,
        onEdited: (state) {
          expect(state, StartSaveState.save);
          edits++;
        },
      ))),
    ));
    final clear = find.byKey(const ValueKey('background-work-clear'));
    await tester.scrollUntilVisible(clear, 150,
        scrollable: find.descendant(
            of: find.byType(BackgroundTab), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    final card = find.ancestor(of: clear, matching: find.byType(Card)).first;
    final preview = tester.widget<ManagedBackground>(
        find.descendant(of: card, matching: find.byType(ManagedBackground)));
    expect(preview.reference, image);
    await tester.tap(clear);
    await tester.pump();
    expect(draft.timer.backgrounds.containsKey('work'), isFalse);
    expect(draft.timer.backgrounds['getReady'], image);
    expect(edits, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
