import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/media/media_browser.dart';

void main() {
  test('folders stay first and alphabetical in either file sort direction', () {
    final view = BrowserPreferences(audio: false);
    final entries = [
      const BrowserEntry(id: 'z', name: 'Zulu', folder: true),
      const BrowserEntry(id: 'old', name: 'old.png', modified: 1),
      const BrowserEntry(id: 'a', name: 'Alpha', folder: true),
      const BrowserEntry(id: 'new', name: 'new.png', modified: 2),
      const BrowserEntry(id: 'unknown', name: 'unknown.png'),
    ];
    expect(view.sorted(entries).map((e) => e.id),
        ['a', 'z', 'new', 'old', 'unknown']);
    view.ascending = true;
    expect(view.sorted(entries).map((e) => e.id),
        ['a', 'z', 'old', 'new', 'unknown']);
    view.sort = 'size';
    expect(view.sorted(entries).take(2).map((e) => e.id), ['a', 'z']);
  });

  test(
      'highlight uses identity first and only a unique exact filename as fallback',
      () {
    final entries = [
      const BrowserEntry(id: 'one', name: 'Same.png'),
      const BrowserEntry(id: 'two', name: 'Same.png'),
      const BrowserEntry(id: 'other', name: 'same.png'),
    ];
    expect(highlightedFile(entries, 'one', 'Same.png'), 'one');
    expect(highlightedFile(entries, 'missing', 'Same.png'), isNull);
    expect(highlightedFile(entries, 'missing', 'same.png'), 'other');
    expect(highlightedFile(entries, 'missing', 'gone.png'), isNull);
  });

  test(
      'library directories navigate one level at a time without recursive file merging',
      () {
    const root = BrowserLocation();
    final volume = root.enter(const BrowserEntry(
        id: 'external_primary/', name: 'Internal storage', folder: true));
    final music = volume.enter(const BrowserEntry(
        id: 'external_primary/Music/', name: 'Music', folder: true));
    expect(music.path, 'Internal storage/Music/');
    expect(music.parent.sameAs(volume), isTrue);
    expect(volume.parent.isHome, isTrue);
    expect(root.parent.isHome, isTrue);
  });

  test('opaque document trails round trip and stop at the authorized root', () {
    const home = BrowserLocation(source: 'folders');
    final root = home.enter(const BrowserEntry(
        id: 'content://tree/root', name: 'Fixtures', folder: true, root: true));
    final child = root.enter(
        const BrowserEntry(id: 'opaque:id', name: 'Child', folder: true));
    final restored = BrowserLocation.fromMap(child.toMap());
    expect(restored.path, 'Fixtures/Child');
    expect(restored.sameAs(child), isTrue);
    expect(restored.parent.sameAs(root), isTrue);
    expect(restored.parent.parent.sameAs(home), isTrue);
    expect(home.parent.sameAs(home), isTrue);
    final renamed = BrowserLocation.fromMap({
      'source': 'folders',
      'tree': root.tree,
      'rootName': 'New display name',
      'trail': [
        {'name': 'Renamed child', 'id': 'opaque:id'}
      ],
    });
    expect(renamed.sameAs(child), isTrue);
  });

  test('equal metadata has deterministic filename and identity order', () {
    final view = BrowserPreferences(audio: false);
    final entries = [
      const BrowserEntry(id: '2', name: 'b.png', modified: 1),
      const BrowserEntry(id: '3', name: 'a.png', modified: 1),
      const BrowserEntry(id: '1', name: 'a.png', modified: 1),
    ];
    expect(view.sorted(entries).map((e) => e.id), ['1', '3', '2']);
  });
}
