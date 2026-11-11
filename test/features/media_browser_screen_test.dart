import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_browser.dart';
import 'package:openhiit/shared/ui/widgets/media_browser_screen.dart';
import '../helpers/crop_image.dart';

class FakeBrowser extends MediaBrowser {
  FakeBrowser({this.audio = false})
      : preferences = BrowserPreferences(audio: audio);
  final bool audio;
  BrowserLocation saved =
      const BrowserLocation(directory: 'external_primary/Pictures/');
  String? file = 'image';
  String? name = 'Background.png';
  String permission = 'full';
  final folders = <Map<Object?, Object?>>[];
  final BrowserPreferences preferences;
  Uint8List? thumbnailBytes;
  final listings = <String, List<BrowserEntry>>{};
  final browsed = <BrowserLocation>[];
  bool failList = false;
  bool failSelect = false;
  int viewWrites = 0;
  int selectionWrites = 0;
  int requests = 0;
  Completer<String?>? copying;

  Map<Object?, Object?> snapshot() => {
        'location': saved.toMap(),
        'file': file,
        'name': name,
        'permission': permission,
        'folders': folders,
        'sort': preferences.sort,
        'ascending': preferences.ascending,
        'grid': preferences.grid,
        'showNames': preferences.showNames,
        'largePreviews': preferences.largePreviews,
      };
  @override
  Future<Map<Object?, Object?>> state(bool audio,
          {bool initialize = false}) async =>
      snapshot();
  @override
  Future<Map<Object?, Object?>> requestPermission(bool audio) async {
    requests++;
    permission = 'full';
    return snapshot();
  }

  @override
  Future<List<BrowserEntry>> list(bool audio, BrowserLocation location) async {
    browsed.add(location);
    if (failList) {
      throw PlatformException(
          code: 'unavailable', message: 'Folder unavailable');
    }
    if (location.source == 'folders' && location.isHome) {
      return folders
          .map((e) => BrowserEntry(
              id: e['tree'] as String,
              name: e['name'] as String,
              folder: true,
              root: true))
          .toList();
    }
    final key = location.tree != null
        ? '${location.tree}/${location.trail.length}'
        : location.directory;
    return listings[key] ??
        [const BrowserEntry(id: 'image', name: 'Background.png', modified: 2)];
  }

  @override
  Future<void> saveView(bool audio, BrowserPreferences view) async {
    viewWrites++;
    preferences.sort = view.sort;
    preferences.ascending = view.ascending;
    preferences.grid = view.grid;
    preferences.showNames = view.showNames;
    preferences.largePreviews = view.largePreviews;
  }

  @override
  Future<Map<Object?, Object?>?> addFolder({String? tree}) async {
    final folder = {'tree': 'content://fixtures/tree', 'name': 'Fixtures'};
    if (folders.isEmpty) folders.add(folder);
    return folder;
  }

  @override
  Future<void> removeFolder(String tree) async {
    folders.removeWhere((e) => e['tree'] == tree);
    if (saved.tree == tree) {
      saved = const BrowserLocation(source: 'folders');
      file = null;
      name = null;
    }
  }

  @override
  Future<String?> select(
      bool audio, BrowserLocation location, BrowserEntry entry) async {
    selectionWrites++;
    saved = location;
    file = entry.id;
    name = entry.name;
    if (failSelect) {
      throw PlatformException(code: 'copy', message: 'Unable to copy');
    }
    return copying?.future;
  }

  @override
  Future<Uint8List?> thumbnail(String id) async => thumbnailBytes;
  @override
  Future<void> cancelThumbnails() async {}
}

void main() {
  late FakeBrowser browser;
  setUp(() {
    browser = FakeBrowser();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<String>(
                              builder: (_) => MediaBrowserScreen(
                                  audio: browser.audio, browser: browser))),
                      child: const Text('Open')),
                ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'restores the current directory and passively highlights the old file',
      (tester) async {
    await show(tester);
    expect(find.text('Internal storage/Pictures/'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('media-entry-image')),
            matching: find.byWidgetPredicate((widget) =>
                widget is Semantics && widget.properties.selected == true)),
        findsOneWidget);
    expect(browser.selectionWrites, 0);
  });

  testWidgets(
      'sort and layout persist even when closing without selecting a file',
      (tester) async {
    final saved = browser.saved;
    await show(tester);
    await tester.tap(find.byTooltip('List view'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
        (w) => w is CheckedPopupMenuItem<String> && w.value == 'size'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(browser.preferences.grid, isFalse);
    expect(browser.preferences.sort, 'size');
    expect(browser.viewWrites, 2);
    expect(browser.saved, saved);
    expect(browser.selectionWrites, 0);
  });

  testWidgets(
      'source switching and cancellation never overwrite remembered navigation',
      (tester) async {
    final saved = browser.saved;
    await show(tester);
    await tester.tap(find.text('Folders').first);
    await tester.pumpAndSettle();
    expect(find.text('Add a folder to browse its files.'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(browser.saved, saved);
    expect(browser.selectionWrites, 0);
  });

  testWidgets('back ascends the folder trail, then folder list, then exits',
      (tester) async {
    browser.saved = const BrowserLocation(
        source: 'folders',
        tree: 'content://fixtures/tree',
        rootName: 'Fixtures',
        trail: [
          {'id': 'child', 'name': 'Child'}
        ]);
    await show(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(browser.browsed.last.trail, isEmpty);
    expect(browser.browsed.last.tree, 'content://fixtures/tree');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(browser.browsed.last.isHome, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MediaBrowserScreen), findsNothing);
  });

  testWidgets('close exits directly from a nested folder', (tester) async {
    browser.saved = const BrowserLocation(
        source: 'folders',
        tree: 'tree',
        rootName: 'Fixtures',
        trail: [
          {'id': 'child', 'name': 'Child'}
        ]);
    await show(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaBrowserScreen), findsNothing);
    expect(browser.saved.trail.length, 1);
  });

  testWidgets(
      'partial permission displays a management action without blocking browsing',
      (tester) async {
    browser.permission = 'partial';
    await show(tester);
    expect(find.text('Only authorized images are shown.'), findsOneWidget);
    expect(find.text('Background.png'), findsOneWidget);
    await tester.tap(find.text('Manage accessible images'));
    await tester.pumpAndSettle();
    expect(browser.requests, 1);
    expect(find.text('Only authorized images are shown.'), findsNothing);
  });

  testWidgets('denied library access still allows adding a durable folder',
      (tester) async {
    browser.permission = 'denied';
    await show(tester);
    expect(find.text('Allow access'), findsOneWidget);
    expect(browser.requests, 0);
    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    expect(find.text('Fixtures'), findsOneWidget);
    expect(browser.folders.length, 1);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(browser.folders.length, 1);
    expect(browser.selectionWrites, 0);
  });

  testWidgets(
      'missing folder reports recovery choices and keeps saved navigation',
      (tester) async {
    final saved = browser.saved;
    browser.failList = true;
    await show(tester);
    expect(find.text('Folder unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Go to source home'), findsOneWidget);
    expect(browser.saved, saved);
    browser.failList = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Background.png'), findsOneWidget);
    expect(browser.browsed.last.sameAs(saved), isTrue);
  });

  testWidgets(
      'failed copy stays in browser and refreshes the confirmed selection record',
      (tester) async {
    browser.failSelect = true;
    await show(tester);
    await tester.tap(find.text('Background.png'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaBrowserScreen), findsOneWidget);
    expect(find.text('Unable to copy'), findsOneWidget);
    expect(browser.selectionWrites, 1);
    expect(browser.file, 'image');
  });

  testWidgets(
      'removing a root updates folder list immediately and keeps imported files out of scope',
      (tester) async {
    browser.saved = const BrowserLocation(source: 'folders');
    browser.folders.add({'tree': 'tree', 'name': 'Fixtures'});
    await show(tester);
    await tester.tap(find.byTooltip('Folder options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(browser.folders, isEmpty);
    expect(find.text('Add a folder to browse its files.'), findsOneWidget);
  });

  testWidgets(
      'remembered file is brought into view after restore, sort, and layout changes',
      (tester) async {
    browser.file = 'file-60';
    browser.name = 'Image 060.png';
    browser.listings[browser.saved.directory] = List.generate(
        100,
        (i) => BrowserEntry(
            id: 'file-$i',
            name: 'Image ${i.toString().padLeft(3, '0')}.png',
            modified: i));
    await show(tester);
    expect(find.text('Image 060.png').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('List view'));
    await tester.pumpAndSettle();
    expect(find.text('Image 060.png').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
        (w) => w is CheckedPopupMenuItem<String> && w.value == 'name'));
    await tester.pumpAndSettle();
    expect(find.text('Image 060.png').hitTestable(), findsOneWidget);
  });

  testWidgets(
      'closing during copying cleans the late cache without popping the editor',
      (tester) async {
    final temporary = await tester
        .runAsync(() => Directory.systemTemp.createTemp('browser-close-'));
    final cached = File('${temporary!.path}/late.png');
    await tester.runAsync(() => cached.writeAsBytes([1, 2, 3]));
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    browser.copying = Completer<String?>();
    await show(tester);
    await tester.tap(find.text('Background.png'));
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    browser.copying!.complete(cached.path);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('Open'), findsOneWidget);
    expect(await tester.runAsync(() => cached.exists()), isFalse);
  });

  testWidgets(
      'image grid fills the cell, hides only file labels, and keeps accessible names',
      (tester) async {
    browser.thumbnailBytes = await tester.runAsync(() async {
      final image = await stripedImage();
      try {
        return await imagePng(image);
      } finally {
        image.dispose();
      }
    });
    browser.listings[browser.saved.directory] = [
      const BrowserEntry(id: 'folder', name: 'Pictures', folder: true),
      const BrowserEntry(id: 'image', name: 'Background.png', modified: 2),
    ];
    await show(tester);
    final tile = find.byKey(const ValueKey('media-entry-image'));
    final preview = find.descendant(of: tile, matching: find.byType(Image));
    expect(tester.widget<Image>(preview).fit, BoxFit.contain);
    expect(tester.getSize(preview).width,
        closeTo(tester.getSize(tile).width - 8, .01));
    final namedHeight = tester.getSize(preview).height;
    expect(tester.widget<Text>(find.text('Background.png')).style!.fontSize!,
        lessThanOrEqualTo(12));
    await tester.tap(find.byTooltip('Hide filenames'));
    await tester.pumpAndSettle();
    expect(find.text('Background.png'), findsNothing);
    expect(find.text('Pictures'), findsOneWidget);
    expect(tester.getSize(preview).height, greaterThan(namedHeight));
    expect(tester.getSize(preview).height,
        closeTo(tester.getSize(tile).height - 8, .01));
    expect(
        find.descendant(
            of: tile,
            matching: find.byWidgetPredicate((w) =>
                w is Semantics && w.properties.label == 'Background.png')),
        findsOneWidget);
    expect(browser.preferences.showNames, isFalse);
    await tester.tap(find.byTooltip('Show filenames'));
    await tester.pumpAndSettle();
    expect(find.text('Background.png'), findsOneWidget);
  });

  testWidgets(
      'preview size selects three or two columns and persists after closing',
      (tester) async {
    await show(tester);
    SliverGridDelegateWithFixedCrossAxisCount delegate() =>
        tester.widget<GridView>(find.byType(GridView)).gridDelegate
            as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate().crossAxisCount, 3);
    await tester.tap(find.byTooltip('Larger previews'));
    await tester.pumpAndSettle();
    expect(delegate().crossAxisCount, 2);
    await tester.tap(find.byTooltip('Hide filenames'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('List view'));
    await tester.pumpAndSettle();
    expect(find.text('Background.png'), findsOneWidget);
    expect(find.byTooltip('Show filenames'), findsNothing);
    await tester.tap(find.byTooltip('Grid view'));
    await tester.pumpAndSettle();
    expect(delegate().crossAxisCount, 2);
    expect(find.text('Background.png'), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(delegate().crossAxisCount, 2);
    expect(find.text('Background.png'), findsNothing);
    expect(browser.selectionWrites, 0);
    expect(browser.file, 'image');
  });

  testWidgets('resizing and hiding names keep the remembered image visible',
      (tester) async {
    browser.file = 'file-60';
    browser.name = 'Image 060.png';
    browser.listings[browser.saved.directory] = List.generate(
        100,
        (i) => BrowserEntry(
            id: 'file-$i',
            name: 'Image ${i.toString().padLeft(3, '0')}.png',
            modified: i));
    await show(tester);
    final selected = find.byKey(const ValueKey('media-entry-file-60'));
    expect(selected.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Larger previews'));
    await tester.pumpAndSettle();
    expect(selected.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Hide filenames'));
    await tester.pumpAndSettle();
    expect(selected.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Smaller previews'));
    await tester.pumpAndSettle();
    expect(selected.hitTestable(), findsOneWidget);
  });

  testWidgets(
      'image grid controls fit a narrow folder home and do not appear for audio',
      (tester) async {
    browser.saved = const BrowserLocation(source: 'folders');
    browser.folders.add({'tree': 'tree', 'name': 'Fixtures'});
    await show(tester);
    tester.view.physicalSize = const Size(320, 700);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    browser = FakeBrowser(audio: true);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Grid view'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide filenames'), findsNothing);
    expect(find.byTooltip('Larger previews'), findsNothing);
    expect(find.text('Background.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'layout fits a short landscape viewport and refreshes access on resume',
      (tester) async {
    await show(tester);
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    browser.permission = 'partial';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Only authorized images are shown.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
