import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/features/settings/ui/storage_cleanup_tile.dart';

class _Store extends MediaStore {
  var cleanCalls = 0;
  List<CleanupItem> candidates = [CleanupItem('unused', File('/unused'), 1024)];
  @override
  Future<List<CleanupItem>> scanUnused() async => candidates;
  @override
  Future<CleanupResult> cleanUnused() async {
    cleanCalls++;
    return const CleanupResult(1, 1024, 0);
  }
}

void main() {
  late MediaStore original;
  late _Store store;
  setUp(() {
    original = MediaStore.instance;
    store = _Store();
    MediaStore.instance = store;
  });
  tearDown(() => MediaStore.instance = original);

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: StorageCleanupTile())));
    await tester.tap(find.byKey(const Key('clean-unused-media')));
    await tester.pumpAndSettle();
  }

  testWidgets('explains cleanup and cancellation never deletes files',
      (tester) async {
    await open(tester);
    expect(find.text('Clean unused media?'), findsOneWidget);
    expect(
        find.textContaining(
            'original files outside the app will not be deleted'),
        findsOneWidget);
    expect(store.cleanCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.cleanCalls, 0);
  });

  testWidgets('requires the second confirmation before deleting',
      (tester) async {
    await open(tester);
    expect(store.cleanCalls, 0);
    await tester.tap(find.byKey(const Key('confirm-clean-unused-media')));
    await tester.pumpAndSettle();
    expect(store.cleanCalls, 1);
    expect(find.textContaining('Removed 1 unused file(s)'), findsOneWidget);
  });

  testWidgets('reports no unused files without showing a deletion dialog',
      (tester) async {
    store.candidates = [];
    await open(tester);
    expect(find.text('No unused media to clean.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.cleanCalls, 0);
  });
}
