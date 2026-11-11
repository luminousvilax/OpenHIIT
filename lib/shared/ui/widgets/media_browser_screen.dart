import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openhiit/core/media/media_browser.dart';

class MediaBrowserScreen extends StatefulWidget {
  const MediaBrowserScreen({super.key, required this.audio, this.browser});
  final bool audio;
  final MediaBrowser? browser;

  @override
  State<MediaBrowserScreen> createState() => _MediaBrowserScreenState();
}

class _MediaBrowserScreenState extends State<MediaBrowserScreen>
    with WidgetsBindingObserver {
  late final MediaBrowser _browser = widget.browser ?? MediaBrowser();
  late final BrowserPreferences _view = BrowserPreferences(audio: widget.audio);
  final _scroll = ScrollController();
  final _thumbnails = <String, Future<Uint8List?>>{};
  BrowserLocation _location = const BrowserLocation();
  BrowserLocation? _remembered;
  String? _file;
  String? _name;
  String _permission = 'denied';
  String? _error;
  List<BrowserEntry> _entries = [];
  List<Map<Object?, Object?>> _folders = [];
  bool _loading = true;
  bool _selecting = false;
  bool _authorizing = false;
  bool _ready = false;
  bool _closed = false;
  bool get _active => mounted && !_closed;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _request++;
    _browser.cancelThumbnails().catchError((Object _) {});
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _ready &&
        !_authorizing &&
        !_selecting) {
      _refreshAccess();
    }
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? 'Unable to read media.'
      : 'Unable to read media. Try again.';

  void _readState(Map<Object?, Object?> state, {bool restore = false}) {
    _permission = state['permission'] as String;
    _folders = (state['folders'] as List).cast<Map>();
    _remembered = BrowserLocation.fromMap(state['location'] as Map);
    _file = state['file'] as String?;
    _name = state['name'] as String?;
    if (restore) {
      _location = _remembered!;
      _view.sort = state['sort'] as String;
      _view.ascending = state['ascending'] as bool;
      _view.grid = state['grid'] as bool;
      _view.showNames = state['showNames'] as bool;
      _view.largePreviews = state['largePreviews'] as bool;
    }
  }

  Future<void> _initialize() async {
    try {
      final state = await _browser.state(widget.audio, initialize: true);
      if (!_active) return;
      _readState(state, restore: true);
      _ready = true;
      await _load();
    } catch (error) {
      if (_active) {
        setState(() {
          _loading = false;
          _error = _message(error);
        });
      }
    }
  }

  Future<void> _refreshAccess() async {
    try {
      final state = await _browser.state(widget.audio);
      if (!_active) return;
      _readState(state);
      await _load();
    } catch (error) {
      if (_active) {
        setState(() {
          _error = _message(error);
        });
      }
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _entries = [];
    });
    _thumbnails.clear();
    try {
      await _browser.cancelThumbnails();
      if (!_active || request != _request) return;
      if (_location.source == 'library' && _permission == 'denied') {
        setState(() {
          _loading = false;
        });
        return;
      }
      final entries = await _browser.list(widget.audio, _location);
      if (!_active || request != _request) return;
      setState(() {
        _entries = _view.sorted(entries);
        _loading = false;
      });
      _revealHighlight(request);
    } catch (error) {
      if (_active && request == _request) {
        setState(() {
          _loading = false;
          _error = _message(error);
        });
      }
    }
  }

  String? get _highlight => _remembered?.sameAs(_location) == true
      ? highlightedFile(_entries, _file, _name)
      : null;

  void _revealHighlight(int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_active || request != _request || !_scroll.hasClients) return;
      final index = _entries.indexWhere((e) => e.id == _highlight);
      if (index < 0) {
        _scroll.jumpTo(0);
        return;
      }
      final viewportExtent = _scroll.position.viewportDimension;
      // Grid columns and row extents match the SliverGridDelegate below.
      final cross = MediaQuery.sizeOf(context).width - 24;
      final columns = widget.audio
          ? math.max(1, (cross / (156 + 8)).ceil())
          : (_view.largePreviews ? 2 : 3);
      final cellWidth = (cross - (columns - 1) * 8) / columns;
      final rowExtent =
          _view.grid ? cellWidth / (widget.audio ? .85 : 1) + 8 : 84.0;
      final row = _view.grid ? index ~/ columns : index;
      _scroll.jumpTo((12 + row * rowExtent - viewportExtent / 2 + rowExtent / 2)
          .clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  Future<void> _navigate(BrowserLocation location) async {
    if (_selecting || _authorizing) return;
    _location = location;
    await _load();
  }

  Future<void> _authorize({bool recover = false}) async {
    if (_authorizing) return;
    setState(() {
      _authorizing = true;
    });
    try {
      final previousTree = recover ? _location.tree : null;
      final folder = await _browser.addFolder(tree: previousTree);
      if (!_active) return;
      if (folder != null) {
        final state = await _browser.state(widget.audio);
        if (!_active) return;
        _readState(state);
        _location = BrowserLocation(
            source: 'folders',
            tree: folder['tree'] as String,
            rootName: folder['name'] as String);
        await _load();
      }
    } catch (error) {
      if (_active) {
        _showError(error);
      }
    } finally {
      if (_active) {
        setState(() {
          _authorizing = false;
        });
      }
    }
  }

  Future<void> _requestPermission() async {
    setState(() {
      _authorizing = true;
    });
    try {
      final state = await _browser.requestPermission(widget.audio);
      if (!_active) return;
      _readState(state);
      await _load();
    } catch (error) {
      if (_active) {
        _showError(error);
      }
    } finally {
      if (_active) {
        setState(() {
          _authorizing = false;
        });
      }
    }
  }

  Future<void> _remove(BrowserEntry entry) async {
    try {
      await _browser.removeFolder(entry.id);
      final state = await _browser.state(widget.audio);
      if (!_active) return;
      _readState(state);
      await _load();
    } catch (error) {
      if (_active) {
        _showError(error);
      }
    }
  }

  void _close() {
    _closed = true;
    Navigator.of(context).pop();
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_message(error))));
  }

  Future<void> _select(BrowserEntry entry) async {
    if (_selecting || _authorizing) return;
    if (entry.folder) {
      await _navigate(_location.enter(entry));
      return;
    }
    setState(() {
      _selecting = true;
    });
    try {
      final path = await _browser.select(widget.audio, _location, entry);
      if (!mounted || _closed) {
        if (path != null) {
          final file = File(path);
          await file.delete();
          await file.parent.delete();
        }
        return;
      }
      Navigator.of(context).pop(path);
    } catch (error) {
      if (_active) {
        _showError(error);
        // The native selection record was committed before copying; refresh it after failure.
        await _refreshAccess();
      }
    } finally {
      if (_active) {
        setState(() {
          _selecting = false;
        });
      }
    }
  }

  Future<void> _saveView() async {
    setState(() {
      _entries = _view.sorted(_entries);
    });
    _revealHighlight(_request);
    try {
      await _browser.saveView(widget.audio, _view);
    } catch (error) {
      if (_active) {
        _showError(error);
      }
    }
  }

  Future<Uint8List?> _thumbnail(String id) {
    final cached = _thumbnails.remove(id);
    final future =
        cached ?? _browser.thumbnail(id).catchError((Object _) => null);
    _thumbnails[id] = future;
    while (_thumbnails.length > 48) {
      _thumbnails.remove(_thumbnails.keys.first);
    }
    return future;
  }

  Widget _icon(BrowserEntry entry, {double size = 40}) {
    if (entry.folder || widget.audio) {
      return Icon(
          entry.folder ? Icons.folder_outlined : Icons.audio_file_outlined,
          size: size);
    }
    return FutureBuilder<Uint8List?>(
        future: _thumbnail(entry.id),
        builder: (context, snapshot) {
          if (snapshot.data == null) {
            return Icon(Icons.image_outlined, size: size);
          }
          return Image.memory(snapshot.data!,
              fit: BoxFit.contain,
              cacheWidth: _view.grid ? (_view.largePreviews ? 512 : 256) : 128,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.image_outlined, size: size));
        });
  }

  String _metadata(BrowserEntry entry) {
    final parts = <String>[];
    if (entry.size != null) {
      final bytes = entry.size!;
      parts.add(bytes < 1024
          ? '$bytes B'
          : bytes < 1024 * 1024
              ? '${(bytes / 1024).toStringAsFixed(1)} KB'
              : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB');
    }
    if (entry.modified != null) {
      final time =
          DateTime.fromMillisecondsSinceEpoch(entry.modified!).toLocal();
      parts.add(MaterialLocalizations.of(context).formatShortDate(time));
    }
    return parts.join(' · ');
  }

  Widget? _removeMenu(BrowserEntry entry) => entry.root
      ? PopupMenuButton<String>(
          tooltip: 'Folder options',
          onSelected: (_) => _remove(entry),
          itemBuilder: (_) =>
              [const PopupMenuItem(value: 'remove', child: Text('Remove'))])
      : null;

  Widget _contents() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _empty(_error!, recovery: true);
    if (_location.source == 'library' && _permission == 'denied') {
      return _empty(
          'Allow access to browse your ${widget.audio ? 'audio files' : 'images'}, or add a folder.',
          permission: true);
    }
    if (_entries.isEmpty) {
      return _empty(_location.source == 'folders' && _location.isHome
          ? 'Add a folder to browse its files.'
          : 'No supported files in this folder.');
    }
    if (_view.grid) {
      return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          gridDelegate: widget.audio
              ? const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 156,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: .85)
              : SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _view.largePreviews ? 2 : 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
          itemCount: _entries.length,
          itemBuilder: (context, index) {
            final entry = _entries[index];
            final selected = entry.id == _highlight;
            return Material(
                color: selected
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                    key: ValueKey('media-entry-${entry.id}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: _selecting || _authorizing
                        ? null
                        : () => _select(entry),
                    child: Semantics(
                        label:
                            !widget.audio && !entry.folder && !_view.showNames
                                ? entry.name
                                : null,
                        selected: selected,
                        child: Column(children: [
                          Expanded(
                              child: Padding(
                                  padding: EdgeInsets.all(widget.audio ? 8 : 4),
                                  child: SizedBox.expand(
                                      child: _icon(entry, size: 56)))),
                          if (widget.audio || entry.folder || _view.showNames)
                            Row(children: [
                              Expanded(
                                  child: Padding(
                                      padding: EdgeInsets.symmetric(
                                          horizontal: widget.audio ? 8 : 6,
                                          vertical: widget.audio ? 8 : 4),
                                      child: Text(entry.name,
                                          style: widget.audio
                                              ? null
                                              : Theme.of(context)
                                                  .textTheme
                                                  .labelSmall,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis))),
                              if (entry.root) _removeMenu(entry)!
                            ]),
                        ]))));
          });
    }
    return ListView.builder(
        controller: _scroll,
        itemExtent: 84,
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          return ListTile(
              key: ValueKey('media-entry-${entry.id}'),
              selected: entry.id == _highlight,
              selectedTileColor:
                  Theme.of(context).colorScheme.secondaryContainer,
              leading: SizedBox(width: 48, height: 48, child: _icon(entry)),
              title: Text(entry.name,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: entry.folder ? null : Text(_metadata(entry)),
              trailing: _removeMenu(entry),
              onTap: _selecting || _authorizing ? null : () => _select(entry));
        });
  }

  Widget _empty(String message,
          {bool recovery = false, bool permission = false}) =>
      Center(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                if (recovery)
                  TextButton(
                      onPressed: _ready ? _refreshAccess : _initialize,
                      child: const Text('Retry')),
                if (permission || (recovery && _location.source == 'library'))
                  TextButton(
                      onPressed: _authorizing ? null : _requestPermission,
                      child: const Text('Allow access')),
                if (recovery && _location.tree != null)
                  TextButton(
                      onPressed:
                          _authorizing ? null : () => _authorize(recover: true),
                      child: const Text('Authorize again')),
                if (_location.source == 'library' || _location.isHome)
                  TextButton(
                      onPressed: _authorizing ? null : _authorize,
                      child: const Text('Add folder')),
                if (recovery && !_location.isHome)
                  TextButton(
                      onPressed: () =>
                          _navigate(BrowserLocation(source: _location.source)),
                      child: const Text('Go to source home')),
              ])));

  @override
  Widget build(BuildContext context) => PopScope<String?>(
      canPop: _location.isHome,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
        if (!didPop && !_selecting && !_authorizing) {
          _navigate(_location.parent);
        }
      },
      child: Scaffold(
        appBar: AppBar(
            title: Text(widget.audio ? 'Choose audio' : 'Choose image'),
            leading: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: _close)),
        body: SafeArea(
            top: false,
            child: Column(children: [
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: 'library', label: Text('Media library')),
                        ButtonSegment(value: 'folders', label: Text('Folders')),
                      ],
                      selected: {
                        _location.source
                      },
                      onSelectionChanged: !_ready || _selecting || _authorizing
                          ? null
                          : (values) => _navigate(
                              BrowserLocation(source: values.single)))),
              Row(children: [
                IconButton(
                    tooltip: 'Parent folder',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _location.isHome || _selecting || _authorizing
                        ? null
                        : () => _navigate(_location.parent)),
                Expanded(
                    child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(_location.path.isEmpty
                            ? (_location.source == 'library'
                                ? 'Media library'
                                : 'Folders')
                            : _location.path))),
                IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading || _selecting || _authorizing
                        ? null
                        : _refreshAccess,
                    icon: const Icon(Icons.refresh)),
              ]),
              if (_location.source == 'library' && _permission == 'partial')
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('Only authorized images are shown.'),
                          TextButton(
                              onPressed:
                                  _authorizing ? null : _requestPermission,
                              child: const Text('Manage accessible images'))
                        ])),
              Row(children: [
                PopupMenuButton<String>(
                    tooltip: 'Sort',
                    icon: const Icon(Icons.sort),
                    enabled: _ready && !_selecting && !_authorizing,
                    onSelected: (value) {
                      if (value == 'direction') {
                        _view.ascending = !_view.ascending;
                      } else {
                        _view.sort = value;
                      }
                      _saveView();
                    },
                    itemBuilder: (_) => [
                          for (final pair in [
                            ('name', 'Name'),
                            ('modified', 'Modified'),
                            ('size', 'Size')
                          ])
                            CheckedPopupMenuItem(
                                value: pair.$1,
                                checked: _view.sort == pair.$1,
                                child: Text(pair.$2)),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                              value: 'direction',
                              child: Text(_view.ascending
                                  ? 'Descending'
                                  : 'Ascending')),
                        ]),
                Expanded(
                    child: Text(
                        '${{
                          'name': 'Name',
                          'modified': 'Modified',
                          'size': 'Size'
                        }[_view.sort]} ${_view.ascending ? '↑' : '↓'}',
                        overflow: TextOverflow.ellipsis)),
                if (_location.source == 'folders' &&
                    _location.isHome &&
                    _folders.isNotEmpty)
                  if (!widget.audio && _view.grid)
                    IconButton(
                        tooltip: 'Add folder',
                        onPressed:
                            _authorizing || _selecting ? null : _authorize,
                        icon: const Icon(Icons.create_new_folder_outlined))
                  else
                    TextButton.icon(
                        onPressed:
                            _authorizing || _selecting ? null : _authorize,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Add folder')),
                if (!widget.audio && _view.grid) ...[
                  IconButton(
                    tooltip: _view.largePreviews
                        ? 'Smaller previews'
                        : 'Larger previews',
                    isSelected: _view.largePreviews,
                    onPressed: !_ready || _selecting || _authorizing
                        ? null
                        : () {
                            _view.largePreviews = !_view.largePreviews;
                            _saveView();
                          },
                    icon: const Icon(Icons.photo_size_select_small),
                    selectedIcon: const Icon(Icons.photo_size_select_large),
                  ),
                  IconButton(
                    tooltip:
                        _view.showNames ? 'Hide filenames' : 'Show filenames',
                    isSelected: _view.showNames,
                    onPressed: !_ready || _selecting || _authorizing
                        ? null
                        : () {
                            _view.showNames = !_view.showNames;
                            _saveView();
                          },
                    icon: const Icon(Icons.text_fields),
                  ),
                ],
                IconButton(
                    tooltip: _view.grid ? 'List view' : 'Grid view',
                    onPressed: !_ready || _selecting || _authorizing
                        ? null
                        : () {
                            _view.grid = !_view.grid;
                            _saveView();
                          },
                    icon: Icon(_view.grid ? Icons.view_list : Icons.grid_view)),
              ]),
              if (_selecting || _authorizing) const LinearProgressIndicator(),
              Expanded(child: _contents()),
            ])),
      ));
}
