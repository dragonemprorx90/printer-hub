import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'camera.dart';
import 'moonraker.dart';
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

class _WallPageState extends State<WallPage> {
  bool get _awake => settings.flag('wallAwake');

  @override
  void initState() {
    super.initState();
    if (_awake) WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
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
        title: const Text('Wall'),
        actions: [
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
        final cols = (c.maxWidth / 520).floor().clamp(1, 4);
        return GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: cols,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 16 / 12.5,
          children: [
            for (final p in widget.printers) _WallTile(printer: p),
          ],
        );
      }),
    );
  }
}

class _WallTile extends StatelessWidget {
  final Printer printer;
  const _WallTile({required this.printer});

  @override
  Widget build(BuildContext context) {
    final client = clientFor(printer);
    return Panel(
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
                  Text(' ${s.hotend.toStringAsFixed(0)}°  '),
                  Icon(Icons.grid_view_rounded, size: 15, color: C.bed),
                  Text(' ${s.bed.toStringAsFixed(0)}°'),
                  const Spacer(),
                  if (active)
                    Text(
                      '${(s.progress * 100).toStringAsFixed(0)}% · ${fmtDuration(s.eta)} left',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                ]),
                if (active) ...[
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
    );
  }
}
