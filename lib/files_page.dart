import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'gcode.dart';
import 'moonraker.dart';
import 'settings.dart';
import 'u1_panels.dart';
import 'ui.dart';

enum _Sort { newest, name, size }

const _gcodeExt = ['gcode', 'g', 'gco', '3mf'];
final _isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

class FilesTab extends StatefulWidget {
  final MoonrakerClient client;
  final Printer printer;
  const FilesTab({super.key, required this.client, required this.printer});
  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  String _path = '';
  List<String> _dirs = const [];
  List<GcodeFile>? _files;
  List<GcodeFile>? _all; // every file in every folder, for search/favourites
  String? _error;
  String _query = '';
  _Sort _sort = _Sort.newest;
  bool _favOnly = false, _dragging = false, _uploading = false;
  List<QueuedJob> _queue = const [];
  final _sel = <String>{}; // long-press to select several files
  String _queueState = '';

  MoonrakerClient get c => widget.client;
  String get _favScope => 'files.${widget.printer.key}';

  @override
  void initState() {
    super.initState();
    if (c.lastDir[''] case final d?) {
      _dirs = d.$1;
      _files = d.$2;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final (dirs, files) = await c.directory(_path);
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _files = files;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    _loadQueue();
  }

  void _toggleSel(String path) =>
      setState(() => _sel.contains(path) ? _sel.remove(path) : _sel.add(path));

  Widget _selectionBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Panel(
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [
            Text('${_sel.length} selected', style: const TextStyle(fontWeight: FontWeight.w700)),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = _sel.toList();
                await run(context, () async {
                  for (final p in picked) {
                    await c.enqueue(p);
                  }
                }, done: 'Added ${picked.length} to the queue');
                setState(_sel.clear);
                _loadQueue();
              },
              icon: const Icon(Icons.queue_rounded),
              label: const Text('Queue'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: C.danger),
              onPressed: () async {
                final picked = _sel.toList();
                if (!await confirm(context, 'Delete ${picked.length} files?',
                        message: 'They are removed from the printer.', action: 'Delete', danger: true) ||
                    !mounted) {
                  return;
                }
                await run(context, () async {
                  for (final p in picked) {
                    await c.deleteFile(p);
                  }
                }, done: 'Deleted ${picked.length} files');
                setState(_sel.clear);
                _all = null;
                _load();
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete'),
            ),
            TextButton(onPressed: () => setState(_sel.clear), child: const Text('Done')),
          ]),
        ),
      );

  Future<void> _loadQueue() async {
    try {
      final (q, state) = await c.queue();
      if (mounted) {
        setState(() {
          _queue = q;
          _queueState = state;
        });
      }
    } catch (_) {
      // No job_queue component on this printer; the panel stays hidden.
    }
  }

  Future<void> _ensureAll() async {
    if (_all != null) return;
    try {
      final all = await c.listFiles();
      if (mounted) setState(() => _all = all);
    } catch (_) {}
  }

  void _openDir(String dir) {
    setState(() {
      _path = dir;
      _dirs = c.lastDir[dir]?.$1 ?? const [];
      _files = c.lastDir[dir]?.$2;
    });
    _load();
  }

  List<GcodeFile> get _visible {
    final favs = settings.favourites(_favScope);
    final q = _query.toLowerCase();
    final source = (_query.isNotEmpty || _favOnly) ? (_all ?? const []) : (_files ?? const []);
    final list = [
      for (final f in source)
        if ((!_favOnly || favs.contains(f.path)) &&
            (q.isEmpty || f.path.toLowerCase().contains(q)))
          f,
    ];
    switch (_sort) {
      case _Sort.newest:
        list.sort((a, b) => b.modified.compareTo(a.modified));
      case _Sort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _Sort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
    }
    return list;
  }

  Future<void> _upload(String name, Uint8List bytes) async {
    if (name.toLowerCase().endsWith('.3mf')) {
      // Snapmaker Orca / Orca / Bambu project: take the sliced plate's G-code.
      final Map<int, Uint8List> plates;
      try {
        plates = platesIn3mf(bytes);
      } catch (e) {
        return toast(context, 'Could not read $name: $e', error: true);
      }
      if (plates.isEmpty) {
        return toast(context,
            'No sliced plate in $name. In the slicer, slice it and use Export plate sliced file (.gcode.3mf).',
            error: true);
      }
      var plate = plates.keys.first;
      if (plates.length > 1) {
        final pick = await showModalBottomSheet<int>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const ListTile(title: Text('Which plate?')),
              for (final n in plates.keys.toList()..sort())
                ListTile(title: Text('Plate $n'), onTap: () => Navigator.pop(ctx, n)),
            ]),
          ),
        );
        if (pick == null || !mounted) return;
        plate = pick;
      }
      final base = name.replaceAll(RegExp(r'(\.gcode)?\.3mf$', caseSensitive: false), '');
      name = '${base}_plate$plate.gcode';
      bytes = plates[plate]!;
    }
    setState(() => _uploading = true);
    try {
      await c.upload(name, bytes, folder: _path);
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        toast(context, 'Upload failed: $e', error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _all = null;
    });
    await _load();
    if (!mounted) return;
    final dest = _path.isEmpty ? name : '$_path/$name';
    if (await confirm(context, 'Uploaded $name',
            message: 'Start printing it now?', action: 'Print') &&
        mounted) {
      if (c.isSnapmaker) {
        final meta = await c.metadataWhenReady(dest);
        if (mounted) await snapmakerPrintSetup(context, c, dest, meta);
      } else {
        run(context, () => c.startPrint(dest), done: 'Print started');
      }
    }
  }

  Future<void> _pick() async {
    final f = await FilePicker.pickFile(
        type: FileType.custom, allowedExtensions: _gcodeExt);
    if (f == null || !mounted) return;
    await _upload(f.name, await f.readAsBytes());
  }

  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    for (final f in d.files) {
      final ext = f.name.split('.').last.toLowerCase();
      if (!_gcodeExt.contains(ext)) {
        toast(context, '${f.name} is not a G-code file', error: true);
        continue;
      }
      await _upload(f.name, await f.readAsBytes());
      if (!mounted) return;
    }
  }

  Future<void> _newFolder() async {
    final n = await askText(context, 'New folder',
        hint: 'Folder name', action: 'Create');
    if (n == null || n.isEmpty || !mounted) return;
    await run(context, () => c.createDir(_path.isEmpty ? n : '$_path/$n'));
    _load();
  }

  Future<void> _folderMenu(String name) async {
    final full = _path.isEmpty ? name : '$_path/$name';
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800))),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: const Text('Rename'),
            onTap: () => Navigator.pop(ctx, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: C.danger),
            title: const Text('Delete folder and its files'),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'rename') {
      final n = await askText(context, 'Rename folder', initial: name, action: 'Rename');
      if (n == null || n.isEmpty || n == name || !mounted) return;
      await run(context, () => c.moveFile(full, _path.isEmpty ? n : '$_path/$n'));
    } else {
      if (!await confirm(context, 'Delete $name?',
              message: 'Everything inside it is removed from the printer.',
              action: 'Delete',
              danger: true) ||
          !mounted) {
        return;
      }
      await run(context, () => c.deleteDir(full), done: 'Deleted');
    }
    _all = null;
    _load();
  }

  void _openFile(GcodeFile f) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => _FileSheet(
          client: c,
          file: f,
          favScope: _favScope,
          onChanged: () {
            _all = null;
            _load();
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final browsing = _query.isEmpty && !_favOnly;
    final files = _visible;
    final crumbs = _path.isEmpty ? <String>[] : _path.split('/');

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
                hintText: 'Search all files', prefixIcon: Icon(Icons.search_rounded)),
            onChanged: (v) {
              setState(() => _query = v);
              if (v.isNotEmpty) _ensureAll();
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Favourites only',
          isSelected: _favOnly,
          icon: const Icon(Icons.star_outline_rounded),
          selectedIcon: const Icon(Icons.star_rounded, color: C.warn),
          onPressed: () {
            setState(() => _favOnly = !_favOnly);
            if (_favOnly) _ensureAll();
          },
        ),
        PopupMenuButton<_Sort>(
          tooltip: 'Sort',
          icon: const Icon(Icons.sort_rounded),
          initialValue: _sort,
          onSelected: (v) => setState(() => _sort = v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: _Sort.newest, child: Text('Newest first')),
            PopupMenuItem(value: _Sort.name, child: Text('Name')),
            PopupMenuItem(value: _Sort.size, child: Text('Largest first')),
          ],
        ),
        IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _newFolder),
        IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              _all = null;
              _load();
            }),
      ]),
    );

    final breadcrumb = !browsing
        ? const SizedBox.shrink()
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              TextButton.icon(
                onPressed: crumbs.isEmpty ? null : () => _openDir(''),
                icon: const Icon(Icons.home_rounded, size: 18),
                label: const Text('All files'),
              ),
              for (var i = 0; i < crumbs.length; i++) ...[
                Icon(Icons.chevron_right_rounded, size: 18, color: C.muted),
                TextButton(
                  onPressed: i == crumbs.length - 1
                      ? null
                      : () => _openDir(crumbs.sublist(0, i + 1).join('/')),
                  child: Text(crumbs[i]),
                ),
              ],
            ]),
          );

    final queue = _queue.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Panel(
              title: 'Print queue (${_queue.length})',
              icon: Icons.queue_rounded,
              trailing: TextButton.icon(
                onPressed: () async {
                  await run(context,
                      _queueState == 'ready' ? c.pauseQueue : c.startQueue);
                  _loadQueue();
                },
                icon: Icon(_queueState == 'ready'
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
                label: Text(_queueState == 'ready' ? 'Pause queue' : 'Start queue'),
              ),
              child: Column(children: [
                for (final (i, j) in _queue.indexed)
                  Row(children: [
                    SizedBox(
                        width: 24,
                        child: Text('${i + 1}.', style: TextStyle(color: C.muted))),
                    Expanded(
                        child: Text(j.filename.split('/').last,
                            overflow: TextOverflow.ellipsis)),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () async {
                        await run(context, () => c.dequeue(j.id));
                        _loadQueue();
                      },
                    ),
                  ]),
                Text(
                  _queueState == 'ready'
                      ? 'The next job starts when the printer finishes the current one.'
                      : 'Queue is paused. Start it to print these one after another.',
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
              ]),
            ),
          );

    Widget list;
    if (_error != null) {
      list = StateView.error(_error!, onRetry: _load);
    } else if (_files == null || (!browsing && _all == null)) {
      list = const Center(child: CircularProgressIndicator());
    } else {
      final favs = settings.favourites(_favScope);
      final dirs = browsing ? _dirs : const <String>[];
      list = RefreshIndicator(
        onRefresh: () async {
          _all = null;
          await _load();
        },
        child: dirs.isEmpty && files.isEmpty
            ? ListView(children: [
                const SizedBox(height: 56),
                StateView.empty(
                    _favOnly ? Icons.star_outline_rounded : Icons.folder_open_rounded,
                    _favOnly ? 'No favourite files yet' : 'No files here'),
              ])
            : ListView.separated(
                key: ValueKey(_path), // new folder: rows replay their entrance
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                itemCount: dirs.length + files.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  if (i < dirs.length) {
                    final d = dirs[i];
                    return Reveal(index: i, child: Tile(
                      onTap: () => _openDir(_path.isEmpty ? d : '$_path/$d'),
                      child: ListTile(
                        leading: Icon(Icons.folder_rounded, color: C.warn, size: 32),
                        title: Text(d, style: const TextStyle(fontWeight: FontWeight.w600)),
                        trailing: IconButton(
                          tooltip: 'Folder options',
                          icon: const Icon(Icons.more_horiz_rounded),
                          onPressed: () => _folderMenu(d),
                        ),
                      ),
                    ));
                  }
                  final f = files[i - dirs.length];
                  return Reveal(index: i, child: _FileTile(
                    file: f,
                    client: c,
                    favourite: favs.contains(f.path),
                    showDir: !browsing,
                    selected: _sel.contains(f.path),
                    onTap: () => _sel.isEmpty ? _openFile(f) : _toggleSel(f.path),
                    onLongPress: () => _toggleSel(f.path),
                  ));
                },
              ),
      );
    }

    Widget body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(children: [
          header,
          breadcrumb,
          if (_sel.isNotEmpty) _selectionBar(),
          queue,
          Expanded(child: AnimatedSwitcher(duration: M.base, child: list)),
        ]),
      ),
    );
    if (_isDesktop) {
      body = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _onDrop,
        child: Stack(children: [
          body,
          if (_dragging)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: C.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.accent, width: 2),
                ),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.upload_file_rounded, size: 48, color: C.accent),
                  const SizedBox(height: 8),
                  Text(
                    'Drop G-code to upload${_path.isEmpty ? '' : ' to $_path'}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ]),
              ),
            ),
        ]),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _pick,
        icon: _uploading
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_rounded),
        label: Text(_uploading ? 'Uploading…' : 'Upload'),
      ),
      body: body,
    );
  }
}

class _Thumb extends StatelessWidget {
  final MoonrakerClient client;
  final String path;
  static const size = 52.0;
  const _Thumb({required this.client, required this.path});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(R.sm),
        child: Container(
          width: size,
          height: size,
          color: C.surfaceHi,
          child: FutureBuilder<Uint8List?>(
            future: Thumbs.of(client, path),
            builder: (_, snap) => snap.data == null
                ? Icon(Icons.description_outlined, color: C.accent)
                : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
          ),
        ),
      );
}

class _FileTile extends StatelessWidget {
  final GcodeFile file;
  final MoonrakerClient client;
  final bool favourite, showDir, selected;
  final VoidCallback onTap, onLongPress;
  const _FileTile({
    required this.file,
    required this.client,
    required this.favourite,
    required this.showDir,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) => Tile(
        onTap: onTap,
        onLongPress: onLongPress,
        selected: selected,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            _Thumb(client: client, path: file.path),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(file.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  '${fmtBytes(file.size)} · ${fmtAgo(file.modified)}'
                  '${showDir && file.dir.isNotEmpty ? ' · ${file.dir}' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
              ]),
            ),
            if (favourite) const Icon(Icons.star_rounded, color: C.warn, size: 18),
            Icon(Icons.chevron_right_rounded, color: C.muted),
          ]),
        ),
      );
}

class _FileSheet extends StatefulWidget {
  final MoonrakerClient client;
  final GcodeFile file;
  final String favScope;
  final VoidCallback onChanged;
  const _FileSheet({
    required this.client,
    required this.file,
    required this.favScope,
    required this.onChanged,
  });
  @override
  State<_FileSheet> createState() => _FileSheetState();
}

class _FileSheetState extends State<_FileSheet> {
  late final Future<Map<String, dynamic>> _meta =
      widget.client.metadata(widget.file.path);

  MoonrakerClient get c => widget.client;
  GcodeFile get f => widget.file;
  bool get _busy => c.status.state == 'printing' || c.status.state == 'paused';

  List<Printer> get _others => [
        for (final s in settings.strings('printers')) Printer.fromJson(jsonDecode(s)),
      ].where((p) => clientFor(p) != c).toList();

  /// Copies this file to another printer and offers to start it there.
  Future<void> _send() async {
    final to = await showModalBottomSheet<Printer>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Send to')),
          for (final p in _others)
            ListTile(
              title: Text(p.name),
              subtitle: Text(clientFor(p).status.online ? clientFor(p).status.state : 'offline'),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ]),
      ),
    );
    if (to == null || !mounted) return;
    final other = clientFor(to);
    var sent = false;
    await run(context, () async {
      await other.upload(f.name, await c.download(f.path));
      sent = true;
    }, done: 'Sent to ${to.name}');
    if (!sent || !mounted) return;
    final idle = other.status.online && !{'printing', 'paused'}.contains(other.status.state);
    if (idle && await confirm(context, 'Print ${f.name} on ${to.name} now?', action: 'Print') && mounted) {
      await run(context, () => other.startPrint(f.name), done: 'Printing on ${to.name}');
    }
  }

  Future<void> _preheat() async {
    if (_busy) return toast(context, 'A print is already running');
    final t = await askNumber(context, 'Heat the chamber to',
        presets: settings.presets('chamber').where((p) => p > 0).toList());
    if (t == null || t <= 0 || !mounted) return;
    c.startPrintAfterChamber(f.path, t);
    toast(context, 'Heating the chamber to $t°C. The print starts when it gets there.');
    Navigator.of(context).pop();
  }

  Future<void> _print() async {
    if (_busy) return toast(context, 'A print is already running');
    if (c.isSnapmaker) {
      final nav = Navigator.of(context);
      final meta = await _meta.catchError((_) => <String, dynamic>{});
      if (!mounted) return;
      if (await snapmakerPrintSetup(context, c, f.path, meta)) nav.pop();
      return;
    }
    if (!await confirm(context, 'Print ${f.name}?', action: 'Print') || !mounted) {
      return;
    }
    final nav = Navigator.of(context);
    await run(context, () => c.startPrint(f.path), done: 'Print started');
    nav.pop();
  }

  Future<void> _enqueue() async {
    final nav = Navigator.of(context);
    await run(context, () => c.enqueue(f.path), done: 'Added to the print queue');
    widget.onChanged();
    nav.pop();
  }

  Future<void> _later() async {
    final now = DateTime.now();
    final at = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start later'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, d) in const [
              ('In 30 min', Duration(minutes: 30)),
              ('In 1 h', Duration(hours: 1)),
              ('In 2 h', Duration(hours: 2)),
              ('In 4 h', Duration(hours: 4)),
              ('In 8 h', Duration(hours: 8)),
            ])
              ActionChip(label: Text(label), onPressed: () => Navigator.pop(ctx, now.add(d))),
            ActionChip(
              avatar: const Icon(Icons.schedule_rounded, size: 16),
              label: const Text('Pick a time…'),
              onPressed: () async {
                final t = await showTimePicker(
                    context: ctx, initialTime: TimeOfDay.fromDateTime(now));
                if (t == null || !ctx.mounted) return;
                var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
                if (at.isBefore(now)) at = at.add(const Duration(days: 1));
                Navigator.pop(ctx, at);
              },
            ),
          ]),
          const SizedBox(height: 14),
          Text('The app must stay open (it sends the start command at that time).',
              style: TextStyle(color: C.muted, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
    if (at == null || !mounted) return;
    c.schedulePrint(f.path, at);
    toast(context, '${f.name} starts at ${fmtTime(at)}');
    Navigator.pop(context);
  }

  Future<void> _rename() async {
    final n = await askText(context, 'Rename file', initial: f.name, action: 'Rename');
    if (n == null || n.isEmpty || n == f.name || !mounted) return;
    final nav = Navigator.of(context);
    await run(context, () => c.moveFile(f.path, f.dir.isEmpty ? n : '${f.dir}/$n'),
        done: 'Renamed');
    widget.onChanged();
    nav.pop();
  }

  Future<void> _move() async {
    final dir = await askText(context, 'Move to folder',
        initial: f.dir, hint: 'folder/sub-folder (empty = top level)', action: 'Move');
    if (dir == null || dir == f.dir || !mounted) return;
    final clean = dir.replaceAll(RegExp(r'^/+|/+$'), '');
    final nav = Navigator.of(context);
    await run(context, () => c.moveFile(f.path, clean.isEmpty ? f.name : '$clean/${f.name}'),
        done: 'Moved');
    widget.onChanged();
    nav.pop();
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete ${f.name}?',
            message: 'The file is removed from the printer.',
            action: 'Delete',
            danger: true) ||
        !mounted) {
      return;
    }
    final nav = Navigator.of(context);
    await run(context, () => c.deleteFile(f.path), done: 'Deleted');
    widget.onChanged();
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final fav = settings.isFavourite(widget.favScope, f.path);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(f.name,
                  style: T.title),
            ),
            IconButton(
              tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
              icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: fav ? C.warn : null),
              onPressed: () {
                setState(() => settings.toggleFavourite(widget.favScope, f.path));
                widget.onChanged();
              },
            ),
          ]),
          Text('${fmtBytes(f.size)} · ${fmtAgo(f.modified)}${f.dir.isEmpty ? '' : ' · ${f.dir}'}',
              style: TextStyle(color: C.muted)),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(R.md),
            child: Container(
              height: 200,
              color: C.surfaceHi,
              child: FutureBuilder<Uint8List?>(
                future: Thumbs.of(c, f.path),
                builder: (_, snap) => snap.data == null
                    ? Center(child: Icon(Icons.image_not_supported_outlined, color: C.muted))
                    : Image.memory(snap.data!, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FutureBuilder<Map<String, dynamic>>(
            future: _meta,
            builder: (context, snap) {
              if (!snap.hasData) return const LinearProgressIndicator();
              final m = snap.data!;
              return Wrap(spacing: 28, runSpacing: 12, children: [
                StatTile(label: 'Est. time', value: fmtDuration(m['estimated_time'] as num?)),
                StatTile(label: 'Filament', value: fmtFilament((m['filament_total'] as num?) ?? 0)),
                StatTile(
                    label: 'Layer height',
                    value: m['layer_height'] != null ? '${m['layer_height']} mm' : '—'),
                StatTile(label: 'Slicer', value: '${m['slicer'] ?? '—'}'),
                FilamentCheck(meta: m, client: c),
              ]);
            },
          ),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _enqueue,
                icon: const Icon(Icons.queue_rounded),
                label: const Text('Queue'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _print,
                icon: const Icon(Icons.print_rounded),
                label: const Text('Print now'),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ActionChip(
                avatar: const Icon(Icons.schedule_rounded, size: 16),
                label: const Text('Start later'),
                onPressed: _later),
            if (_others.isNotEmpty)
              ActionChip(
                avatar: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Send to another printer'),
                onPressed: _send,
              ),
            if (c.status.chamberHeatable)
              ActionChip(
                avatar: const Icon(Icons.local_fire_department_outlined, size: 16),
                label: const Text('Heat chamber first'),
                onPressed: _preheat,
              ),
            ActionChip(
              avatar: const Icon(Icons.layers_rounded, size: 16),
              label: const Text('Layer preview'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => GcodePreviewPage(client: c, file: f)),
              ),
            ),
            ActionChip(
                avatar: const Icon(Icons.drive_file_rename_outline_rounded, size: 16),
                label: const Text('Rename'),
                onPressed: _rename),
            ActionChip(
                avatar: const Icon(Icons.drive_file_move_outline, size: 16),
                label: const Text('Move'),
                onPressed: _move),
            ActionChip(
              avatar: const Icon(Icons.delete_outline_rounded, size: 16, color: C.danger),
              label: const Text('Delete'),
              onPressed: _delete,
            ),
          ]),
        ]),
      ),
    );
  }
}

GcodeModel _parseBytes(Uint8List bytes) =>
    parseGcode(utf8.decode(bytes, allowMalformed: true));

/// 2D layer viewer: downloads the file and draws each layer's moves.
class GcodePreviewPage extends StatefulWidget {
  final MoonrakerClient client;
  final GcodeFile file;
  const GcodePreviewPage({super.key, required this.client, required this.file});
  @override
  State<GcodePreviewPage> createState() => _GcodePreviewPageState();
}

class _GcodePreviewPageState extends State<GcodePreviewPage> {
  GcodeModel? _model;
  String _status = 'Downloading…';
  String? _error;
  int _layer = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.client.download(widget.file.path);
      if (!mounted) return;
      setState(() => _status = 'Reading ${fmtBytes(bytes.length)} of G-code…');
      final m = await compute(_parseBytes, bytes);
      if (!mounted) return;
      setState(() {
        _model = m;
        _layer = m.layers.isEmpty ? 0 : m.layers.length - 1;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _model;
    final bed = widget.client.status.axisMax;
    return Scaffold(
      appBar: AppBar(title: Text(widget.file.name, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: C.danger)))
          : m == null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_status, style: TextStyle(color: C.muted)),
                  ]),
                )
              : m.layers.isEmpty
                  ? Center(child: Text('No extrusion moves found', style: TextStyle(color: C.muted)))
                  : Column(children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: InteractiveViewer(
                            maxScale: 8,
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: LayerPainter(
                                m,
                                _layer,
                                bed[0] > 0 ? bed[0] : m.maxX,
                                bed[1] > 0 ? bed[1] : m.maxY,
                                color: C.accent,
                                below: C.muted.withValues(alpha: 0.25),
                                border: C.border,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Panel(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: Row(children: [
                              IconButton(
                                tooltip: 'Previous layer',
                                onPressed: _layer > 0 ? () => setState(() => _layer--) : null,
                                icon: const Icon(Icons.remove_rounded),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _layer.toDouble(),
                                  min: 0,
                                  max: (m.layers.length - 1).toDouble(),
                                  onChanged: (v) => setState(() => _layer = v.round()),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Next layer',
                                onPressed: _layer < m.layers.length - 1
                                    ? () => setState(() => _layer++)
                                    : null,
                                icon: const Icon(Icons.add_rounded),
                              ),
                              SizedBox(
                                width: 150,
                                child: Text(
                                  'Layer ${_layer + 1}/${m.layers.length}\n'
                                  'Z ${m.z[_layer].toStringAsFixed(2)} mm',
                                  textAlign: TextAlign.end,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ]),
    );
  }
}
