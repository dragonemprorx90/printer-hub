import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'gcode.dart';
import 'mesh.dart';
import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

/// Files the app slices on the home bridge (3MF too, when it isn't sliced yet).
const modelExt = ['stl', 'step', 'stp', 'obj'];

class SlicePrinter {
  final String id, name, process;
  final int tools;
  final List<String> processes, filaments;

  /// Build volume in mm. Null from a slicer older than the editor, which
  /// can't take placement or print settings.
  final List<double>? bed;
  SlicePrinter.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        process = '${j['process']}',
        tools = (j['tools'] as num?)?.toInt() ?? 1,
        bed = j['bed'] is List ? [for (final v in j['bed'] as List) (v as num).toDouble()] : null,
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
      String folder = '',
      String? settings,
      bool placed = false}) async {
    final r = await h.post(
      _u('jobs', {
        'printer': printer,
        'process': process,
        'filaments': filaments.join(';'),
        'tool': '$tool',
        'name': name,
        'folder': folder,
        'settings': ?settings,
        if (placed) 'arrange': '0',
      }),
      headers: {'content-type': 'application/octet-stream'},
      body: model,
    );
    return '${(_decode(r) as Map)['id']}';
  }

  /// [model] as a binary STL on [printer]'s plate (STEP and 3MF converted;
  /// [orient] lets Orca choose the orientation).
  Future<Uint8List> mesh(Uint8List model, {required String name, required String printer, bool orient = false}) async {
    final r = await h.post(_u('mesh', {'printer': printer, 'name': name, if (orient) 'orient': '1'}),
        headers: {'content-type': 'application/octet-stream'}, body: model);
    if (r.statusCode == 200) return r.bodyBytes;
    if (r.statusCode == 404 && r.body.contains('Not found')) {
      throw MoonrakerError('Update the slicer on your home bridge to view this model (setup guide, "Slicing").');
    }
    throw MoonrakerError(slicerError(r.statusCode, r.body));
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


/// Build volumes when the slicer doesn't say (it always does since 1.24).
const _beds = {'k2plus': [350.0, 350.0, 350.0], 'u1': [270.0, 270.0, 270.0]};

/// One print setting the editor can change. Unset means "as in the preset".
class SliceOption {
  final String key, label, unit;
  final List<(String, String)>? choices; // (value, label)
  final bool filament;
  const SliceOption(this.key, this.label, {this.unit = '', this.choices, this.filament = false});
}

const sliceGroups = <(String, IconData, List<SliceOption>)>[
  ('Quality', Icons.layers_rounded, [
    SliceOption('layer_height', 'Layer height', unit: 'mm'),
    SliceOption('wall_loops', 'Walls'),
    SliceOption('sparse_infill_density', 'Infill', unit: '%'),
    SliceOption('sparse_infill_pattern', 'Infill pattern', choices: [
      ('grid', 'Grid'), ('gyroid', 'Gyroid'), ('cubic', 'Cubic'), ('crosshatch', 'Cross hatch'),
      ('honeycomb', 'Honeycomb'), ('triangles', 'Triangles'), ('line', 'Line'),
      ('zig-zag', 'Rectilinear'), ('adaptivecubic', 'Adaptive cubic'), ('lightning', 'Lightning'),
    ]),
  ]),
  ('Supports', Icons.foundation_rounded, [
    SliceOption('support', 'Supports', choices: [('off', 'Off'), ('normal(auto)', 'Normal'), ('tree(auto)', 'Tree')]),
    SliceOption('support_threshold_angle', 'Overhang angle', unit: '°'),
    SliceOption('support_on_build_plate_only', 'Supports from', choices: [('1', 'Plate only'), ('0', 'Everywhere')]),
    SliceOption('brim_type', 'Brim', choices: [
      ('auto_brim', 'Auto'), ('no_brim', 'Off'), ('outer_only', 'Outer'), ('brim_ears', 'Ears'),
    ]),
  ]),
  ('Speed and flow', Icons.speed_rounded, [
    SliceOption('outer_wall_speed', 'Outer wall', unit: 'mm/s'),
    SliceOption('inner_speed', 'Inner + infill', unit: 'mm/s'),
    SliceOption('filament_flow_ratio', 'Flow ratio', filament: true),
  ]),
  ('Temperature', Icons.thermostat_rounded, [
    SliceOption('nozzle_temperature', 'Nozzle', unit: '°C', filament: true),
    SliceOption('bed_temperature', 'Bed', unit: '°C', filament: true),
  ]),
];

/// The `settings` JSON for POST /slicer/jobs from the editor's [values]
/// (option key -> value; missing keys keep the preset), or null if none.
/// Filament settings go to toolhead [tool], or to every toolhead when
/// [allTools] (a painted 3MF).
@visibleForTesting
String? settingsJson(Map<String, String> values, {required int tool, required int tools, bool allTools = false}) {
  final process = <String, String>{}, filament = <String, String>{};
  final filamentKeys = {
    for (final g in sliceGroups)
      for (final o in g.$3)
        if (o.filament) o.key,
  };
  values.forEach((k, v) {
    switch (k) {
      case 'support':
        process['enable_support'] = v == 'off' ? '0' : '1';
        if (v != 'off') process['support_type'] = v;
      case 'sparse_infill_density':
        process[k] = '$v%';
      case 'inner_speed':
        for (final key in ['inner_wall_speed', 'sparse_infill_speed', 'internal_solid_infill_speed']) {
          process[key] = v;
        }
      default:
        (filamentKeys.contains(k) ? filament : process)[k] = v;
    }
  });
  if (process.isEmpty && filament.isEmpty) return null;
  return jsonEncode({
    'process': process,
    'filaments': [
      for (var i = 0; i < tools; i++) (allTools || i == tool) && filament.isNotEmpty ? filament : null,
    ],
  });
}

final _number = RegExp(r'^\d+(\.\d+)?$');

GcodeModel _parseGcodeBytes(Uint8List b) => parseGcode(utf8.decode(b, allowMalformed: true));

(Mesh, Mesh) _readStl(Uint8List b) {
  final m = parseStl(b);
  return (m, decimate(m));
}

/// Opens the slice editor for [model]: see it on the plate, move, turn and
/// scale it, change print settings, slice on the home bridge and look at the
/// layers. Returns the G-code files it put on the printer when the user goes
/// on to print (null if closed first).
Future<List<String>?> showSliceDialog(BuildContext context, MoonrakerClient client, String name, Uint8List model,
        {String folder = ''}) =>
    Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => SliceEditor(client: client, name: name, model: model, folder: folder)),
    );

class SliceEditor extends StatefulWidget {
  final MoonrakerClient client;
  final String name, folder;
  final Uint8List model;

  /// The slicer to use instead of the one on the client's home bridge (tests).
  final SlicerApi? api;
  const SliceEditor(
      {super.key, required this.client, required this.name, required this.model, this.folder = '', this.api});
  @override
  State<SliceEditor> createState() => _SliceEditorState();
}

class _SliceEditorState extends State<SliceEditor> {
  SlicerApi? _api;
  void Function() _release = () {};
  List<SlicePrinter>? _printers;
  String? _error, _state;
  late SlicePrinter _p;
  late String _process;
  late List<String> _fils;
  int _tool = 0;
  bool _closed = false;
  Map<String, String> _values = {};

  // The model: full mesh for slicing, thinned one for drawing.
  (Mesh, Mesh)? _mesh, _original;
  String? _meshError;
  bool _meshBusy = false;
  late Placement _place;
  (List<double>, List<double>) _bounds1 = (const [0, 0, 0], const [0, 0, 0]); // turned, scale 1
  Float32List _drawn = Float32List(0);
  bool _moved = false, _layFlat = false;
  final _view = GlobalKey<MeshViewState>();

  // After slicing.
  Map<String, dynamic>? _done;
  GcodeModel? _layers;
  String? _layersError;

  bool get _is3mf => widget.name.toLowerCase().endsWith('.3mf');
  bool get _running => _state != null && _error == null;
  bool get _editor => _p.bed != null; // the slicer takes placement and settings
  List<double> get _bed => _p.bed ?? _beds[_p.id] ?? const [256, 256, 256];

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
      if (widget.api != null) {
        _api = widget.api;
      } else {
        final (h, release) = await widget.client.bridgeClient();
        if (_closed) return release();
        _release = release;
        _api = SlicerApi(h);
      }
      final printers = await _api!.presets();
      if (!mounted) return;
      final want = settings.text('slice.printer', widget.client.isSnapmaker ? 'u1' : 'k2plus');
      setState(() {
        _printers = printers;
        _pick(printers.firstWhere((p) => p.id == want, orElse: () => printers.first));
      });
      await _loadMesh();
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
    try {
      _values = (jsonDecode(settings.text('slice.${p.id}.overrides', '{}')) as Map).cast<String, String>();
    } catch (_) {
      _values = {};
    }
    _place = Placement(x: _bed[0] / 2, y: _bed[1] / 2, rot: _mesh == null ? identity : _place.rot, scale: _mesh == null ? 1 : _place.scale);
    if (_mesh != null) _refresh();
  }

  Future<void> _loadMesh() async {
    setState(() {
      _meshBusy = true;
      _meshError = null;
    });
    try {
      final stl = widget.name.toLowerCase().endsWith('.stl')
          ? widget.model
          : await _api!.mesh(widget.model, name: widget.name, printer: _p.id);
      final m = await compute(_readStl, stl);
      if (!mounted) return;
      setState(() {
        _mesh = _original = m;
        _place = Placement(x: _bed[0] / 2, y: _bed[1] / 2);
        _refresh(turned: true);
      });
    } catch (e) {
      if (mounted) setState(() => _meshError = '$e');
    } finally {
      if (mounted) setState(() => _meshBusy = false);
    }
  }

  /// Re-places the drawn mesh; [turned] after rotating or a new mesh.
  void _refresh({bool turned = false}) {
    final m = _mesh;
    if (m == null) return;
    if (turned) _bounds1 = turnedBounds(m.$1.v, _place.rot, 1);
    _drawn = place(m.$2.v, _place, _scaled);
  }

  (List<double>, List<double>) get _scaled => (
        [for (final v in _bounds1.$1) v * _place.scale],
        [for (final v in _bounds1.$2) v * _place.scale],
      );

  /// Size of the placed model in mm.
  List<double> get _size => [for (var i = 0; i < 3; i++) (_bounds1.$2[i] - _bounds1.$1[i]) * _place.scale];

  bool get _fits {
    final s = _size, b = _bed;
    return _place.x - s[0] / 2 >= -0.01 &&
        _place.x + s[0] / 2 <= b[0] + 0.01 &&
        _place.y - s[1] / 2 >= -0.01 &&
        _place.y + s[1] / 2 <= b[1] + 0.01 &&
        s[2] <= b[2] + 0.01;
  }

  void _edit(Placement p, {bool turned = false}) => setState(() {
        _place = p;
        _moved = true;
        _refresh(turned: turned);
      });

  void _rotate(int axis, double deg) =>
      _edit(_place.copyWith(rot: mulRot(axisRot(axis, deg), _place.rot)), turned: true);

  void _onFace(int t) {
    final (x, y, z) = normalOf(_drawn, t);
    _layFlat = false;
    _edit(_place.copyWith(rot: mulRot(downRot(x, y, z), _place.rot)), turned: true);
  }

  void _reset() => setState(() {
        _mesh = _original;
        _moved = false;
        _place = Placement(x: _bed[0] / 2, y: _bed[1] / 2);
        _refresh(turned: true);
      });

  /// Orca's auto-orient on the model as it is now.
  Future<void> _autoOrient() async {
    setState(() => _meshBusy = true);
    try {
      final stl = await _api!.mesh(toStl(place(_mesh!.$1.v, _place, _scaled)),
          name: 'model.stl', printer: _p.id, orient: true);
      final m = await compute(_readStl, stl);
      if (!mounted) return;
      setState(() {
        _mesh = m;
        _moved = true;
        _place = Placement(x: _place.x, y: _place.y);
        _refresh(turned: true);
      });
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _meshBusy = false);
    }
  }

  Future<void> _slice() async {
    settings
      ..setText('slice.printer', _p.id)
      ..setText('slice.${_p.id}.process', _process)
      ..setStrings('slice.${_p.id}.filaments', _fils)
      ..setNumber('slice.${_p.id}.tool', _tool.toDouble())
      ..setText('slice.${_p.id}.overrides', jsonEncode(_values));
    setState(() {
      _error = null;
      _state = 'Sending the model…';
    });
    try {
      // A 3MF nobody moved goes as it is (painted colours, plates); anything
      // else as the placed mesh, sliced where it stands.
      final asIs = _mesh == null || !_editor || (_is3mf && !_moved);
      final stem = widget.name.contains('.') ? widget.name.substring(0, widget.name.lastIndexOf('.')) : widget.name;
      final id = await _api!.start(asIs ? widget.model : toStl(place(_mesh!.$1.v, _place, _scaled)),
          name: asIs ? widget.name : '$stem.stl',
          printer: _p.id,
          process: _process,
          filaments: _fils,
          tool: _tool,
          folder: widget.folder,
          placed: !asIs,
          settings: _editor ? settingsJson(_values, tool: _tool, tools: _p.tools, allTools: _is3mf && asIs) : null);
      while (!_closed) {
        final j = await _api!.job(id);
        switch (j['state']) {
          case 'done':
            if (mounted) {
              setState(() {
                _state = null;
                _done = j;
              });
              _loadLayers('${(j['files'] as List).first}');
            }
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

  Future<void> _loadLayers(String path) async {
    setState(() {
      _layers = null;
      _layersError = null;
    });
    try {
      final m = await compute(_parseGcodeBytes, await widget.client.download(path));
      if (mounted) setState(() => _layers = m);
    } catch (e) {
      if (mounted) setState(() => _layersError = '$e');
    }
  }

  // --- Building blocks ------------------------------------------------------

  Widget _dropdown(String label, String value, List<(String, String)> items, ValueChanged<String> onChanged) =>
      DropdownButtonFormField<String>(
        key: ValueKey('$label/$value/${_p.id}'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: _running ? null : (v) => v == null ? null : setState(() => onChanged(v)),
      );

  Widget _names(String label, String value, List<String> items, ValueChanged<String> onChanged) =>
      _dropdown(label, value, [for (final i in items) (i, i)], onChanged);

  Widget _option(SliceOption o) {
    final value = _values[o.key];
    if (o.choices != null) {
      return _dropdown(o.label, value ?? '', [('', 'Preset'), ...o.choices!], (v) {
        v.isEmpty ? _values.remove(o.key) : _values[o.key] = v;
      });
    }
    return TextFormField(
      key: ValueKey('${o.key}/${_p.id}/${value == null}'),
      initialValue: value,
      enabled: !_running,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
          labelText: o.label,
          hintText: 'Preset',
          suffixText: o.unit,
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
      validator: (v) => v == null || v.trim().isEmpty || _number.hasMatch(v.trim()) ? null : 'A number',
      onChanged: (v) {
        v = v.trim();
        if (v.isEmpty) {
          _values.remove(o.key);
        } else if (_number.hasMatch(v)) {
          _values[o.key] = v;
        }
      },
    );
  }

  /// Fields two to a row.
  Widget _grid(List<Widget> fields) => LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth >= 320 ? (box.maxWidth - 12) / 2 : box.maxWidth;
          return Wrap(spacing: 12, runSpacing: 12, children: [for (final f in fields) SizedBox(width: w, child: f)]);
        },
      );

  Widget _printerPanel() {
    final p = _p;
    return Panel(
      title: 'Printer',
      icon: Icons.print_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _grid([
          if (_printers!.length > 1)
            _names('Printer', p.name, [for (final x in _printers!) x.name],
                (v) => _pick(_printers!.firstWhere((x) => x.name == v))),
          _names('Quality preset', _process, p.processes, (v) => _process = v),
          for (var i = 0; i < p.tools; i++)
            _names(p.tools == 1 ? 'Filament' : 'Toolhead ${i + 1}', _fils[i], p.filaments, (v) => _fils[i] = v),
        ]),
        if (p.tools > 1 && !(_is3mf && !_moved)) ...[
          const SizedBox(height: 12),
          Text('PRINT WITH', style: T.label.copyWith(color: C.muted, letterSpacing: 1.1)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [for (var i = 0; i < p.tools; i++) ButtonSegment(value: i, label: Text('T${i + 1}'))],
            selected: {_tool},
            showSelectedIcon: false,
            onSelectionChanged: _running ? null : (s) => setState(() => _tool = s.first),
          ),
        ],
        if (p.tools > 1 && _is3mf && !_moved) ...[
          const SizedBox(height: 12),
          const Hint('Uses the colours painted in the 3MF, in toolhead order.'),
        ],
      ]),
    );
  }

  Widget _placePanel() {
    final s = _size;
    final busy = _running || _meshBusy || _mesh == null;
    Widget axis(String name, int i) => Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 18, child: Text(name, style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(
            tooltip: 'Turn $name −15°',
            onPressed: busy ? null : () => _rotate(i, -15),
            icon: const Icon(Icons.rotate_left_rounded),
          ),
          IconButton(
            tooltip: 'Turn $name +15°',
            onPressed: busy ? null : () => _rotate(i, 15),
            icon: const Icon(Icons.rotate_right_rounded),
          ),
          TextButton(onPressed: busy ? null : () => _rotate(i, 90), child: const Text('90°')),
        ]);
    return Panel(
      title: 'Place',
      icon: Icons.open_with_rounded,
      trailing: TextButton(onPressed: busy || !_moved ? null : _reset, child: const Text('Reset')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          _mesh == null
              ? '—'
              : '${s[0].toStringAsFixed(1)} × ${s[1].toStringAsFixed(1)} × ${s[2].toStringAsFixed(1)} mm'
                  ' · at ${_place.x.toStringAsFixed(0)}, ${_place.y.toStringAsFixed(0)}',
          style: T.small.copyWith(color: C.muted, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 4, runSpacing: 0, children: [axis('X', 0), axis('Y', 1), axis('Z', 2)]),
        Row(children: [
          Text('Scale', style: T.small.copyWith(color: C.muted)),
          Expanded(
            child: Slider(
              value: math.log(_place.scale) / math.ln2,
              min: -3.33,
              max: 2,
              onChanged: busy ? null : (v) => _edit(_place.copyWith(scale: math.pow(2, v).toDouble())),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text('${(_place.scale * 100).round()}%',
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilterChip(
            avatar: const Icon(Icons.touch_app_rounded, size: 16),
            label: const Text('Lay on face'),
            selected: _layFlat,
            onSelected: busy ? null : (v) => setState(() => _layFlat = v),
          ),
          ActionChip(
            avatar: const Icon(Icons.auto_fix_high_rounded, size: 16),
            label: const Text('Auto-orient'),
            onPressed: busy ? null : _autoOrient,
          ),
          ActionChip(
            avatar: const Icon(Icons.center_focus_strong_rounded, size: 16),
            label: const Text('Centre'),
            onPressed: busy ? null : () => _edit(_place.copyWith(x: _bed[0] / 2, y: _bed[1] / 2)),
          ),
        ]),
        const SizedBox(height: 12),
        Text(
          _layFlat
              ? 'Tap the face that should rest on the plate.'
              : 'Drag the model to move it. Drag elsewhere to turn the view; pinch or scroll to zoom, two fingers to pan.',
          style: T.caption.copyWith(color: C.muted),
        ),
        if (_is3mf && _moved) ...[
          const SizedBox(height: 12),
          const Hint('Slices the mesh as placed here: colours painted in the 3MF and its other plates are not kept.'),
        ],
        if (_mesh != null && !_fits) ...[
          const SizedBox(height: 12),
          Hint('The model doesn\'t fit the ${_bed[0].round()} × ${_bed[1].round()} × ${_bed[2].round()} mm build volume.',
              color: C.danger),
        ],
      ]),
    );
  }

  Widget _settingsPanels() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (title, icon, opts) in sliceGroups) ...[
          Panel(
            title: title == 'Temperature' && _p.tools > 1 && !(_is3mf && !_moved) ? 'Temperature · T${_tool + 1}' : title,
            icon: icon,
            trailing: title == 'Quality' && _values.isNotEmpty && !_running
                ? TextButton(onPressed: () => setState(() => _values = {}), child: const Text('Use preset'))
                : null,
            child: _grid([for (final o in opts) _option(o)]),
          ),
          const SizedBox(height: 12),
        ],
      ]);

  Widget _viewer() {
    if (_done != null) {
      if (_layersError != null) return StateView.error(_layersError!);
      if (_layers == null) return const Center(child: CircularProgressIndicator());
      if (_layers!.layers.isEmpty) return StateView.empty(Icons.layers_clear_rounded, 'No extrusion moves found');
      return LayerView(_layers!, _bed[0], _bed[1]);
    }
    if (_meshError != null) {
      return StateView.error(_meshError!, onRetry: _api == null ? null : _loadMesh);
    }
    if (_mesh == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_printers == null ? 'Connecting to your home bridge…' : 'Loading the model…',
              style: T.small.copyWith(color: C.muted)),
        ]),
      );
    }
    return Stack(children: [
      Positioned.fill(
        child: MeshView(
          key: _view,
          mesh: _drawn,
          bed: _bed,
          color: _fits ? C.accent : C.danger,
          layFlat: _layFlat,
          onMove: _editor && !_running ? (dx, dy) => _edit(_place.copyWith(x: _place.x + dx, y: _place.y + dy)) : null,
          onFace: _onFace,
        ),
      ),
      Positioned(
        top: 8,
        right: 8,
        child: IconButton.filledTonal(
          tooltip: 'Reset view',
          onPressed: () => _view.currentState?.reset(),
          icon: const Icon(Icons.threed_rotation_rounded),
        ),
      ),
      if (_meshBusy) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
    ]);
  }

  Widget _resultPanel() {
    final j = _done!;
    final files = [for (final f in j['files'] as List) '$f'];
    Widget stat(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.toUpperCase(), style: T.label.copyWith(color: C.muted, letterSpacing: 1.1)),
            const SizedBox(height: 4),
            Text(value, style: T.value.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );
    return Panel(
      title: 'Sliced',
      icon: Icons.check_circle_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          stat('Print time', fmtDuration(j['time'] as num?)),
          stat('Filament', (j['weight'] as num? ?? 0) > 0 ? '${j['weight']} g' : '—'),
        ]),
        const SizedBox(height: 12),
        Text(files.join('\n'), style: T.small.copyWith(color: C.muted)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, files),
          icon: const Icon(Icons.print_rounded),
          label: const Text('Continue to print'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() => _done = null),
          icon: const Icon(Icons.edit_rounded),
          label: const Text('Back to editing'),
        ),
      ]),
    );
  }

  Widget _panel() {
    if (_done != null) {
      return ListView(padding: const EdgeInsets.all(16), children: [_resultPanel()]);
    }
    final ready = _printers != null;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('OrcaSlicer on your home bridge', style: T.small.copyWith(color: C.muted)),
          const SizedBox(height: 12),
          if (!ready && _error == null) const Center(child: CircularProgressIndicator()),
          if (ready) ...[
            _printerPanel(),
            const SizedBox(height: 12),
            if (_editor) ...[
              _placePanel(),
              const SizedBox(height: 12),
              _settingsPanels(),
            ] else
              const Hint('Update the slicer on your home bridge to place the model and change print settings '
                  '(setup guide, "Slicing").'),
          ],
        ]),
      ),
      SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: C.border))),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_error != null) ...[Hint(_error!, color: C.danger), const SizedBox(height: 8)],
            if (_running) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_state!, style: T.small.copyWith(color: C.muted)),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              onPressed: !ready || _running || _meshBusy || (_mesh != null && _editor && !_fits) ? null : _slice,
              icon: const Icon(Icons.layers_rounded),
              label: Text(_error == null ? 'Slice' : 'Try again'),
            ),
          ]),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _running) toast(context, 'Still slicing. The file shows up in Files when it\'s done.');
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
        body: LayoutBuilder(builder: (context, box) {
          final view = ClipRect(child: _viewer());
          if (box.maxWidth >= 840) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: view),
              Container(
                width: 400,
                decoration: BoxDecoration(border: Border(left: BorderSide(color: C.border))),
                child: _panel(),
              ),
            ]);
          }
          return Column(children: [
            SizedBox(height: box.maxHeight * 0.42, child: view),
            Divider(height: 1, color: C.border),
            Expanded(child: _panel()),
          ]);
        }),
      ),
    );
  }
}
