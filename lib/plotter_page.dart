// The pen plotter (Elegoo Neptune with plot macros on its pad): plot controls,
// pen setup, and writing text on an A4 page or a photo of a worksheet. Text is
// laid out by the plot service next to the home bridge (neptune/plotter/
// server.py, which wraps plot.py), reached like the slicer at /slicer/plot/*.
//
// Safety: nothing here moves the machine without a deliberate tap. Starting a
// plot, Home, Set origin and Cancel ask first; while it isn't homed only Home
// is offered.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';

import 'moonraker.dart';
import 'relay.dart';
import 'ui.dart';

const kPage = Size(210, 297); // A4, mm

/// Pen colours: the plotter has one pen, so a colour is whichever pen is loaded.
const plotColours = {
  'black': Color(0xFF1B1B1F),
  'blue': Color(0xFF1E50D8),
  'red': Color(0xFFD32F2F),
  'green': Color(0xFF2E7D32),
  'purple': Color(0xFF7B1FA2),
  'orange': Color(0xFFEF6C00),
};

const plotStyles = {
  'hand': 'My handwriting',
  'neat': 'Neat',
  'bold': 'Bold',
  'cursive': 'Cursive',
  'script': 'Script',
  'serif': 'Serif',
  'gothic': 'Gothic',
};

/// One block of text on the page. [pos] is its top-left in mm on the paper.
class PlotBox {
  String text;
  String style;
  double em;
  bool mistakes;
  int seed;
  String colour;
  Offset pos;
  PlotBox({
    this.text = '',
    this.style = 'hand',
    this.em = 7,
    this.mistakes = true,
    int? seed,
    this.colour = 'blue',
    this.pos = const Offset(17, 23),
  }) : seed = seed ?? math.Random().nextInt(1 << 30);

  // From the plot service's preview: strokes relative to [pos] (mm, y down).
  List<List<Offset>> paths = const [];
  Size size = Size.zero;
  int seconds = 0;
  String? error;
  bool busy = false;

  Map<String, dynamic> toJson() => {
        'text': text,
        'style': style,
        'em': em,
        'x_mm': pos.dx,
        'y_mm': pos.dy,
        'mistakes': mistakes ? 0.06 : 0,
        'seed': seed, // the same seed for preview and plot, so they match
      };
}

/// Boxes grouped by pen colour, in the order the colours first appear: one
/// G-code file (and one pen swap) per group.
List<(String, List<PlotBox>)> groupByColour(Iterable<PlotBox> boxes) {
  final groups = <String, List<PlotBox>>{};
  for (final b in boxes) {
    (groups[b.colour] ??= []).add(b);
  }
  return [for (final e in groups.entries) (e.key, e.value)];
}

/// The projective transform taking the four points [from] to [to] (each
/// top-left, top-right, bottom-right, bottom-left), as a Matrix4 for [Transform].
Matrix4 homography(List<Offset> from, List<Offset> to) {
  // Solve the 8 unknowns of [[a b c][d e f][g h 1]].
  final m = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final (x, y, u, v) = (from[i].dx, from[i].dy, to[i].dx, to[i].dy);
    m[2 * i].setAll(0, [x, y, 1, 0, 0, 0, -u * x, -u * y, u]);
    m[2 * i + 1].setAll(0, [0, 0, 0, x, y, 1, -v * x, -v * y, v]);
  }
  for (var c = 0; c < 8; c++) {
    var p = c;
    for (var r = c + 1; r < 8; r++) {
      if (m[r][c].abs() > m[p][c].abs()) p = r;
    }
    final t = m[c];
    m[c] = m[p];
    m[p] = t;
    if (m[c][c].abs() < 1e-12) return Matrix4.identity(); // degenerate corners
    for (var r = 0; r < 8; r++) {
      if (r == c) continue;
      final k = m[r][c] / m[c][c];
      for (var j = c; j < 9; j++) {
        m[r][j] -= k * m[c][j];
      }
    }
  }
  final h = [for (var i = 0; i < 8; i++) m[i][8] / m[i][i]];
  // Column-major; z passes through.
  return Matrix4(h[0], h[3], 0, h[6], h[1], h[4], 0, h[7], 0, 0, 1, 0, h[2], h[5], 0, 1);
}

/// The plot service through the home bridge (or the slicer address).
class PlotApi {
  final http.Client h;
  PlotApi(this.h);

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await h.post(Uri(scheme: 'http', host: 'bridge', path: '/slicer/plot/$path'),
        headers: {'content-type': 'application/json'}, body: jsonEncode(body));
    Map<String, dynamic>? j;
    try {
      j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    } catch (_) {}
    if (r.statusCode == 200 && j != null) return j;
    if (r.statusCode == 502 || (r.statusCode == 404 && j?['error'] == null)) {
      throw MoonrakerError('The plot service isn\'t running next to this printer\'s home bridge.');
    }
    throw MoonrakerError('${j?['error'] ?? 'Plot service error (HTTP ${r.statusCode})'}');
  }

  Future<Map<String, dynamic>> preview(PlotBox b) => _post('preview', b.toJson());

  /// Makes the G-code and uploads it (never starts it). Returns {file, seconds}.
  Future<Map<String, dynamic>> send(String name, List<PlotBox> boxes) =>
      _post('send', {'name': name, 'boxes': [for (final b in boxes) b.toJson()], 'start': false});
}

/// An uploaded file waiting for its pen.
class PlotStep {
  final String file, colour;
  final int seconds;
  bool started = false;
  PlotStep(this.file, this.colour, this.seconds);
}

class PlotterPage extends StatefulWidget {
  final Printer printer;
  final MoonrakerClient client;
  const PlotterPage({super.key, required this.printer, required this.client});
  @override
  State<PlotterPage> createState() => _PlotterPageState();
}

class _PlotterPageState extends State<PlotterPage> {
  int _tab = 0;
  final _steps = <PlotStep>[];
  int _filesEpoch = 0;

  void _sent(List<PlotStep> steps) {
    setState(() {
      _steps
        ..clear()
        ..addAll(steps);
      _filesEpoch++;
      _tab = 0;
    });
    toast(context, 'Uploaded. Load the ${steps.first.colour.toUpperCase()} pen, then tap Plot.');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<PrinterStatus>(
          stream: c.stream,
          initialData: c.status,
          builder: (_, snap) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.printer.name, overflow: TextOverflow.ellipsis, style: T.title),
            Text(plotSummary(snap.data!), style: T.caption.copyWith(color: C.muted, fontWeight: FontWeight.w400)),
          ]),
        ),
      ),
      body: IndexedStack(index: _tab, children: [
        _ControlTab(client: c, steps: _steps, filesEpoch: _filesEpoch, onClear: () => setState(_steps.clear)),
        PlotEditor(client: c, worksheet: false, onSent: _sent),
        PlotEditor(client: c, worksheet: true, onSent: _sent),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.gesture_rounded), label: 'Plot'),
          NavigationDestination(icon: Icon(Icons.edit_rounded), label: 'Write'),
          NavigationDestination(icon: Icon(Icons.description_rounded), label: 'On a page'),
        ],
      ),
    );
  }
}

/// "Not homed", "Plotting 42%", "Ready" ...
String plotSummary(PrinterStatus s) {
  if (!s.online) return 'Offline';
  if (s.klippy != 'ready') return 'Klipper ${s.klippy}';
  if (s.state == 'printing') return 'Plotting ${(s.progress * 100).round()}%';
  if (s.state == 'paused') return 'Paused';
  return s.homed ? 'Ready' : 'Not homed';
}

// --- Plot tab: status, queue, pen setup, files --------------------------------

class _ControlTab extends StatelessWidget {
  final MoonrakerClient client;
  final List<PlotStep> steps;
  final int filesEpoch;
  final VoidCallback onClear;
  const _ControlTab({required this.client, required this.steps, required this.filesEpoch, required this.onClear});

  @override
  Widget build(BuildContext context) => StreamBuilder<PrinterStatus>(
        stream: client.stream,
        initialData: client.status,
        builder: (context, snap) {
          final s = snap.data!;
          final ready = s.online && s.klippy == 'ready';
          final active = s.state == 'printing' || s.state == 'paused';
          final idle = ready && s.homed && !active;
          return ListView(padding: const EdgeInsets.all(16), children: [
            _status(context, s, ready, active),
            if (steps.isNotEmpty) ...[const SizedBox(height: 12), _queue(context, idle)],
            if (idle) ...[const SizedBox(height: 12), _pen(context, s)],
            const SizedBox(height: 12),
            _PlotFiles(key: ValueKey(filesEpoch), client: client, canPlot: idle),
          ]);
        },
      );

  Widget _status(BuildContext context, PrinterStatus s, bool ready, bool active) {
    final pos = s.toolPosition;
    String p(int i) => pos.length > i ? pos[i].toStringAsFixed(1) : '—';
    final left = s.progress > 0.01 ? s.printDuration * (1 - s.progress) / s.progress : null;
    return Panel(
      title: 'Plotter',
      icon: Icons.gesture_rounded,
      trailing: s.online ? StatusPill(state: s.state, online: s.online, dense: true) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!s.online)
          Text(client.linkError ?? 'Connecting…', style: T.small.copyWith(color: C.muted))
        else if (s.klippy != 'ready')
          Hint('Klipper is ${s.klippy}. ${s.klippyMessage ?? ''}'.trim(), color: C.danger)
        else ...[
          if (!s.homed) ...[
            const Hint('Not homed. Home it before plotting (it forgets after a restart).'),
            const SizedBox(height: 12),
          ],
          StatGrid(columns: 3, children: [
            StatTile(label: 'X', value: p(0)),
            StatTile(label: 'Y', value: p(1)),
            StatTile(label: 'Z', value: p(2)),
          ]),
          if (active) ...[
            const SizedBox(height: 12),
            Text(s.filename?.split('/').last ?? '', overflow: TextOverflow.ellipsis, style: T.value),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: s.progress),
            const SizedBox(height: 12),
            StatGrid(columns: 3, children: [
              StatTile(label: 'Progress', value: '${(s.progress * 100).round()}%'),
              StatTile(label: 'Elapsed', value: fmtDuration(s.printDuration)),
              StatTile(label: 'Left', value: left == null ? '—' : fmtDuration(left)),
            ]),
          ],
        ],
        if (ready) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (s.state == 'printing')
              FilledButton.tonalIcon(
                  onPressed: () => run(context, client.pause, done: 'Pausing'),
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('Pause')),
            if (s.state == 'paused')
              FilledButton.icon(
                  onPressed: () => run(context, client.resume, done: 'Resuming'),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Resume')),
            if (active)
              OutlinedButton.icon(
                  onPressed: () async {
                    if (await confirm(context, 'Cancel this plot?',
                            message: 'The pen lifts and the plot stops. It can\'t be resumed.',
                            action: 'Cancel plot',
                            danger: true) &&
                        context.mounted) {
                      run(context, client.cancel, done: 'Cancelled');
                    }
                  },
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Cancel')),
            if (!active && !s.homed) _homeButton(context, filled: true),
            FilterChip(
              avatar: const Icon(Icons.lightbulb_outline_rounded, size: 18),
              label: const Text('Light'),
              selected: s.plotLight,
              onSelected: (on) =>
                  run(context, () => client.gcode('SET_LED LED=LED_Light WHITE=${on ? 1 : 0}')),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _homeButton(BuildContext context, {bool filled = false}) {
    Future<void> go() async {
      if (await confirm(context, 'Home the plotter?',
              message: 'The head and bed move to their end stops. Clear the bed of anything but the paper tray, '
                  'and keep hands away.',
              action: 'Home') &&
          context.mounted) {
        run(context, () => client.gcode('G28'), done: 'Homed');
      }
    }

    const icon = Icon(Icons.home_rounded);
    const label = Text('Home');
    return filled
        ? FilledButton.icon(onPressed: go, icon: icon, label: label)
        : OutlinedButton.icon(onPressed: go, icon: icon, label: label);
  }

  Widget _queue(BuildContext context, bool idle) => Panel(
        title: 'Ready to plot',
        icon: Icons.playlist_play_rounded,
        trailing: TextButton(onPressed: onClear, child: const Text('Clear')),
        child: Column(children: [
          for (final (i, st) in steps.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(radius: 10, backgroundColor: plotColours[st.colour] ?? C.muted),
              title: Text('${i == 0 ? 'Load' : 'Swap to'} the ${st.colour.toUpperCase()} pen'),
              subtitle: Text('${st.file} · about ${fmtDuration(st.seconds)}'),
              trailing: st.started
                  ? Icon(Icons.check_rounded, color: C.accent)
                  : FilledButton(
                      // One at a time, in order: the earlier colours first.
                      onPressed: idle && steps.take(i).every((e) => e.started)
                          ? () async {
                              if (await confirm(context, 'Load the ${st.colour.toUpperCase()} pen',
                                      message: 'With the ${st.colour} pen in the holder and paper in the tray, '
                                          'plot ${st.file} (about ${fmtDuration(st.seconds)})? '
                                          'The plotter starts moving straight away.',
                                      action: 'Plot') &&
                                  context.mounted) {
                                await run(context, () async {
                                  await client.startPrint(st.file);
                                  st.started = true;
                                }, done: 'Plotting ${st.file}');
                              }
                            }
                          : null,
                      child: const Text('Plot'),
                    ),
            ),
        ]),
      );

  Widget _pen(BuildContext context, PrinterStatus s) {
    final v = s.plotVars;
    final down = (v['plot_zdown'] as num?)?.toDouble();
    void setDown(double z) => run(context,
        () => client.gcode('SAVE_VARIABLE VARIABLE=plot_zdown VALUE=${math.max(0, z).toStringAsFixed(2)}'));
    return Panel(
      title: 'Pen setup',
      icon: Icons.edit_note_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => run(context, () => client.gcode('PEN_UP')),
              icon: const Icon(Icons.north_rounded),
              label: const Text('Pen up')),
          OutlinedButton.icon(
              onPressed: () => run(context, () => client.gcode('PEN_DOWN')),
              icon: const Icon(Icons.south_rounded),
              label: const Text('Pen down')),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Text('Pen-down height', style: T.small)),
          IconButton(
              tooltip: 'Lower 0.1 mm (presses harder)',
              onPressed: down == null ? null : () => setDown(down - 0.1),
              icon: const Icon(Icons.remove_rounded)),
          SizedBox(
              width: 64,
              child: Text(down == null ? '—' : 'Z ${down.toStringAsFixed(2)}', textAlign: TextAlign.center, style: T.value)),
          IconButton(
              tooltip: 'Raise 0.1 mm (lighter)',
              onPressed: down == null ? null : () => setDown(down + 0.1),
              icon: const Icon(Icons.add_rounded)),
        ]),
        Text(
            'Lift ${v['plot_lift'] ?? '—'} mm between strokes · origin X${v['plot_ox'] ?? '—'} Y${v['plot_oy'] ?? '—'}. '
            'The new height applies at the next Pen down.',
            style: T.caption.copyWith(color: C.muted)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: () async {
              final pos = s.toolPosition;
              final at = pos.length > 1 ? ' (X${pos[0].toStringAsFixed(1)} Y${pos[1].toStringAsFixed(1)})' : '';
              if (await confirm(context, 'Set the origin here?',
                      message: 'Saves where the pen is now$at as the top-left of the writing area. '
                          'Text placed on the page was measured for the current origin, so it will land '
                          'somewhere else until the page is measured again.',
                      action: 'Set origin') &&
                  context.mounted) {
                run(context, () => client.gcode('PLOT_SET_ORIGIN'), done: 'Origin saved');
              }
            },
            icon: const Icon(Icons.my_location_rounded),
            label: const Text('Set origin'),
          ),
          _homeButton(context),
        ]),
      ]),
    );
  }
}

/// Pen G-code in the gcodes root, newest first.
class _PlotFiles extends StatefulWidget {
  final MoonrakerClient client;
  final bool canPlot;
  const _PlotFiles({super.key, required this.client, required this.canPlot});
  @override
  State<_PlotFiles> createState() => _PlotFilesState();
}

class _PlotFilesState extends State<_PlotFiles> {
  late Future<List<GcodeFile>> _files = _load();

  Future<List<GcodeFile>> _load() async {
    final (_, files) = await widget.client.directory('');
    return files.where((f) => f.name.toLowerCase().endsWith('.gcode')).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
  }

  @override
  Widget build(BuildContext context) => Panel(
        title: 'Files',
        icon: Icons.folder_rounded,
        trailing: IconButton(
            tooltip: 'Refresh', onPressed: () => setState(() => _files = _load()), icon: const Icon(Icons.refresh_rounded)),
        child: FutureBuilder<List<GcodeFile>>(
          future: _files,
          builder: (context, snap) {
            if (snap.hasError) return Text(cleanError('${snap.error}'), style: T.small.copyWith(color: C.muted));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) return Text('No files yet', style: T.small.copyWith(color: C.muted));
            return Column(children: [
              for (final f in snap.data!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(f.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${fmtBytes(f.size)} · ${fmtAgo(f.modified)}'),
                  trailing: OutlinedButton(
                    onPressed: widget.canPlot
                        ? () async {
                            if (await confirm(context, 'Plot ${f.name}?',
                                    message: 'Load the right pen and put the paper in first. '
                                        'The plotter starts moving straight away.',
                                    action: 'Plot') &&
                                context.mounted) {
                              run(context, () => widget.client.startPrint(f.path), done: 'Plotting ${f.name}');
                            }
                          }
                        : null,
                    child: const Text('Plot'),
                  ),
                ),
              if (!widget.canPlot) Hint('Home the plotter, and wait for it to be idle, to plot a file.', color: C.muted),
            ]);
          },
        ),
      );
}

// --- Write / Write on this page ----------------------------------------------

/// A photo or PDF page shown as the paper, straightened by its four corners.
class _Background {
  final Uint8List bytes;
  final Size size; // image pixels
  List<Offset> corners; // top-left, top-right, bottom-right, bottom-left (image px)
  _Background(this.bytes, this.size)
      : corners = [Offset.zero, Offset(size.width, 0), Offset(size.width, size.height), Offset(0, size.height)];
}

class PlotEditor extends StatefulWidget {
  final MoonrakerClient client;

  /// "Write on this page": a page photo behind, any number of boxes.
  final bool worksheet;
  final void Function(List<PlotStep>) onSent;

  /// For tests: a ready API instead of the home bridge.
  final PlotApi? api;
  const PlotEditor({super.key, required this.client, required this.worksheet, required this.onSent, this.api});
  @override
  State<PlotEditor> createState() => _PlotEditorState();
}

class _PlotEditorState extends State<PlotEditor> {
  late final _boxes = [PlotBox(pos: widget.worksheet ? const Offset(20, 40) : const Offset(17, 23))];
  int _sel = 0;
  final _text = TextEditingController();
  final _timers = <PlotBox, Timer>{};
  _Background? _bg;
  PlotApi? _api;
  void Function() _release = () {};
  bool _sending = false;
  String? _bgError;

  PlotBox get _box => _boxes[_sel];

  @override
  void initState() {
    super.initState();
    _api = widget.api;
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _text.dispose();
    _release();
    super.dispose();
  }

  /// [f] on the plot service; once more on a fresh link if the relay link dropped.
  Future<V> _call<V>(Future<V> Function(PlotApi) f) async {
    Future<void> connect() async {
      final (h, release) = await widget.client.bridgeClient();
      _release = release;
      _api = PlotApi(h);
    }

    if (_api == null) await connect();
    try {
      return await f(_api!);
    } on RelayError {
      if (widget.api != null) rethrow;
      _release();
      await connect();
      return f(_api!);
    }
  }

  void _changed(PlotBox b, {bool now = false}) {
    setState(() {});
    _timers[b]?.cancel();
    if (b.text.trim().isEmpty) {
      setState(() {
        b.paths = const [];
        b.size = Size.zero;
        b.error = null;
      });
      return;
    }
    _timers[b] = Timer(Duration(milliseconds: now ? 0 : 450), () => _preview(b));
  }

  Future<void> _preview(PlotBox b) async {
    setState(() => b.busy = true);
    try {
      final r = await _call((a) => a.preview(b));
      final box = (r['boxes'] as List).first as Map;
      b.paths = [
        for (final s in box['paths'] as List)
          [for (final p in s as List) Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())],
      ];
      b.size = Size((box['w'] as num).toDouble(), (box['h'] as num).toDouble());
      b.seconds = (r['seconds'] as num).toInt();
      b.error = r['error'] as String?;
    } catch (e) {
      b.error = cleanError('$e');
    }
    if (mounted) setState(() => b.busy = false);
  }

  void _select(int i) {
    setState(() => _sel = i);
    _text.text = _box.text;
  }

  // Page gestures, in mm on the paper.
  int? _hit(Offset mm) {
    for (var i = _boxes.length - 1; i >= 0; i--) {
      final b = _boxes[i];
      final r = Rect.fromLTWH(b.pos.dx, b.pos.dy, math.max(b.size.width, 20), math.max(b.size.height, 8)).inflate(3);
      if (r.contains(mm)) return i;
    }
    return null;
  }

  Offset _clamp(Offset p) => Offset(p.dx.clamp(0, kPage.width - 10), p.dy.clamp(0, kPage.height - 5));

  void _tap(Offset mm) {
    final i = _hit(mm);
    if (i != null && i != _sel) return _select(i);
    if (i == null) {
      _box.pos = _clamp(mm);
      _changed(_box, now: true); // the wrap width depends on where it starts
    }
  }

  int? _dragging;
  void _dragStart(Offset mm) {
    _dragging = _hit(mm);
    if (_dragging != null && _dragging != _sel) _select(_dragging!);
  }

  void _dragMove(Offset deltaMm) {
    if (_dragging == null) return;
    setState(() => _boxes[_dragging!].pos = _clamp(_boxes[_dragging!].pos + deltaMm));
  }

  void _dragEnd() {
    if (_dragging != null) _changed(_boxes[_dragging!], now: true);
    _dragging = null;
  }

  Future<void> _pickBackground({bool camera = false}) async {
    setState(() => _bgError = null);
    try {
      Uint8List? bytes;
      if (camera) {
        bytes = await (await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400))?.readAsBytes();
      } else {
        final picked = await FilePicker.pickFiles(
            type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png', 'heic', 'webp', 'pdf']);
        if (picked.isEmpty) return;
        final f = picked.first;
        bytes = await f.readAsBytes();
        if (f.name.toLowerCase().endsWith('.pdf')) bytes = await _pdfPage(bytes);
      }
      if (bytes == null) return;
      final img = await decodeImageFromList(bytes);
      final bg = _Background(bytes, Size(img.width.toDouble(), img.height.toDouble()));
      img.dispose();
      setState(() => _bg = bg);
      if (mounted) await _adjustCorners();
    } catch (e) {
      if (mounted) setState(() => _bgError = 'Couldn\'t open that: ${cleanError('$e')}');
    }
  }

  /// The PDF's first page as a PNG, about 150 dpi.
  static Future<Uint8List> _pdfPage(Uint8List pdf) async {
    final doc = await PdfDocument.openData(pdf);
    try {
      final page = await doc.getPage(1);
      try {
        final img = await page.render(width: page.width * 2, height: page.height * 2, format: PdfPageImageFormat.png);
        if (img == null) throw Exception('empty page');
        return img.bytes;
      } finally {
        await page.close();
      }
    } finally {
      await doc.close();
    }
  }

  Future<void> _adjustCorners() async {
    final bg = _bg;
    if (bg == null) return;
    final c = await Navigator.push<List<Offset>>(
        context, MaterialPageRoute(builder: (_) => _CornerEditor(bg: bg)));
    if (c != null) setState(() => bg.corners = c);
  }

  Future<void> _send() async {
    final boxes = _boxes.where((b) => b.text.trim().isNotEmpty).toList();
    if (boxes.isEmpty) return toast(context, 'Write some text first');
    for (final b in boxes) {
      if (b.paths.isEmpty || b.busy) await _preview(b);
      if (!mounted) return;
      if (b.error != null) {
        _select(_boxes.indexOf(b));
        return toast(context, b.error!);
      }
    }
    setState(() => _sending = true);
    try {
      final now = DateTime.now();
      final slug = boxes.first.text.trim().split(RegExp(r'\s+')).take(3).join('_');
      final base = '${slug}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final steps = <PlotStep>[];
      for (final (colour, group) in groupByColour(boxes)) {
        final r = await _call((a) => a.send('${base}_$colour', group));
        steps.add(PlotStep('${r['file']}', colour, (r['seconds'] as num).toInt()));
      }
      if (mounted) widget.onSent(steps);
    } catch (e) {
      if (mounted) toast(context, cleanError('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _PageCanvas(
      boxes: _boxes,
      selected: _sel,
      background: _bg,
      onTap: _tap,
      onDragStart: _dragStart,
      onDragMove: _dragMove,
      onDragEnd: _dragEnd,
    );
    final controls = _controls(context);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 900) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Padding(padding: const EdgeInsets.all(16), child: Center(child: page))),
          SizedBox(width: 380, child: ListView(padding: const EdgeInsets.fromLTRB(0, 16, 16, 16), children: controls)),
        ]);
      }
      return ListView(padding: const EdgeInsets.all(16), children: [
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 560), child: Center(child: page)),
        const SizedBox(height: 16),
        ...controls,
      ]);
    });
  }

  List<Widget> _controls(BuildContext context) {
    final b = _box;
    final total = _boxes.fold<int>(0, (t, b) => t + (b.text.trim().isEmpty ? 0 : b.seconds));
    final colours = {for (final b in _boxes) if (b.text.trim().isNotEmpty) b.colour};
    return [
      if (widget.worksheet)
        Panel(
          title: 'The page',
          icon: Icons.image_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android))
                OutlinedButton.icon(
                    onPressed: () => _pickBackground(camera: true),
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Take a photo')),
              OutlinedButton.icon(
                  onPressed: _pickBackground, icon: const Icon(Icons.upload_file_rounded), label: const Text('Image or PDF')),
              if (_bg != null) ...[
                OutlinedButton.icon(
                    onPressed: _adjustCorners, icon: const Icon(Icons.crop_free_rounded), label: const Text('Corners')),
                TextButton(onPressed: () => setState(() => _bg = null), child: const Text('Remove')),
              ],
            ]),
            if (_bgError != null) ...[const SizedBox(height: 8), Hint(_bgError!, color: C.danger)],
            const SizedBox(height: 8),
            Text('The photo is only a guide on screen; the plotter writes the text.',
                style: T.caption.copyWith(color: C.muted)),
          ]),
        ),
      if (widget.worksheet) const SizedBox(height: 12),
      Panel(
        title: widget.worksheet ? 'Text box ${_sel + 1} of ${_boxes.length}' : 'Text',
        icon: Icons.edit_rounded,
        trailing: widget.worksheet
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                if (_boxes.length > 1)
                  IconButton(
                      tooltip: 'Delete this box',
                      onPressed: () {
                        _timers.remove(b)?.cancel();
                        setState(() => _boxes.removeAt(_sel));
                        _select(math.min(_sel, _boxes.length - 1));
                      },
                      icon: const Icon(Icons.delete_outline_rounded)),
                IconButton(
                    tooltip: 'Add a text box',
                    onPressed: () {
                      final last = _boxes.last;
                      _boxes.add(PlotBox(
                          style: last.style,
                          em: last.em,
                          colour: last.colour,
                          mistakes: last.mistakes,
                          pos: _clamp(last.pos + Offset(0, math.max(last.size.height, 10) + 10))));
                      _select(_boxes.length - 1);
                    },
                    icon: const Icon(Icons.add_rounded)),
              ])
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(hintText: 'What should it write?'),
            onChanged: (v) {
              b.text = v;
              _changed(b);
            },
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in plotStyles.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: b.style == e.key,
                onSelected: (_) {
                  b.style = e.key;
                  _changed(b, now: true);
                },
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Text('Size', style: T.small),
            Expanded(
              child: Slider(
                value: b.em,
                min: 3,
                max: 20,
                divisions: 34,
                label: '${b.em.toStringAsFixed(1)} mm',
                onChanged: (v) => setState(() => b.em = v),
                onChangeEnd: (_) => _changed(b, now: true),
              ),
            ),
            SizedBox(width: 56, child: Text('${b.em.toStringAsFixed(1)} mm', style: T.small)),
          ]),
          if (b.style == 'hand')
            Row(children: [
              Expanded(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Messy mistakes'),
                  subtitle: const Text('Now and then a wrong letter, scribbled out'),
                  value: b.mistakes,
                  onChanged: (v) {
                    b.mistakes = v;
                    _changed(b, now: true);
                  },
                ),
              ),
              IconButton(
                tooltip: 'Write it differently',
                onPressed: () {
                  b.seed = math.Random().nextInt(1 << 30);
                  _changed(b, now: true);
                },
                icon: const Icon(Icons.shuffle_rounded),
              ),
            ]),
          const SizedBox(height: 8),
          Text('Pen colour', style: T.small),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final e in plotColours.entries)
              Tooltip(
                message: e.key,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => b.colour = e.key),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: e.value,
                      shape: BoxShape.circle,
                      border: Border.all(color: b.colour == e.key ? C.text : Colors.transparent, width: 3),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          if (b.error != null)
            Hint(b.error!, color: C.danger)
          else
            Text(
                b.busy
                    ? 'Updating the preview…'
                    : widget.worksheet
                        ? 'Tap a box to pick it, drag to move it. Tap empty paper to move the picked box there.'
                        : 'Tap or drag on the page to place the text.',
                style: T.caption.copyWith(color: C.muted)),
        ]),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _sending ? null : _send,
        icon: _sending
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_rounded),
        label: Text(colours.length > 1 ? 'Send to the plotter (${colours.length} pens)' : 'Send to the plotter'),
      ),
      const SizedBox(height: 6),
      Text(
          '${total > 0 ? 'About ${fmtDuration(total)} of plotting. ' : ''}'
          'Sending only uploads it; you start it on the Plot tab${colours.length > 1 ? ', one pen at a time' : ''}.',
          style: T.caption.copyWith(color: C.muted)),
    ];
  }
}

/// The A4 sheet with the background and every box's preview, in mm.
class _PageCanvas extends StatelessWidget {
  final List<PlotBox> boxes;
  final int selected;
  final _Background? background;
  final void Function(Offset mm) onTap, onDragStart, onDragMove;
  final VoidCallback onDragEnd;
  const _PageCanvas({
    required this.boxes,
    required this.selected,
    required this.background,
    required this.onTap,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: kPage.width / kPage.height,
        child: LayoutBuilder(builder: (context, c) {
          final k = c.maxWidth / kPage.width; // px per mm
          final bg = background;
          return Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: C.border)),
            clipBehavior: Clip.hardEdge,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => onTap(d.localPosition / k),
              onPanStart: (d) => onDragStart(d.localPosition / k),
              onPanUpdate: (d) => onDragMove(d.delta / k),
              onPanEnd: (_) => onDragEnd(),
              child: Stack(children: [
                if (bg != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    width: bg.size.width,
                    height: bg.size.height,
                    child: Transform(
                      transform: homography(bg.corners,
                          [Offset.zero, Offset(c.maxWidth, 0), Offset(c.maxWidth, c.maxHeight), Offset(0, c.maxHeight)]),
                      child: Image.memory(bg.bytes, fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                  ),
                Positioned.fill(child: CustomPaint(painter: _BoxesPainter(boxes, selected, k))),
              ]),
            ),
          );
        }),
      );
}

class _BoxesPainter extends CustomPainter {
  final List<PlotBox> boxes;
  final int selected;
  final double k;
  _BoxesPainter(this.boxes, this.selected, this.k);

  @override
  void paint(Canvas canvas, Size size) {
    for (final (i, b) in boxes.indexed) {
      final pen = Paint()
        ..color = plotColours[b.colour] ?? Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, 0.45 * k)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final s in b.paths) {
        if (s.isEmpty) continue;
        final path = Path()..moveTo((b.pos.dx + s[0].dx) * k, (b.pos.dy + s[0].dy) * k);
        for (final p in s.skip(1)) {
          path.lineTo((b.pos.dx + p.dx) * k, (b.pos.dy + p.dy) * k);
        }
        canvas.drawPath(path, pen);
      }
      final r = Rect.fromLTWH(b.pos.dx * k, b.pos.dy * k, math.max(b.size.width, 20) * k, math.max(b.size.height, 8) * k)
          .inflate(2 * k);
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = i == selected ? 1.5 : 1
            ..color = b.error != null
                ? const Color(0xFFD32F2F)
                : (i == selected ? const Color(0xFF2962FF) : const Color(0x552962FF)));
    }
  }

  @override
  bool shouldRepaint(_BoxesPainter old) => true;
}

/// Drag the four handles onto the paper's corners in the photo.
class _CornerEditor extends StatefulWidget {
  final _Background bg;
  const _CornerEditor({required this.bg});
  @override
  State<_CornerEditor> createState() => _CornerEditorState();
}

class _CornerEditorState extends State<_CornerEditor> {
  late final _c = [...widget.bg.corners];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Page corners'),
          actions: [
            TextButton(
                onPressed: () => setState(() {
                      final s = widget.bg.size;
                      _c.setAll(0, [Offset.zero, Offset(s.width, 0), Offset(s.width, s.height), Offset(0, s.height)]);
                    }),
                child: const Text('Reset')),
            FilledButton(onPressed: () => Navigator.pop(context, _c), child: const Text('Done')),
            const SizedBox(width: 12),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: LayoutBuilder(builder: (context, box) {
            final s = widget.bg.size;
            final k = math.min(box.maxWidth / s.width, box.maxHeight / s.height);
            final o = Offset((box.maxWidth - s.width * k) / 2, (box.maxHeight - s.height * k) / 2);
            return Stack(children: [
              Positioned(
                  left: o.dx,
                  top: o.dy,
                  width: s.width * k,
                  height: s.height * k,
                  child: Image.memory(widget.bg.bytes, fit: BoxFit.fill)),
              Positioned.fill(child: CustomPaint(painter: _QuadPainter([for (final p in _c) o + p * k]))),
              for (final (i, p) in _c.indexed)
                Positioned(
                  left: o.dx + p.dx * k - 22,
                  top: o.dy + p.dy * k - 22,
                  child: GestureDetector(
                    onPanUpdate: (d) => setState(() {
                      final n = _c[i] + d.delta / k;
                      _c[i] = Offset(n.dx.clamp(0, s.width), n.dy.clamp(0, s.height));
                    }),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: C.accent.withValues(alpha: 0.25),
                        border: Border.all(color: C.accent, width: 2),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Text('Drag each circle onto a corner of the sheet: top-left, top-right, bottom-right, bottom-left.',
                    textAlign: TextAlign.center, style: T.small.copyWith(color: C.muted)),
              ),
            ]);
          }),
        ),
      );
}

class _QuadPainter extends CustomPainter {
  final List<Offset> p;
  _QuadPainter(this.p);
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
      Path()..addPolygon(p, true),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF2962FF));
  @override
  bool shouldRepaint(_QuadPainter old) => true;
}
