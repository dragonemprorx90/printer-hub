import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

/// Files the app slices on the home bridge (3MF too, when it isn't sliced yet).
const modelExt = ['stl', 'step', 'stp', 'obj'];

class SlicePrinter {
  final String id, name, process;
  final int tools;
  final List<String> processes, filaments;
  SlicePrinter.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        process = '${j['process']}',
        tools = (j['tools'] as num?)?.toInt() ?? 1,
        processes = [for (final p in j['processes'] as List) '$p'],
        filaments = [for (final f in j['filaments'] as List) '$f'];
}

/// The slicer container next to the home bridge (slicer/server.py), reached
/// through the relay. Only the path and query matter; the bridge forwards
/// /slicer/* to 127.0.0.1 on its own machine.
class SlicerApi {
  final http.Client h;
  SlicerApi(this.h);

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: 'bridge', path: '/slicer/$path', queryParameters: q);

  static dynamic _decode(http.Response r) {
    if (r.statusCode == 200) return jsonDecode(r.body);
    throw MoonrakerError(slicerError(r.statusCode, r.body));
  }

  Future<List<SlicePrinter>> presets() async => [
        for (final p in (_decode(await h.get(_u('presets'))) as Map)['printers'] as List)
          SlicePrinter.fromJson(p as Map<String, dynamic>),
      ];

  Future<String> start(Uint8List model,
      {required String name,
      required String printer,
      required String process,
      required List<String> filaments,
      int tool = 0,
      String folder = ''}) async {
    final r = await h.post(
      _u('jobs', {
        'printer': printer,
        'process': process,
        'filaments': filaments.join(';'),
        'tool': '$tool',
        'name': name,
        'folder': folder,
      }),
      headers: {'content-type': 'application/octet-stream'},
      body: model,
    );
    return '${(_decode(r) as Map)['id']}';
  }

  Future<Map<String, dynamic>> job(String id) async =>
      (_decode(await h.get(_u('jobs/$id'))) as Map).cast<String, dynamic>();
}

/// What to tell the user when the slicer answers [status] with [body].
@visibleForTesting
String slicerError(int status, String body) {
  // 502: the bridge couldn't reach the container. 404 without our JSON: a
  // bridge from before slicing, which sends /slicer/ on to the printer.
  if (status == 502 || (status == 404 && !body.contains('"error"'))) {
    return 'The slicer isn\'t running on your home bridge. Update it and add slicer to '
        'COMPOSE_PROFILES (setup guide, "Slicing").';
  }
  try {
    return '${(jsonDecode(body) as Map)['error']}';
  } catch (_) {
    return 'Slicer error (HTTP $status)';
  }
}

/// Picks presets, slices [model] on the home bridge and returns the G-code
/// files it put on the printer (null if closed first).
Future<List<String>?> showSliceDialog(BuildContext context, MoonrakerClient client, String name, Uint8List model,
        {String folder = ''}) =>
    showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SliceDialog(client: client, name: name, model: model, folder: folder),
    );

class _SliceDialog extends StatefulWidget {
  final MoonrakerClient client;
  final String name, folder;
  final Uint8List model;
  const _SliceDialog({required this.client, required this.name, required this.model, required this.folder});
  @override
  State<_SliceDialog> createState() => _SliceDialogState();
}

class _SliceDialogState extends State<_SliceDialog> {
  SlicerApi? _api;
  void Function() _release = () {};
  List<SlicePrinter>? _printers;
  String? _error, _state;
  late SlicePrinter _p;
  late String _process;
  late List<String> _fils;
  int _tool = 0;
  bool _closed = false;

  bool get _is3mf => widget.name.toLowerCase().endsWith('.3mf');
  bool get _running => _state != null && _error == null;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _closed = true;
    _release();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final (h, release) = await widget.client.bridgeClient();
      if (_closed) return release();
      _release = release;
      _api = SlicerApi(h);
      final printers = await _api!.presets();
      if (!mounted) return;
      final want = settings.text('slice.printer', widget.client.isSnapmaker ? 'u1' : 'k2plus');
      setState(() {
        _printers = printers;
        _pick(printers.firstWhere((p) => p.id == want, orElse: () => printers.first));
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Selects printer [p] with the choices remembered for it.
  void _pick(SlicePrinter p) {
    _p = p;
    final process = settings.text('slice.${p.id}.process', p.process);
    _process = p.processes.contains(process) ? process : p.process;
    final saved = settings.strings('slice.${p.id}.filaments');
    _fils = [
      for (var i = 0; i < p.tools; i++)
        i < saved.length && p.filaments.contains(saved[i]) ? saved[i] : p.filaments.first,
    ];
    _tool = settings.number('slice.${p.id}.tool', 0).toInt().clamp(0, p.tools - 1);
  }

  Future<void> _slice() async {
    settings
      ..setText('slice.printer', _p.id)
      ..setText('slice.${_p.id}.process', _process)
      ..setStrings('slice.${_p.id}.filaments', _fils)
      ..setNumber('slice.${_p.id}.tool', _tool.toDouble());
    setState(() {
      _error = null;
      _state = 'Sending the model…';
    });
    try {
      final id = await _api!.start(widget.model,
          name: widget.name, printer: _p.id, process: _process, filaments: _fils, tool: _tool, folder: widget.folder);
      while (!_closed) {
        final j = await _api!.job(id);
        switch (j['state']) {
          case 'done':
            if (mounted) Navigator.pop(context, [for (final f in j['files'] as List) '$f']);
            return;
          case 'error':
            throw MoonrakerError('${j['error']}');
        }
        if (mounted) {
          setState(() => _state = switch (j['state']) {
                'converting' => 'Reading the STEP file…',
                'slicing' => 'Slicing…',
                'uploading' => 'Sending the G-code to the printer…',
                _ => 'Waiting for the slicer…',
              });
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Widget _dropdown(String label, String value, List<String> items, ValueChanged<String> onChanged) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          key: ValueKey('$label/$value'),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i, overflow: TextOverflow.ellipsis))],
          onChanged: _running ? null : (v) => v == null ? null : setState(() => onChanged(v)),
        ),
      );

  Widget _form() {
    final p = _p;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_printers!.length > 1)
        _dropdown('Printer', p.name, [for (final x in _printers!) x.name],
            (v) => _pick(_printers!.firstWhere((x) => x.name == v))),
      _dropdown('Quality', _process, p.processes, (v) => _process = v),
      for (var i = 0; i < p.tools; i++)
        _dropdown(p.tools == 1 ? 'Filament' : 'Toolhead ${i + 1}', _fils[i], p.filaments, (v) => _fils[i] = v),
      if (p.tools > 1 && !_is3mf)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PRINT WITH', style: T.label.copyWith(color: C.muted, letterSpacing: 1.1)),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: [for (var i = 0; i < p.tools; i++) ButtonSegment(value: i, label: Text('T${i + 1}'))],
              selected: {_tool},
              showSelectedIcon: false,
              onSelectionChanged: _running ? null : (s) => setState(() => _tool = s.first),
            ),
          ]),
        ),
      if (p.tools > 1 && _is3mf) const Hint('Uses the colours painted in the 3MF, in toolhead order.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _printers != null;
    return AlertDialog(
      title: const Text('Slice model'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.name, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
            Text('OrcaSlicer on your home bridge', style: T.small.copyWith(color: C.muted)),
            const SizedBox(height: 16),
            if (ready) _form() else if (_error == null) const Center(child: CircularProgressIndicator()),
            if (_running) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_state!, style: T.small.copyWith(color: C.muted)),
            ],
            if (_error != null) Hint(_error!, color: C.danger),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_running) toast(context, 'Still slicing. The file shows up in Files when it\'s done.');
            Navigator.pop(context);
          },
          child: Text(_running ? 'Close' : 'Cancel'),
        ),
        if (ready)
          FilledButton(
            onPressed: _running ? null : _slice,
            child: Text(_error == null ? 'Slice' : 'Try again'),
          ),
      ],
    );
  }
}
