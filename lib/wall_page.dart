import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'camera.dart';
import 'moonraker.dart';
import 'printer_page.dart';
import 'settings.dart';
import 'ui.dart';

/// Every printer's camera and status on one screen, for a spare tablet or
/// monitor. Keeps the screen awake while open (toggle in the app bar).
class WallPage extends StatefulWidget {
  final List<Printer> printers;
  const WallPage({super.key, required this.printers});
  @override
  State<WallPage> createState() => _WallPageState();
}

/// Problems first (offline, error, paused), then printing, then idle.
int wallRank(PrinterStatus s) => !s.online || s.state == 'error' || s.state == 'paused'
    ? 0
    : s.state == 'printing'
        ? 1
        : 2;

class _WallPageState extends State<WallPage> {
  bool get _awake => settings.flag('wallAwake');
  bool get _sorted => settings.flag('wallSort', false);
  Timer? _resort;

  @override
  void initState() {
    super.initState();
    if (_awake) WakelockPlus.enable();
    // One big printer at a time, next every 15 s (for a TV or a spare tablet).
    _cycleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_cycle && mounted) setState(() => _at++);
    });
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    // ponytail: re-sort every 10 s rather than listening to every printer.
    _resort = Timer.periodic(const Duration(seconds: 10), (_) {
      if ((_sorted || _busyOnly) && mounted) setState(() {});
    });
  }

  bool _onTop = false;

  @override
  void dispose() {
    if (_onTop) keepOnTop(false);
    _cycleTimer?.cancel();
    _clock?.cancel();
    _resort?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  bool get _busyOnly => settings.flag('wallBusyOnly', false);
  bool get _cycle => settings.flag('wallCycle', false);
  int _at = 0; // which printer the cycle shows
  Timer? _cycleTimer, _clock;
  int get _cols => settings.number('wallCols', 0).round(); // 0 = fit the screen

  List<Printer> get _order {
    final list = [
      for (final p in widget.printers)
        if (!_busyOnly || const {'printing', 'paused', 'error'}.contains(clientFor(p).status.state)) p,
    ];
    if (_sorted) {
      // List.sort isn't stable; keep the saved order within a rank.
      final idx = {for (final (i, p) in list.indexed) p: i};
      list.sort((a, b) {
        final r = wallRank(clientFor(a).status).compareTo(wallRank(clientFor(b).status));
        return r != 0 ? r : idx[a]!.compareTo(idx[b]!);
      });
    }
    return list;
  }

  void _toggleAwake() {
    settings.setFlag('wallAwake', !_awake);
    _awake ? WakelockPlus.enable() : WakelockPlus.disable();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Wall · ${fmtTime(DateTime.now())}'),
        actions: [
          IconButton(
            tooltip: _sorted ? 'Sorted: problems first' : 'Saved order',
            isSelected: _sorted,
            icon: const Icon(Icons.sort_rounded),
            selectedIcon: Icon(Icons.sort_rounded, color: C.accent),
            onPressed: () => setState(() => settings.setFlag('wallSort', !_sorted)),
          ),
          if (Platform.isMacOS)
            IconButton(
              tooltip: _onTop ? 'Stop keeping on top' : 'Keep on top of other apps',
              icon: Icon(_onTop ? Icons.push_pin_rounded : Icons.push_pin_outlined),
              onPressed: () {
                setState(() => _onTop = !_onTop);
                keepOnTop(_onTop);
              },
            ),
          IconButton(
            tooltip: _busyOnly ? 'Showing busy printers only' : 'Showing every printer',
            isSelected: _busyOnly,
            icon: const Icon(Icons.filter_alt_outlined),
            selectedIcon: Icon(Icons.filter_alt_rounded, color: C.accent),
            onPressed: () => setState(() => settings.setFlag('wallBusyOnly', !_busyOnly)),
          ),
          IconButton(
            tooltip: _cycle ? 'Cycling: one printer at a time' : 'Show one printer at a time, in turn',
            isSelected: _cycle,
            icon: const Icon(Icons.slideshow_outlined),
            selectedIcon: Icon(Icons.slideshow_rounded, color: C.accent),
            onPressed: () => setState(() => settings.setFlag('wallCycle', !_cycle)),
          ),
          PopupMenuButton<int>(
            tooltip: 'Columns',
            icon: const Icon(Icons.view_column_outlined),
            initialValue: _cols,
            onSelected: (v) => setState(() => settings.setNumber('wallCols', v.toDouble())),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 0, child: Text('Fit the screen')),
              for (final n in const [1, 2, 3, 4]) PopupMenuItem(value: n, child: Text('$n column${n == 1 ? '' : 's'}')),
            ],
          ),
          IconButton(
            tooltip: _awake ? 'Screen stays on' : 'Screen may sleep',
            isSelected: _awake,
            icon: const Icon(Icons.light_mode_outlined),
            selectedIcon: Icon(Icons.light_mode_rounded, color: C.warn),
            onPressed: _toggleAwake,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final cols = _cols > 0 ? _cols : (c.maxWidth / 520).floor().clamp(1, 4);
        final order = _order;
        if (order.isEmpty) return const StateView.empty(Icons.filter_alt_off_outlined, 'No printer is busy right now.');
        if (_cycle) {
          final p = order[_at % order.length];
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: AspectRatio(aspectRatio: 16 / 12.5, child: _WallTile(key: ValueKey('cycle ${p.key}'), printer: p)),
            ),
          );
        }
        return GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: cols,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 16 / 12.5,
          children: [
            for (final p in order) _WallTile(key: ValueKey(p.key), printer: p),
          ],
        );
      }),
    );
  }
}

class _WallTile extends StatelessWidget {
  final Printer printer;
  const _WallTile({super.key, required this.printer});

  @override
  Widget build(BuildContext context) {
    final client = clientFor(printer);
    return GestureDetector(
      onDoubleTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PrinterPage(printer: printer))),
      child: Panel(
      padding: const EdgeInsets.all(8),
      child: Column(children: [
        PrinterCamera(client: client, cameraUrl: printer.cameraUrl),
        const SizedBox(height: 8),
        StreamBuilder<PrinterStatus>(
          stream: client.stream,
          initialData: client.status,
          builder: (context, snap) {
            final s = snap.data!;
            final active = s.state == 'printing' || s.state == 'paused';
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: Text(printer.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                  StatusPill(state: s.state, online: s.online),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Icons.local_fire_department_rounded, size: 15, color: C.hot),
                  Text(' ${Units.deg(s.hotend)}  '),
                  Icon(Icons.grid_view_rounded, size: 15, color: C.bed),
                  Text(' ${Units.deg(s.bed)}'),
                  if (s.led != null)
                    IconButton(
                      tooltip: s.led! ? 'Light off' : 'Light on',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(s.led! ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                          size: 18, color: s.led! ? C.warn : C.muted),
                      onPressed: () => run(context, () => client.setLed(!s.led!)),
                    ),
                  const Spacer(),
                  if (active)
                    Text(
                      '${(s.progress * 100).toStringAsFixed(0)}% · ${fmtDuration(s.eta)} left'
                      '${s.eta == null ? '' : ' · done ${fmtTime(DateTime.now().add(Duration(seconds: s.eta!.round())))}'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                ]),
                if (active) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text((s.filename ?? '').split('/').last,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.muted)),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: s.progress,
                      minHeight: 6,
                      backgroundColor: C.surfaceHi,
                      color: s.state == 'paused' ? C.warn : C.accent,
                    ),
                  ),
                ],
              ]),
            );
          },
        ),
      ]),
    ));
  }
}
