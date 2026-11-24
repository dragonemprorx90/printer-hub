import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gcode.dart';
import 'models_page.dart';
import 'insights.dart';
import 'moonraker.dart';
import 'settings.dart';
import 'slice_where.dart';
import 'slicer.dart';
import 'u1_panels.dart';
import 'ui.dart';
import 'workshop_page.dart';

enum _Sort { newest, oldest, name, size, smallest, popular }

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
  final _searchCtl = TextEditingController();
  _Sort _sort = _Sort.newest;
  bool _favOnly = false, _dragging = false, _uploading = false, _recentOnly = false;
  List<QueuedJob> _queue = const [];
  final _sel = <String>{}; // long-press to select several files
  String _queueState = '';
  final _est = <String, double?>{}; // estimated seconds per queued file

  MoonrakerClient get c => widget.client;
  String get _favScope => 'files.${widget.printer.key}';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

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
            Text('${_sel.length} selected · ${fmtBytes(totalSize([for (final f in [...?_all, ...?_files]) if (_sel.contains(f.path)) f].fold(<String, GcodeFile>{}, (m, f) => m..[f.path] = f).values))}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            TextButton(
              onPressed: () => setState(() => _sel.addAll(_visible.map((f) => f.path))),
              child: const Text('Select all'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final t = await askText(context, 'Add tags to ${_sel.length} files', hint: 'e.g. gifts, spare parts', action: 'Add');
                if (t == null || t.trim().isEmpty || !mounted) return;
                final add = [for (final x in t.split(',')) if (x.trim().isNotEmpty) x.trim()];
                for (final p in _sel) {
                  final k = 'tags.$_favScope.$p';
                  final have = settings.text(k).split(', ').where((x) => x.isNotEmpty).toSet()..addAll(add);
                  settings.setText(k, have.join(', '));
                }
                toast(context, 'Tagged ${_sel.length} files');
                setState(_sel.clear);
              },
              icon: const Icon(Icons.sell_outlined),
              label: const Text('Tag'),
            ),
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
              onPressed: () async {
                final picked = _sel.toList();
                final dir = await askText(context, 'Move ${picked.length} files to folder',
                    hint: 'folder/sub-folder (empty = top level)', action: 'Move');
                if (dir == null || !mounted) return;
                final clean = dir.replaceAll(RegExp(r'^/+|/+$'), '');
                await run(context, () async {
                  for (final p in picked) {
                    final name = p.split('/').last;
                    await c.moveFile(p, clean.isEmpty ? name : '$clean/$name');
                  }
                }, done: 'Moved ${picked.length} files');
                setState(_sel.clear);
                _all = null;
                _load();
              },
              icon: const Icon(Icons.drive_file_move_outlined),
              label: const Text('Move'),
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
      for (final j in q.where((j) => !_est.containsKey(j.filename))) {
        _est[j.filename] = null;
        c.metadata(j.filename).then((m) {
          if (mounted) setState(() => _est[j.filename] = (m['estimated_time'] as num?)?.toDouble());
        }).catchError((_) {});
      }
    } catch (_) {
      // No job_queue component on this printer; the panel stays hidden.
    }
  }

  /// Storage used, likely duplicates and old files. Picking a group selects
  /// those files; deleting still goes through the selection bar (asks first).
  Future<void> _tidy() async {
    await _ensureAll();
    final all = _all;
    if (all == null || !mounted) return;
    final dups = duplicates(all);
    final days = settings.number('tidyDays', 90).round();
    final old = olderThan(all, days);
    final pick = await showModalBottomSheet<List<GcodeFile>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true, children: [
        Text('Tidy up', style: T.title),
        const SizedBox(height: 12),
        Wrap(spacing: 24, runSpacing: 12, children: [
          StatTile(label: 'Files', value: '${all.length}'),
          StatTile(label: 'Space used', value: fmtBytes(totalSize(all))),
          StatTile(label: 'Copies', value: '${dups.fold(0, (a, g) => a + g.length - 1)}'),
          StatTile(label: 'Older than $days days', value: '${old.length}'),
        ]),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history_toggle_off_rounded),
          title: Text('Select ${old.length} files older than $days days'),
          subtitle: Text(fmtBytes(totalSize(old))),
          enabled: old.isNotEmpty,
          onTap: () => Navigator.pop(ctx, old),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.copy_all_rounded),
          title: const Text('Select the extra copies'),
          subtitle: const Text('Keeps the newest of each'),
          enabled: dups.isNotEmpty,
          onTap: () => Navigator.pop(ctx, [
            for (final g in dups) ...([...g]..sort((a, b) => b.modified.compareTo(a.modified))).skip(1),
          ]),
        ),
        for (final g in dups.take(20))
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 4),
            child: Text('${g.first.name}: ${g.map((f) => f.dir.isEmpty ? '/' : f.dir).join(', ')}',
                style: T.caption.copyWith(color: C.muted), overflow: TextOverflow.ellipsis),
          ),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Old means older than'),
          const Spacer(),
          for (final d in const [30, 90, 180])
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ChoiceChip(
                label: Text('$d d'),
                selected: d == days,
                onSelected: (_) {
                  settings.setNumber('tidyDays', d.toDouble());
                  Navigator.pop(ctx);
                  _tidy();
                },
              ),
            ),
        ]),
      ]),
    );
    if (pick == null || pick.isEmpty || !mounted) return;
    setState(() => _sel
      ..clear()
      ..addAll(pick.map((f) => f.path)));
    toast(context, '${pick.length} selected. Check them, then Delete.');
  }

  /// Every tag in use, with how many files carry it; tap one to show them.
  Future<void> _tagList() async {
    await _ensureAll();
    if (!mounted) return;
    final counts = <String, int>{};
    for (final f in _all ?? const <GcodeFile>[]) {
      for (final t in settings.text('tags.$_favScope.${f.path}').split(', ')) {
        if (t.isNotEmpty) counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Text('Tags', style: T.title),
        if (counts.isEmpty) const Hint('No tags yet. Open a file and tap Tags, or select several and tap Tag.'),
        for (final e in (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sell_outlined),
            title: Text('#${e.key}'),
            trailing: Text('${e.value}'),
            onTap: () => Navigator.pop(ctx, e.key),
          ),
      ]),
    );
    if (pick == null || !mounted) return;
    _searchCtl.text = '#$pick';
    setState(() => _query = '#$pick');
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
    final source = (_query.isNotEmpty || _favOnly || _recentOnly) ? (_all ?? const []) : (_files ?? const []);
    final recent = {
      for (final j in c.lastHistory?.$1 ?? const <PrintJob>[])
        if (DateTime.now().difference(j.start).inDays < 30) j.filename,
    };
    final list = [
      for (final f in source)
        if ((!_favOnly || favs.contains(f.path)) &&
            (!_recentOnly || recent.contains(f.path)) &&
            (q.isEmpty ||
                f.path.toLowerCase().contains(q) ||
                (q.startsWith('#') && settings.text('tags.$_favScope.${f.path}').toLowerCase().contains(q.substring(1)))))
          f,
    ];
    switch (_sort) {
      case _Sort.newest:
        list.sort((a, b) => b.modified.compareTo(a.modified));
      case _Sort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _Sort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
      case _Sort.oldest:
        list.sort((a, b) => a.modified.compareTo(b.modified));
      case _Sort.smallest:
        list.sort((a, b) => a.size.compareTo(b.size));
      case _Sort.popular:
        final jobs = c.lastHistory?.$1 ?? const <PrintJob>[];
        final n = <String, int>{for (final j in jobs) j.filename: 0};
        for (final j in jobs) {
          n[j.filename] = n[j.filename]! + 1;
        }
        list.sort((a, b) => (n[b.path] ?? 0).compareTo(n[a.path] ?? 0));
    }
    return list;
  }

  /// Slices a model on the home bridge, then opens the new G-code (preview, print).
  Future<void> _slice(String name, Uint8List bytes) async {
    final files = await sliceOrSend(context, c, name, bytes, folder: _path);
    if (files == null || files.isEmpty || !mounted) return;
    await _show(files.first);
  }

  /// Online models: ready G-code or a sliced model lands here, then opens.
  Future<void> _findModels() async {
    final path = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => ModelsPage(client: c, folder: _path)));
    if (path != null && mounted) await _show(path);
  }

  /// Reloads the folder and opens [path]'s sheet (preview, print).
  Future<void> _show(String path) async {
    _all = null;
    // Moonraker reads the new file's time and filament a moment after upload.
    await Future.wait([_load(), c.metadataWhenReady(path)]);
    if (!mounted) return;
    final f = _files?.where((f) => f.path == path).firstOrNull;
    if (f != null) _openFile(f);
  }

  Future<void> _upload(String name, Uint8List bytes) async {
    if (modelExt.contains(name.split('.').last.toLowerCase())) return _slice(name, bytes);
    if (name.toLowerCase().endsWith('.3mf')) {
      // Snapmaker Orca / Orca / Bambu project: take the sliced plate's G-code.
      final Map<int, Uint8List> plates;
      try {
        plates = platesIn3mf(bytes);
      } catch (e) {
        return toast(context, 'Could not read $name: $e', error: true);
      }
      if (plates.isEmpty) {
        if (c.relay == null) {
          return toast(context,
              'No sliced plate in $name. In the slicer, slice it and use Export plate sliced file (.gcode.3mf).',
              error: true);
        }
        return _slice(name, bytes);
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
        if (await preflight(context) && mounted) run(context, () => c.startPrint(dest), done: 'Print started');
      }
    }
  }

  Future<void> _pick() async {
    // Pick one or several: each goes up in turn (models still open the slicer one by one).
    final picked = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: [..._gcodeExt, ...modelExt]);
    for (final f in picked) {
      if (!mounted) return;
      await _upload(f.name, await f.readAsBytes());
    }
    if (picked.length > 1 && mounted) toast(context, 'Uploaded ${picked.length} files');
  }

  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    for (final f in d.files) {
      final ext = f.name.split('.').last.toLowerCase();
      if (!_gcodeExt.contains(ext) && !modelExt.contains(ext)) {
        toast(context, '${f.name} is not G-code or a 3D model', error: true);
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
    final browsing = _query.isEmpty && !_favOnly && !_recentOnly;
    final files = _visible;
    final crumbs = _path.isEmpty ? <String>[] : _path.split('/');

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _searchCtl,
            decoration: const InputDecoration(
                hintText: 'Search all files, or #tag', prefixIcon: Icon(Icons.search_rounded)),
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
        IconButton(
          tooltip: _recentOnly ? 'Showing files printed in the last 30 days' : 'Printed in the last 30 days',
          isSelected: _recentOnly,
          icon: const Icon(Icons.history_rounded),
          selectedIcon: Icon(Icons.history_rounded, color: C.accent),
          onPressed: () {
            setState(() => _recentOnly = !_recentOnly);
            if (_recentOnly) _ensureAll();
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
            PopupMenuItem(value: _Sort.oldest, child: Text('Oldest first')),
            PopupMenuItem(value: _Sort.smallest, child: Text('Smallest first')),
            PopupMenuItem(value: _Sort.popular, child: Text('Printed most')),
          ],
        ),
        IconButton(
            tooltip: settings.flag('filesGrid', false) ? 'Show as a list' : 'Show as a grid',
            icon: Icon(settings.flag('filesGrid', false) ? Icons.view_list_rounded : Icons.grid_view_rounded),
            onPressed: () => setState(() => settings.setFlag('filesGrid', !settings.flag('filesGrid', false)))),
        IconButton(
            tooltip: 'Tags',
            icon: const Icon(Icons.sell_outlined),
            onPressed: _tagList),
        IconButton(
            tooltip: 'Tidy up',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: _tidy),
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
              if (_files != null && _files!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('${_files!.length} files · ${fmtBytes(totalSize(_files!))}',
                      style: T.caption.copyWith(color: C.muted)),
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

    final st = c.status;
    final busy = st.state == 'printing' || st.state == 'paused';
    final finish = queueFinishTimes([for (final j in _queue) _est[j.filename] == null ? null : _est[j.filename]! * st.etaFactor],
        from: DateTime.now(), currentLeft: busy ? (st.eta ?? 0) : 0);
    final total = _queue.fold(0.0, (a, j) => a + (_est[j.filename] ?? 0));
    final queue = _queue.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Panel(
              title: 'Print queue (${_queue.length})',
              icon: Icons.queue_rounded,
              trailing: TextButton.icon(
                onPressed: () async {
                  final idle = !const {'printing', 'paused'}.contains(c.status.state);
                  if (_queueState != 'ready' && idle &&
                      !await confirm(context, 'Start the queue?',
                          message: 'The first job (${_queue.first.filename.split('/').last}) starts printing now. Is the plate clear?',
                          action: 'Start')) {
                    return;
                  }
                  if (!context.mounted) return;
                  await run(context,
                      _queueState == 'ready' ? c.pauseQueue : c.startQueue);
                  _loadQueue();
                },
                icon: Icon(_queueState == 'ready'
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
                label: Text(_queueState == 'ready'
                    ? 'Pause queue'
                    : (st.state == 'complete' || st.state == 'cancelled' ? 'Bed is clear, start next' : 'Start queue')),
              ),
              child: Column(children: [
                if (_queue.length > 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () async {
                        if (!await confirm(context, 'Clear the queue?', message: 'The files stay; only the queue is emptied.', action: 'Clear') ||
                            !context.mounted) {
                          return;
                        }
                        await run(context, () async {
                          for (final j in [..._queue]) {
                            await c.dequeue(j.id);
                          }
                        }, done: 'Queue cleared');
                        _loadQueue();
                      },
                      child: const Text('Clear queue'),
                    ),
                  ),
                for (final (i, j) in _queue.indexed)
                  Row(children: [
                    if (_queueState != 'ready')
                      IconButton(
                        tooltip: 'Move up',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                        onPressed: i == 0
                            ? null
                            : () async {
                                final l = [..._queue]..insert(i - 1, _queue[i])..removeAt(i + 1);
                                await run(context, () => c.setQueueOrder(l));
                                _loadQueue();
                              },
                      ),
                    SizedBox(
                        width: 24,
                        child: Text('${i + 1}.', style: TextStyle(color: C.muted))),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(width: 32, height: 32, child: FittedBox(child: _Thumb(client: c, path: j.filename))),
                    ),
                    Expanded(
                        child: Text(j.filename.split('/').last,
                            overflow: TextOverflow.ellipsis)),
                    if (finish.length > i && _est[j.filename] != null)
                      Text('done ${fmtTime(finish[i])}', style: T.caption.copyWith(color: C.muted)),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () async {
                        await run(context, () => c.dequeue(j.id));
                        _loadQueue();
                      },
                    ),
                  ]),
                if (total > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${fmtDuration(total)} in all, done about ${fmtTime(finish.last)}',
                        style: T.small.copyWith(color: C.muted)),
                  ),
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
                  _favOnly ? 'No favourite files yet' : 'No files here',
                  action: _favOnly
                      ? null
                      : FilledButton.tonalIcon(
                          onPressed: _findModels,
                          icon: const Icon(Icons.travel_explore_rounded),
                          label: const Text('Find models online'),
                        ),
                ),
              ])
            : settings.flag('filesGrid', false) && dirs.isEmpty
            ? GridView.builder(
                key: ValueKey('grid $_path'),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.8),
                itemCount: files.length,
                itemBuilder: (_, i) {
                  final f = files[i];
                  return Reveal(
                    index: i,
                    child: Tile(
                      onTap: () => _sel.isEmpty ? _openFile(f) : _toggleSel(f.path),
                      onLongPress: () => _toggleSel(f.path),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: Container(
                            color: _sel.contains(f.path) ? C.accent.withValues(alpha: 0.2) : C.surfaceHi,
                            child: FutureBuilder<Uint8List?>(
                              future: Thumbs.of(c, f.path),
                              builder: (_, snap) => snap.data == null
                                  ? Icon(Icons.description_outlined, color: C.accent, size: 40)
                                  : Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.small),
                            Text(
                                '${DateTime.now().difference(f.modified).inHours < 24 ? 'new · ' : ''}${fmtBytes(f.size)} · ${fmtAgo(f.modified)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: T.caption.copyWith(color: C.muted)),
                          ]),
                        ),
                      ]),
                    ),
                  );
                },
              )
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
                    'Drop G-code or a model${_path.isEmpty ? '' : ' into $_path'}',
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
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        FloatingActionButton.small(
          heroTag: 'findModels',
          tooltip: 'Find models online',
          onPressed: _findModels,
          child: const Icon(Icons.travel_explore_rounded),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'upload',
          onPressed: _uploading ? null : _pick,
          icon: _uploading
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_rounded),
          label: Text(_uploading ? 'Uploading…' : 'Upload'),
        ),
      ]),
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
                Row(children: [
                  Flexible(
                    child: Text(file.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  if (DateTime.now().difference(file.modified).inHours < 24)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: C.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(99)),
                      child: Text('new', style: T.caption.copyWith(color: C.ink(C.accent), fontWeight: FontWeight.w700)),
                    ),
                ]),
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
  bool _idle(Printer p) {
    final s = clientFor(p).status;
    return s.online && !{'printing', 'paused', 'error'}.contains(s.state);
  }

  Future<void> _send() async {
    final to = await showModalBottomSheet<Printer>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Send to')),
          // Idle printers first; a smaller bed than this one gets a warning.
          for (final (i, p) in ([..._others]..sort((a, b) => (_idle(b) ? 1 : 0).compareTo(_idle(a) ? 1 : 0))).indexed)
            ListTile(
              title: Text('${p.name}${i == 0 && _idle(p) ? '  ·  suggested' : ''}'),
              subtitle: Text([
                clientFor(p).status.online ? clientFor(p).status.state : 'offline',
                if (clientFor(p).status.buildVolume case final v?) '${v[0].round()}×${v[1].round()}×${v[2].round()} mm',
                if ((c.status.buildVolume, clientFor(p).status.buildVolume) case (final mine?, final theirs?)
                    when !fits(mine, theirs))
                  'smaller bed than this printer: check the model fits',
              ].join(' · ')),
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
    final meta = await _meta.catchError((_) => <String, dynamic>{});
    if (!mounted) return;
    final st = c.status;
    final warn = materialWarning('${meta['filament_type'] ?? ''}'.split(';').first,
        hasChamber: st.chamberHeatable, chamberTemp: st.hasChamber ? st.chamber : null);
    final hot = tempWarning('${meta['filament_type'] ?? ''}'.split(';').first,
        (meta['first_layer_extr_temp'] ?? meta['nozzle_temperature']) as num?);
    final soft = cfsWarning('${meta['filament_type'] ?? ''}'.split(';').first, hasCfs: st.cfs.isNotEmpty);
    final est = (meta['estimated_time'] as num?)?.toDouble();
    final when = est == null || est <= 0 ? null : 'Done about ${fmtTime(DateTime.now().add(Duration(seconds: est.round())))}.';
    if (!await confirm(context, 'Print ${f.name}?', message: [?when, ?warn, ?soft, ?hot].isEmpty ? null : [?when, ?warn, ?soft, ?hot].join('\n\n'), action: 'Print') || !mounted) {
      return;
    }
    if (!await preflight(context) || !mounted) return;
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

  String get _tagKey => 'tags.${widget.favScope}.${f.path}';

  Future<void> _tags() async {
    final t = await askText(context, 'Tags', initial: settings.text(_tagKey), hint: 'e.g. gifts, spare parts', action: 'Save');
    if (t == null || !mounted) return;
    setState(() => settings.setText(_tagKey, t.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).join(', ')));
    widget.onChanged();
  }

  Future<void> _later() async {
    final now = DateTime.now();
    final est = ((await _meta.catchError((_) => <String, dynamic>{}))['estimated_time'] as num?)?.toDouble();
    if (!mounted) return;
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
            if (est != null && est > 0)
              ActionChip(
                avatar: const Icon(Icons.flag_outlined, size: 16),
                label: const Text('Finish at…'),
                onPressed: () async {
                  final t = await showTimePicker(
                      context: ctx, initialTime: TimeOfDay.fromDateTime(now.add(Duration(seconds: est.round() + 3600))));
                  if (t == null || !ctx.mounted) return;
                  var end = DateTime(now.year, now.month, now.day, t.hour, t.minute);
                  if (end.isBefore(now)) end = end.add(const Duration(days: 1));
                  final start = startForFinish(end, est);
                  if (start == null) {
                    toast(ctx, 'Too soon: the print takes ${fmtDuration(est)}', error: true);
                    return;
                  }
                  Navigator.pop(ctx, start);
                },
              ),
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

  /// Tags and the favourite star follow a renamed or moved file.
  void _carryOver(String to) {
    final tags = settings.text(_tagKey);
    if (tags.isNotEmpty) {
      settings.setText('tags.${widget.favScope}.$to', tags);
      settings.setText(_tagKey, '');
    }
    if (settings.isFavourite(widget.favScope, f.path)) {
      settings.toggleFavourite(widget.favScope, f.path);
      settings.toggleFavourite(widget.favScope, to);
    }
  }

  Future<void> _rename() async {
    final n = await askText(context, 'Rename file', initial: f.name, action: 'Rename');
    if (n == null || n.isEmpty || n == f.name || !mounted) return;
    final nav = Navigator.of(context);
    final to = f.dir.isEmpty ? n : '${f.dir}/$n';
    await run(context, () => c.moveFile(f.path, to), done: 'Renamed');
    _carryOver(to);
    widget.onChanged();
    nav.pop();
  }

  Future<void> _move() async {
    final dir = await askText(context, 'Move to folder',
        initial: f.dir, hint: 'folder/sub-folder (empty = top level)', action: 'Move');
    if (dir == null || dir == f.dir || !mounted) return;
    final clean = dir.replaceAll(RegExp(r'^/+|/+$'), '');
    final nav = Navigator.of(context);
    final to = clean.isEmpty ? f.name : '$clean/${f.name}';
    await run(context, () => c.moveFile(f.path, to), done: 'Moved');
    _carryOver(to);
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
              tooltip: 'Copy the file name',
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: f.name));
                toast(context, 'Name copied');
              },
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
          if (settings.text(_tagKey).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, children: [
                for (final t in settings.text(_tagKey).split(', ')) Chip(label: Text('#$t'), visualDensity: VisualDensity.compact),
              ]),
            ),
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
                    : GestureDetector(
                        // Tap for a big picture, pinch to zoom.
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => Scaffold(
                                      appBar: AppBar(title: Text(f.name)),
                                      body: InteractiveViewer(
                                          maxScale: 6, child: Center(child: Image.memory(snap.data!, fit: BoxFit.contain))),
                                    ))),
                        child: Image.memory(snap.data!, fit: BoxFit.contain),
                      ),
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
                if ((m['estimated_time'] as num? ?? 0) > 0 && (c.status.etaFactor - 1).abs() > 0.03)
                  StatTile(
                      label: 'On this printer',
                      value: 'about ${fmtDuration((m['estimated_time'] as num) * c.status.etaFactor)}'),
                if ((m['estimated_time'] as num? ?? 0) > 0)
                  StatTile(
                      label: 'Done if started now',
                      value: fmtTime(DateTime.now().add(Duration(seconds: ((m['estimated_time'] as num) * c.status.etaFactor).round())))),
                StatTile(label: 'Filament', value: fmtFilament((m['filament_total'] as num?) ?? 0)),
                StatTile(
                    label: 'Weight',
                    value: m['filament_weight_total'] is num
                        ? '${(m['filament_weight_total'] as num).toStringAsFixed(1)} g'
                        : '—'),
                StatTile(
                    label: 'Layer height',
                    value: m['layer_height'] != null ? '${m['layer_height']} mm' : '—'),
                StatTile(label: 'Slicer', value: '${m['slicer'] ?? '—'}'),
                if (m['filament_weight_total'] is num)
                  StatTile(
                      label: 'Cost (filament + power)',
                      value: '${settings.text('currency', r'$')}${((m['filament_weight_total'] as num) / 1000 * settings.pricePerKg('${m['filament_type'] ?? ''}') + ((m['estimated_time'] as num?) ?? 0) / 3600 * settings.number('printerWatts', 350) / 1000 * settings.number('kwhPrice', 0.30)).toStringAsFixed(2)}'),
                if (toolChanges(m) case final n? when n > 0) StatTile(label: 'Tool changes', value: '$n'),
                if (fileRecord(c.lastHistory?.$1 ?? const [], f.path) case (final n, final ok, final avg) when n > 0) ...[
                  StatTile(label: 'Printed before', value: '$n× ($ok finished)'),
                  if (avg != null) StatTile(label: 'Real time', value: fmtDuration(avg)),
                ],
                FilamentCheck(meta: m, client: c),
                for (final n in settings.jsonList('materialNotes'))
                  if ('${m['filament_type'] ?? ''}'.toUpperCase().contains('${n['m']}'.toUpperCase()) ||
                      '${n['m']}'.toUpperCase().contains('${m['filament_type'] ?? '~'}'.split(';').first.toUpperCase()))
                    Hint('Your note for ${n['m']}: ${n['t']}'),
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
            ActionChip(
                avatar: const Icon(Icons.sell_outlined, size: 16),
                label: const Text('Tags'),
                onPressed: _tags),
            ActionChip(
                avatar: const Icon(Icons.repeat_rounded, size: 16),
                label: const Text('Queue several'),
                onPressed: () async {
                  final n = await askNumber(context, 'How many copies in the queue?', presets: const [2, 3, 5, 10], unit: '');
                  if (n == null || n < 1 || !context.mounted) return;
                  final nav = Navigator.of(context);
                  await run(context, () async {
                    for (var i = 0; i < n.clamp(1, 50); i++) {
                      await c.enqueue(f.path);
                    }
                  }, done: 'Added $n to the queue');
                  widget.onChanged();
                  nav.pop();
                }),
            ActionChip(
                avatar: const Icon(Icons.copy_all_rounded, size: 16),
                label: const Text('Duplicate'),
                onPressed: () async {
                  final stem = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
                  final ext = f.name.contains('.') ? f.name.substring(f.name.lastIndexOf('.')) : '';
                  final n = await askText(context, 'Name of the copy', initial: '$stem copy$ext', action: 'Copy');
                  if (n == null || n.isEmpty || !context.mounted) return;
                  final nav = Navigator.of(context);
                  await run(context, () => c.copyFile(f.path, f.dir.isEmpty ? n : '${f.dir}/$n'), done: 'Copied');
                  widget.onChanged();
                  nav.pop();
                }),
            ActionChip(
                avatar: const Icon(Icons.save_alt_rounded, size: 16),
                label: const Text('Save to this device'),
                onPressed: () => run(context, () async {
                      final bytes = await c.download(f.path);
                      await FilePicker.saveFile(fileName: f.name, bytes: bytes);
                    })),
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
      setState(() => _model = m);
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
                  : LayerView(m, bed[0] > 0 ? bed[0] : m.maxX, bed[1] > 0 ? bed[1] : m.maxY),
    );
  }
}
