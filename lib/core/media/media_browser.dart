import 'package:flutter/services.dart';

class BrowserLocation {
  const BrowserLocation({
    this.source = 'library',
    this.directory = '',
    this.tree,
    this.rootName,
    this.trail = const [],
  });

  factory BrowserLocation.fromMap(Map<Object?, Object?> value) =>
      BrowserLocation(
        source: value['source'] as String? ?? 'library',
        directory: value['directory'] as String? ?? '',
        tree: value['tree'] as String?,
        rootName: value['rootName'] as String?,
        trail: (value['trail'] as List? ?? [])
            .map((e) => Map<String, String>.from(e as Map))
            .toList(),
      );

  final String source;
  final String directory;
  final String? tree;
  final String? rootName;
  final List<Map<String, String>> trail;

  bool get isHome => source == 'library' ? directory.isEmpty : tree == null;
  String get path => source == 'library'
      ? directory.replaceFirst(
          RegExp(r'^external_primary/'), 'Internal storage/')
      : [if (rootName != null) rootName!, ...trail.map((e) => e['name']!)]
          .join('/');

  BrowserLocation get parent {
    if (source == 'library') {
      final parts = directory.split('/').where((e) => e.isNotEmpty).toList();
      return BrowserLocation(
          directory: parts.length <= 1
              ? ''
              : '${parts.take(parts.length - 1).join('/')}/');
    }
    if (trail.isEmpty) return const BrowserLocation(source: 'folders');
    return BrowserLocation(
        source: source,
        tree: tree,
        rootName: rootName,
        trail: trail.take(trail.length - 1).toList());
  }

  BrowserLocation enter(BrowserEntry entry) => source == 'library'
      ? BrowserLocation(directory: entry.id)
      : entry.root
          ? BrowserLocation(
              source: source, tree: entry.id, rootName: entry.name)
          : BrowserLocation(
              source: source,
              tree: tree,
              rootName: rootName,
              trail: [
                  ...trail,
                  {'id': entry.id, 'name': entry.name}
                ]);

  Map<String, Object?> toMap() => {
        'source': source,
        'directory': directory,
        if (tree != null) 'tree': tree,
        if (rootName != null) 'rootName': rootName,
        if (trail.isNotEmpty) 'trail': trail,
      };

  bool sameAs(BrowserLocation other) {
    if (source != other.source) return false;
    if (source == 'library') return directory == other.directory;
    if (tree != other.tree || trail.length != other.trail.length) return false;
    for (var i = 0; i < trail.length; i++) {
      if (trail[i]['id'] != other.trail[i]['id']) return false;
    }
    return true;
  }
}

class BrowserEntry {
  const BrowserEntry(
      {required this.id,
      required this.name,
      this.folder = false,
      this.root = false,
      this.size,
      this.modified});
  factory BrowserEntry.fromMap(Map<Object?, Object?> value) => BrowserEntry(
      id: value['id'] as String,
      name: value['name'] as String,
      folder: value['folder'] == true,
      root: value['root'] == true,
      size: (value['size'] as num?)?.toInt(),
      modified: (value['modified'] as num?)?.toInt());
  final String id;
  final String name;
  final bool folder;
  final bool root;
  final int? size;
  final int? modified;
}

class BrowserPreferences {
  BrowserPreferences({required bool audio})
      : sort = audio ? 'name' : 'modified',
        ascending = audio,
        grid = !audio;
  String sort;
  bool ascending;
  bool grid;
  bool showNames = true;
  bool largePreviews = false;

  List<BrowserEntry> sorted(List<BrowserEntry> entries) {
    int byName(BrowserEntry a, BrowserEntry b) {
      final folded = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (folded != 0) return folded;
      final exact = a.name.compareTo(b.name);
      return exact != 0 ? exact : a.id.compareTo(b.id);
    }

    return [...entries]..sort((a, b) {
        if (a.folder != b.folder) return a.folder ? -1 : 1;
        if (a.folder) return byName(a, b);
        int comparison;
        if (sort == 'name') {
          comparison = byName(a, b);
        } else {
          final left = sort == 'size' ? a.size : a.modified;
          final right = sort == 'size' ? b.size : b.modified;
          // Unknown provider metadata stays last in either direction.
          if (left == null || right == null) {
            if (left == right) return byName(a, b);
            return left == null ? 1 : -1;
          }
          comparison = left.compareTo(right);
        }
        if (comparison == 0) return byName(a, b);
        return ascending ? comparison : -comparison;
      });
  }
}

String? highlightedFile(List<BrowserEntry> entries, String? id, String? name) {
  final files = entries.where((e) => !e.folder);
  if (id != null && files.any((e) => e.id == id)) return id;
  if (name == null) return null;
  final matches = files.where((e) => e.name == name).toList();
  return matches.length == 1 ? matches.single.id : null;
}

/// Android owns persistent state. This class only serializes channel messages.
class MediaBrowser {
  static const channel = MethodChannel('openhiit/media_picker');

  Future<Map<Object?, Object?>> state(bool audio,
          {bool initialize = false}) async =>
      (await channel.invokeMapMethod<Object?, Object?>(
          initialize ? 'initialize' : 'state', {'audio': audio}))!;

  Future<Map<Object?, Object?>> requestPermission(bool audio) async =>
      (await channel.invokeMapMethod<Object?, Object?>(
          'requestPermission', {'audio': audio}))!;

  Future<List<BrowserEntry>> list(bool audio, BrowserLocation location) async =>
      (await channel.invokeListMethod<Object?>(
              'list', {'audio': audio, 'location': location.toMap()}))!
          .map((e) => BrowserEntry.fromMap(e as Map))
          .toList();

  Future<Map<Object?, Object?>?> addFolder({String? tree}) =>
      channel.invokeMapMethod<Object?, Object?>('addFolder', {'tree': tree});

  Future<void> removeFolder(String tree) =>
      channel.invokeMethod('removeFolder', {'tree': tree});

  Future<void> saveView(bool audio, BrowserPreferences view) =>
      channel.invokeMethod('saveView', {
        'audio': audio,
        'sort': view.sort,
        'ascending': view.ascending,
        'grid': view.grid,
        'showNames': view.showNames,
        'largePreviews': view.largePreviews
      });

  Future<String?> select(
          bool audio, BrowserLocation location, BrowserEntry entry) =>
      channel.invokeMethod<String>('select',
          {'audio': audio, 'location': location.toMap(), 'id': entry.id});

  Future<Uint8List?> thumbnail(String id) =>
      channel.invokeMethod<Uint8List>('thumbnail', {'id': id});
  Future<void> cancelThumbnails() => channel.invokeMethod('cancelThumbnails');
}
