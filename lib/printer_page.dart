import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'camera.dart';
import 'charts.dart';
import 'console_page.dart';
import 'control_page.dart';
import 'files_page.dart';
import 'history_page.dart';
import 'moonraker.dart';
import 'screen_page.dart';
import 'settings.dart';
import 'tools_page.dart';
import 'u1_panels.dart';
import 'ui.dart';

/// One printer: five tabs, bottom bar on phones, side rail on wide screens.
class PrinterPage extends StatefulWidget {
  final Printer printer;
  const PrinterPage({super.key, required this.printer});
  @override
  State<PrinterPage> createState() => _PrinterPageState();
}

class _PrinterPageState extends State<PrinterPage> {
  int _tab = 0;
  late final MoonrakerClient _client = clientFor(widget.printer);

  static const _dest = [
    (Icons.dashboard_outlined, Icons.dashboard_rounded, 'Overview'),
    (Icons.open_with_outlined, Icons.open_with_rounded, 'Control'),
    (Icons.folder_outlined, Icons.folder_rounded, 'Files'),
    (Icons.handyman_outlined, Icons.handyman_rounded, 'Tools'),
    (Icons.history, Icons.history, 'History'),
  ];

  void _go(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final body = IndexedStack(index: _tab, children: [
      OverviewTab(
          printer: widget.printer, client: _client, onBrowseFiles: () => _go(2)),
      ControlTab(client: _client, printer: widget.printer),
      FilesTab(client: _client, printer: widget.printer),
      ToolsTab(client: _client, printer: widget.printer),
      HistoryTab(client: _client),
    ]);
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 1000;
      return Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.printer.name,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(widget.printer.host,
                style: TextStyle(fontSize: 12, color: C.muted)),
          ]),
          actions: [
            IconButton(
              tooltip: 'Console',
              icon: const Icon(Icons.terminal),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ConsolePage(client: _client)),
              ),
            ),
            const SizedBox(width: 4),
            StreamBuilder<PrinterStatus>(
              stream: _client.stream,
              initialData: _client.status,
              builder: (_, s) => Row(mainAxisSize: MainAxisSize.min, children: [
                if (_client.hasScreen)
                  IconButton(
                    tooltip: 'Printer screen',
                    icon: const Icon(Icons.touch_app_rounded),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ScreenPage(client: _client)),
                    ),
                  ),
                if (_client.viaRelay && s.data!.online)
                  Tooltip(
                    message: 'Connected from away, through your home bridge'
                        '${_client.relayDelay == null ? '' : ' · ${_client.relayDelay!.inMilliseconds} ms'}',
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.public_rounded, color: C.accent, size: 20),
                    ),
                  ),
                StatusPill(state: s.data!.state, online: s.data!.online),
              ]),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: wide
            ? Row(children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: _go,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in _dest)
                      NavigationRailDestination(
                        icon: Icon(d.$1),
                        selectedIcon: Icon(d.$2),
                        label: Text(d.$3),
                      ),
                  ],
                ),
                VerticalDivider(width: 1, color: C.border),
                Expanded(child: body),
              ])
            : body,
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: _go,
                destinations: [
                  for (final d in _dest)
                    NavigationDestination(
                      icon: Icon(d.$1),
                      selectedIcon: Icon(d.$2),
                      label: d.$3,
                    ),
                ],
              ),
      );
    });
  }
}

class OverviewTab extends StatefulWidget {
  final Printer printer;
  final MoonrakerClient client;
  final VoidCallback onBrowseFiles;
  const OverviewTab({
    super.key,
    required this.printer,
    required this.client,
    required this.onBrowseFiles,
  });

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  final _cam = GlobalKey<PrinterCameraState>();
  MoonrakerClient get c => widget.client;

  Future<void> _fullscreen() async {
    // One video session at a time: the K2's camera may refuse a second.
    await _cam.currentState?.stop();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CameraFullscreen(
            client: c,
            cameraUrl: widget.printer.cameraUrl,
            title: widget.printer.name),
      ),
    );
    _cam.currentState?.restart();
  }

  Future<void> _snapshot() async {
    final cam = _cam.currentState;
    final bytes = await cam?.snapshot();
    if (!mounted) return;
    if (cam == null || bytes == null) {
      return toast(context, 'No camera image yet', error: true);
    }
    final now = DateTime.now();
    final safe = widget.printer.name.replaceAll(RegExp(r'[^\w-]+'), '_');
    final stamp = fmtClock(now).replaceAll(':', '');
    try {
      final saved = await FilePicker.saveFile(
        fileName: '$safe-${fmtDate(now)}-$stamp.${cam.snapshotExtension}',
        bytes: bytes,
      );
      if (saved != null && mounted) toast(context, 'Snapshot saved');
    } catch (e) {
      if (mounted) toast(context, 'Could not save the snapshot: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Built outside the status stream so the video never restarts.
    final camera = Stack(children: [
      PrinterCamera(key: _cam, client: c, cameraUrl: widget.printer.cameraUrl),
      Positioned.fill(
        child: StreamBuilder<PrinterStatus>(
          stream: c.stream,
          initialData: c.status,
          builder: (context, snap) => _CameraOverlay(
            s: snap.data!,
            onFullscreen: _fullscreen,
            onSnapshot: _snapshot,
            onLight: (on) => run(context, () => c.setLed(on)),
            onAdjust: () => _cam.currentState?.adjust(context),
          ),
        ),
      ),
    ]);
    final chart = _TempHistory(client: c);
    return StreamBuilder<PrinterStatus>(
      stream: c.stream,
      initialData: c.status,
      builder: (context, snap) {
        final s = snap.data!;
        final job = _JobPanel(
            s: s, client: c, onBrowseFiles: widget.onBrowseFiles);
        final temps = _Temps(s: s, client: c);
        final cfs = Column(children: [
          _CfsPanel(boxes: s.cfs, client: c),
          if (s.dragon != null) HeaterPanel(s: s, client: c),
        ]);
        final actions = _Actions(s: s, client: c, printer: widget.printer);
        const gap = SizedBox(height: 16, width: 16);
        return LayoutBuilder(builder: (context, box) {
          if (box.maxWidth >= 860) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(children: [camera, gap, job, gap, chart]),
                  ),
                  gap,
                  Expanded(
                    flex: 2,
                    child: Column(children: [temps, gap, cfs, actions]),
                  ),
                ],
              ),
            );
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            camera,
            gap,
            job,
            gap,
            temps,
            gap,
            chart,
            gap,
            cfs,
            actions,
          ]);
        });
      },
    );
  }
}

class _CameraOverlay extends StatelessWidget {
  final PrinterStatus s;
  final VoidCallback onFullscreen, onSnapshot;
  final ValueChanged<bool> onLight;
  final VoidCallback onAdjust;
  const _CameraOverlay({
    required this.s,
    required this.onFullscreen,
    required this.onSnapshot,
    required this.onLight,
    required this.onAdjust,
  });

  @override
  Widget build(BuildContext context) {
    final active = s.state == 'printing' || s.state == 'paused';
    final eta = s.eta;
    return Stack(children: [
      Positioned(
          top: 10, left: 10, child: StatusPill(state: s.state, online: s.online)),
      Positioned(
        top: 6,
        right: 6,
        child: Row(children: [
          if (s.led != null)
            OverlayButton(
              icon: s.led! ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
              tooltip: s.led! ? 'Light off' : 'Light on',
              active: s.led!,
              onPressed: () => onLight(!s.led!),
            ),
          OverlayButton(
              icon: Icons.screen_rotation_alt_rounded,
              tooltip: 'Rotate or mirror',
              onPressed: onAdjust),
          OverlayButton(
              icon: Icons.photo_camera_rounded,
              tooltip: 'Save snapshot',
              onPressed: onSnapshot),
          OverlayButton(
              icon: Icons.fullscreen_rounded,
              tooltip: 'Fullscreen',
              onPressed: onFullscreen),
        ]),
      ),
      if (active)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 32, 14, 12),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xC0000000)],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(s.filename ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                    Text('${(s.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: s.progress,
                      minHeight: 5,
                      backgroundColor: Colors.white24,
                      color: s.state == 'paused' ? C.warn : C.accent,
                    ),
                  ),
                  if (eta != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${fmtDuration(eta)} left · done '
                      '${fmtTime(DateTime.now().add(Duration(seconds: eta.round())))}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
    ]);
  }
}

class _JobPanel extends StatelessWidget {
  final PrinterStatus s;
  final MoonrakerClient client;
  final VoidCallback onBrowseFiles;
  const _JobPanel(
      {required this.s, required this.client, required this.onBrowseFiles});

  void _objects(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ObjectsSheet(client: client),
      );

  @override
  Widget build(BuildContext context) {
    final active = s.state == 'printing' || s.state == 'paused';
    final scheduled = client.scheduled;
    final banner = scheduled == null
        ? const SizedBox.shrink()
        : Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: C.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.schedule_rounded, color: C.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${scheduled.$1.split('/').last} starts at ${fmtTime(scheduled.$2)}'
                  ' (keep the app open)',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                  onPressed: client.cancelScheduled, child: const Text('Cancel')),
            ]),
          );

    if (s.filename == null || !(active || s.state == 'complete')) {
      return Panel(
        title: 'Job',
        icon: Icons.layers_outlined,
        child: Column(children: [
          banner,
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (s.online ? C.accent : C.muted).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                s.online ? Icons.check_circle_rounded : Icons.wifi_off_rounded,
                color: s.online ? C.accent : C.muted,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.online ? 'Ready to print' : 'Connecting to printer…',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text(
                  s.online
                      ? (s.message ?? 'Pick a file to start a print')
                      : (client.linkError ??
                          'Check the printer is on and on the same network'),
                  style: TextStyle(color: C.muted, fontSize: 13),
                ),
              ]),
            ),
            if (s.online)
              FilledButton.tonalIcon(
                onPressed: onBrowseFiles,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Files'),
              ),
          ]),
        ]),
      );
    }
    final layers = s.currentLayer != null && (s.totalLayers ?? 0) > 0
        ? '${s.currentLayer} / ${s.totalLayers}'
        : '—';
    final eta = s.eta;
    final objects = s.objects;
    return Panel(
      title: s.state == 'complete' ? 'Last job' : 'Printing',
      icon: Icons.layers_outlined,
      trailing: active && objects.isNotEmpty
          ? TextButton.icon(
              onPressed: () => _objects(context),
              icon: const Icon(Icons.layers_clear_rounded, size: 18),
              label: Text(
                  'Objects ${objects.length - s.excludedObjects.length}/${objects.length}'),
            )
          : null,
      child: Column(children: [
        banner,
        Row(children: [
          ProgressRing(
            value: s.progress,
            color: s.state == 'paused' ? C.warn : null,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.filename!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Wrap(spacing: 24, runSpacing: 12, children: [
                StatTile(label: 'Elapsed', value: fmtDuration(s.printDuration)),
                StatTile(label: 'Remaining', value: fmtDuration(eta)),
                StatTile(
                  label: 'Done at',
                  value: eta == null
                      ? '—'
                      : fmtTime(DateTime.now().add(Duration(seconds: eta.round()))),
                ),
                StatTile(label: 'Layer', value: layers),
                StatTile(label: 'Filament', value: fmtFilament(s.filamentUsed)),
              ]),
            ]),
          ),
        ]),
      ]),
    );
  }
}

class _ObjectsSheet extends StatelessWidget {
  final MoonrakerClient client;
  const _ObjectsSheet({required this.client});

  Future<void> _skip(BuildContext context, PrintObject o) async {
    if (await confirm(context, 'Skip ${o.name}?',
            message:
                'The printer stops printing this object for the rest of the job. This cannot be undone.',
            action: 'Skip object',
            danger: true) &&
        context.mounted) {
      run(context, () => client.excludeObject(o.name), done: 'Skipped ${o.name}');
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<PrinterStatus>(
        stream: client.stream,
        initialData: client.status,
        builder: (context, snap) {
          final s = snap.data!;
          final bed = s.axisMax;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Objects on the plate',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Tap an object to stop printing it (for example a part that came loose).',
                    style: TextStyle(color: C.muted)),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ObjectMap(
                    objects: s.objects,
                    excluded: s.excludedObjects,
                    current: s.currentObject,
                    bedW: bed[0],
                    bedH: bed[1],
                    onTap: (o) => _skip(context, o),
                  ),
                ),
                const SizedBox(height: 12),
                for (final o in s.objects)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      s.excludedObjects.contains(o.name)
                          ? Icons.block_rounded
                          : o.name == s.currentObject
                              ? Icons.print_rounded
                              : Icons.check_box_outline_blank_rounded,
                      color: s.excludedObjects.contains(o.name) ? C.muted : C.accent,
                    ),
                    title: Text(o.name, overflow: TextOverflow.ellipsis),
                    trailing: s.excludedObjects.contains(o.name)
                        ? Text('Skipped', style: TextStyle(color: C.muted))
                        : TextButton(
                            onPressed: () => _skip(context, o),
                            child: const Text('Skip')),
                  ),
              ]),
            ),
          );
        },
      );
}

class _Temps extends StatelessWidget {
  final PrinterStatus s;
  final MoonrakerClient client;
  const _Temps({required this.s, required this.client});

  Future<void> _set(BuildContext context, String label, String presetKey,
      Future<void> Function(int) setter) async {
    final v = await askNumber(context, 'Set $label temperature',
        presets: settings.presets(presetKey));
    if (v != null && context.mounted) await run(context, () => setter(v));
  }

  @override
  Widget build(BuildContext context) {
    final tools = s.extruders.isEmpty ? ['extruder'] : s.extruders;
    final gauges = <Widget>[
      for (var i = 0; i < tools.length; i++)
        TempGauge(
          label: tools.length == 1 ? 'Nozzle' : 'T$i',
          icon: Icons.local_fire_department_rounded,
          temp: s.toolTemp(tools[i]),
          target: s.toolTarget(tools[i]),
          max: 320,
          color: C.tools[i % C.tools.length],
          onTap: () => _set(context, tools.length == 1 ? 'nozzle' : 'T$i',
              'nozzle', (t) => client.setToolTemp(tools[i], t)),
        ),
      TempGauge(
        label: 'Bed',
        icon: Icons.grid_view_rounded,
        temp: s.bed,
        target: s.bedTarget,
        max: 120,
        color: C.bed,
        onTap: () => _set(context, 'bed', 'bed', client.setBed),
      ),
      if (s.hasChamber)
        TempGauge(
          label: 'Chamber',
          icon: Icons.thermostat_rounded,
          temp: s.chamber,
          target: s.chamberTarget,
          max: 70,
          color: C.chamber,
          onTap: s.chamberHeatable
              ? () => _set(context, 'chamber', 'chamber', client.setChamber)
              : null,
        ),
    ];
    return LayoutBuilder(builder: (context, c) {
      const gap = 12.0;
      final cols = gauges.length <= 3
          ? gauges.length
          : (c.maxWidth / 130).floor().clamp(2, gauges.length);
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final g in gauges) SizedBox(width: w, child: g),
      ]);
    });
  }
}

/// Last 10 minutes of temperatures: Moonraker's store, then live samples.
class _TempHistory extends StatefulWidget {
  final MoonrakerClient client;
  const _TempHistory({required this.client});
  @override
  State<_TempHistory> createState() => _TempHistoryState();
}

class _TempHistoryState extends State<_TempHistory> {
  static const _window = 600;
  final _data = <String, List<double>>{};
  bool _loaded = false;
  Timer? _timer;

  PrinterStatus get s => widget.client.status;

  String get _chamberKey => s.chamberHeatable
      ? s.chamberHeater
      : s.chamberSensor;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = await widget.client.temperatureStore();
      for (final e in store.entries) {
        final v = e.value;
        _data[e.key] = v.length > _window ? v.sublist(v.length - _window) : v;
      }
    } catch (_) {
      // Older Moonraker or no store: the chart just starts empty and fills.
    }
    if (mounted) setState(() => _loaded = true);
  }

  void _add(String key, double v) {
    final l = _data.putIfAbsent(key, () => []);
    l.add(v);
    if (l.length > _window) l.removeAt(0);
  }

  void _tick() {
    if (!_loaded || !s.online) return;
    _add('extruder', s.hotend);
    _add('extruder#target', s.hotendTarget);
    _add('heater_bed', s.bed);
    _add('heater_bed#target', s.bedTarget);
    if (s.hasChamber) {
      _add(_chamberKey, s.chamber);
      _add('$_chamberKey#target', s.chamberTarget);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    Series series(String label, Color color, String key) =>
        Series(label, color, _data[key] ?? const [], _data['$key#target']);
    return Panel(
      title: 'Temperatures · last 10 min',
      icon: Icons.show_chart_rounded,
      child: !_loaded
          ? const SizedBox(
              height: 170, child: Center(child: CircularProgressIndicator()))
          : TempChart(series: [
              series('Nozzle', C.hot, 'extruder'),
              series('Bed', C.bed, 'heater_bed'),
              if (s.hasChamber) series('Chamber', C.chamber, _chamberKey),
            ]),
    );
  }
}

class _CfsPanel extends StatelessWidget {
  final List<CfsBox> boxes;
  final MoonrakerClient client;
  const _CfsPanel({required this.boxes, required this.client});

  @override
  Widget build(BuildContext context) {
    if (boxes.isEmpty) return const SizedBox.shrink();
    final limit = settings.number('humidityLimit', 45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Panel(
        title: 'Filament system',
        icon: Icons.palette_outlined,
        child: Column(children: [
          for (final b in boxes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(
                  width: 54,
                  child: Text(b.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                for (final slot in b.slots)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: slot.lane == null
                        ? _SlotDot(slot: slot)
                        : InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => editLane(context, client, slot),
                            child: _SlotDot(slot: slot),
                          ),
                  ),
                const Spacer(),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (b.temperature != null)
                    Text('${b.temperature!.toStringAsFixed(0)}°C',
                        style: TextStyle(fontSize: 12, color: C.muted)),
                  if (b.humidity != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (b.humidity! >= limit)
                        const Icon(Icons.water_drop_rounded,
                            size: 13, color: C.warn),
                      Text('${b.humidity!.toStringAsFixed(0)}% RH',
                          style: TextStyle(
                              fontSize: 12,
                              color: b.humidity! >= limit ? C.warn : C.muted,
                              fontWeight: b.humidity! >= limit
                                  ? FontWeight.w700
                                  : null)),
                    ]),
                ]),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _SlotDot extends StatelessWidget {
  final CfsSlot slot;
  const _SlotDot({required this.slot});

  @override
  Widget build(BuildContext context) {
    final tip = slot.empty
        ? 'Slot ${slot.label} · empty'
        : 'Slot ${slot.label}${slot.remain == null ? '' : ' · ${slot.remain!.toStringAsFixed(0)} left'}';
    return Tooltip(
      message: tip,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: slot.empty ? Colors.transparent : Color(slot.color!),
            border: Border.all(
                color: slot.empty ? C.border : C.text.withValues(alpha: 0.2),
                width: 2),
          ),
          child: slot.empty
              ? Icon(Icons.close_rounded, size: 14, color: C.muted)
              : null,
        ),
        const SizedBox(height: 4),
        Text(slot.label, style: TextStyle(fontSize: 11, color: C.muted)),
      ]),
    );
  }
}

class _Actions extends StatelessWidget {
  final PrinterStatus s;
  final MoonrakerClient client;
  final Printer printer;
  const _Actions({required this.s, required this.client, required this.printer});

  @override
  Widget build(BuildContext context) {
    final printing = s.state == 'printing', paused = s.state == 'paused';
    final busy = printing || paused;
    final favs = settings.favourites('macros.${printer.key}').toList()..sort();
    return Panel(
      title: 'Quick actions',
      icon: Icons.bolt_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          if (busy && client.canPauseAtLayer)
            OutlinedButton.icon(
              onPressed: () async {
                final now = s.currentLayer ?? 0;
                final l = await askNumber(context, 'Pause at layer',
                    presets: [0, now + 1, now + 5, now + 10], unit: '');
                if (l == null || !context.mounted) return;
                await run(context, () => client.pauseAtLayer(l == 0 ? null : l),
                    done: l == 0 ? 'Layer pause off' : 'Pauses at layer $l');
              },
              icon: const Icon(Icons.layers_clear_outlined),
              label: const Text('Pause at layer'),
            ),
          if (printing)
            FilledButton.icon(
              onPressed: () => run(context, client.pause),
              icon: const Icon(Icons.pause_rounded),
              label: const Text('Pause'),
            ),
          if (paused)
            FilledButton.icon(
              onPressed: () => run(context, client.resume),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume'),
            ),
          if (busy)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: C.danger),
              onPressed: () async {
                if (await confirm(context, 'Cancel this print?',
                        message: 'This cannot be undone.',
                        action: 'Cancel print',
                        danger: true) &&
                    context.mounted) {
                  run(context, client.cancel);
                }
              },
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Cancel'),
            ),
          OutlinedButton.icon(
            onPressed:
                busy ? null : () => run(context, client.home, done: 'Homed'),
            icon: const Icon(Icons.home_rounded),
            label: const Text('Home all'),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => run(context, () => client.gcode('M84'),
                    done: 'Motors disabled'),
            icon: const Icon(Icons.power_settings_new_rounded),
            label: const Text('Motors off'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: C.danger, foregroundColor: Colors.white),
            onPressed: () async {
              if (await confirm(context, 'Emergency stop?',
                      message:
                          'Klipper halts immediately and needs a firmware restart.',
                      action: 'E-STOP',
                      danger: true) &&
                  context.mounted) {
                run(context, client.emergencyStop);
              }
            },
            icon: const Icon(Icons.emergency),
            label: const Text('E-STOP'),
          ),
        ]),
        if (favs.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('Favourite macros', style: TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in favs)
              ActionChip(
                avatar: const Icon(Icons.star_rounded, size: 16, color: C.warn),
                label: Text(m),
                onPressed: () async {
                  if (await confirm(context, 'Run $m?', action: 'Run') &&
                      context.mounted) {
                    run(context, () => client.gcode(m), done: '$m finished');
                  }
                },
              ),
          ]),
        ],
      ]),
    );
  }
}
