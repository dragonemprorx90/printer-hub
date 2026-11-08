import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'charts.dart';
import 'console_page.dart';
import 'moonraker.dart';
import 'settings.dart';
import 'u1_panels.dart';
import 'ui.dart';

class ToolsTab extends StatefulWidget {
  final MoonrakerClient client;
  final Printer printer;
  const ToolsTab({super.key, required this.client, required this.printer});
  @override
  State<ToolsTab> createState() => _ToolsTabState();
}

/// (title, what it does, command candidates — the first one the printer has wins)
const _calibrations = [
  (
    'Nozzle PID',
    'Tunes the hotend heater so it holds temperature steadily.',
    ['NOZZLE_PID', 'PID_CALIBRATE HEATER=extruder TARGET=220'],
  ),
  (
    'Bed PID',
    'Tunes the bed heater.',
    ['BEDPID', 'PID_CALIBRATE HEATER=heater_bed TARGET=60'],
  ),
  (
    'Input shaper',
    'Measures vibrations so the printer can move faster and cleaner.',
    ['INPUTSHAPER', 'SHAPER_CALIBRATE'],
  ),
  ('Belt tension', 'Checks the X and Y belt tension.', ['BELT_TENSION']),
  ('Z tilt', 'Levels the gantry to the bed.', ['Z_TILT_ADJUST']),
  ('Quad gantry level', 'Levels a four-motor gantry.', ['QUAD_GANTRY_LEVEL']),
  (
    'Bed mesh',
    'Probes the bed surface (see Bed mesh).',
    ['BED_MESH_CALIBRATE'],
  ),
];

/// (title, description, command, icon)
const _filament = [
  (
    'Load from CFS',
    'Heats up and feeds filament from the CFS into the nozzle.',
    'BOX_LOAD_MATERIAL',
    Icons.download_rounded,
  ),
  (
    'Unload to CFS',
    'Heats up, cuts and pulls the filament back into the CFS.',
    'BOX_QUIT_MATERIAL',
    Icons.upload_rounded,
  ),
  (
    'Load external spool',
    'Heats up and loads filament from the spool holder.',
    'LOAD_MATERIAL',
    Icons.download_rounded,
  ),
  (
    'Unload external spool',
    'Heats up, cuts and retracts the filament for removal.',
    'QUIT_MATERIAL',
    Icons.upload_rounded,
  ),
  (
    'Refresh CFS',
    'Re-reads spool colours and RFID data from the CFS.',
    'BOX_INFO_REFRESH',
    Icons.refresh_rounded,
  ),
  (
    'Load filament',
    'Runs the printer\'s LOAD_FILAMENT macro.',
    'LOAD_FILAMENT',
    Icons.download_rounded,
  ),
  (
    'Unload filament',
    'Runs the printer\'s UNLOAD_FILAMENT macro.',
    'UNLOAD_FILAMENT',
    Icons.upload_rounded,
  ),
];

const _defaultMaintenance = [
  ('Clean nozzle and hotend', 200.0),
  ('Lubricate rods and lead screws', 300.0),
  ('Check belt tension', 200.0),
  ('Clean the build plate', 50.0),
];

class _ToolsTabState extends State<ToolsTab> {
  late final Future<List<PowerDevice>> _power = c.powerDevices();
  double? _printHours;

  MoonrakerClient get c => widget.client;
  String get _maintKey => 'maint.${widget.printer.key}';

  @override
  void initState() {
    super.initState();
    _loadHours();
  }

  Future<void> _loadHours() async {
    try {
      final t = await c.historyTotals();
      final hours = t.printTime / 3600;
      // First visit: start every reminder from today's hour count.
      if (settings.jsonList(_maintKey).isEmpty) {
        settings.setJsonList(_maintKey, [
          for (final (name, every) in _defaultMaintenance)
            {'name': name, 'hours': every, 'since': hours},
        ]);
      }
      if (mounted) setState(() => _printHours = hours);
    } catch (_) {}
  }

  Future<void> _runCommand(String title, String command, String why) async {
    final busy = c.status.state == 'printing' || c.status.state == 'paused';
    if (busy) return toast(context, 'Wait for the print to finish first');
    if (!await confirm(
          context,
          '$title?',
          message:
              '$why\n\nThe printer may heat up and move. Stay nearby.\n\nRuns: $command',
          action: 'Start',
        ) ||
        !mounted) {
      return;
    }
    run(context, () => c.gcode(command), done: '$title finished');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PrinterStatus>(
      stream: c.stream,
      initialData: c.status,
      builder: (context, snap) {
        final s = snap.data!;
        final left = [_meshPanel(s), _calibrationPanel()];
        final right = [
          _filamentPanel(),
          _maintenancePanel(),
          _powerPanel(),
          TimelapsePanel(client: c),
          SpoolmanPanel(client: c),
          RulesPanel(client: c),
          HealthPanel(client: c),
          _remotePanel(),
          _consolePanel(),
        ];
        const gap = SizedBox(height: 16, width: 16);
        List<Widget> spaced(List<Widget> w) => [
          for (final (i, x) in w.indexed) ...[if (i > 0) gap, x],
        ];
        return LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth >= 860) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Column(children: spaced(left))),
                    gap,
                    Expanded(child: Column(children: spaced(right))),
                  ],
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: spaced([...left, ...right]),
            );
          },
        );
      },
    );
  }

  Widget _meshPanel(PrinterStatus s) {
    final mesh = s.mesh;
    final flat = [for (final r in mesh) ...r];
    final lo = flat.isEmpty ? 0.0 : flat.reduce((a, b) => a < b ? a : b);
    final hi = flat.isEmpty ? 0.0 : flat.reduce((a, b) => a > b ? a : b);
    return Panel(
      title: 'Bed mesh',
      icon: Icons.grid_on_rounded,
      trailing: c.has('BED_MESH_CALIBRATE')
          ? TextButton.icon(
              onPressed: () => _runCommand(
                'Calibrate bed mesh',
                'BED_MESH_CALIBRATE',
                'Probes the whole bed. Takes a few minutes.',
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Calibrate'),
            )
          : null,
      child: mesh.isEmpty
          ? Text('No bed mesh loaded.', style: TextStyle(color: C.muted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: MeshView(mesh: mesh),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 24,
                  runSpacing: 10,
                  children: [
                    StatTile(
                      label: 'Profile',
                      value: s.meshProfile.isEmpty ? '—' : s.meshProfile,
                    ),
                    StatTile(
                      label: 'Points',
                      value: '${mesh.first.length} × ${mesh.length}',
                    ),
                    StatTile(
                      label: 'Lowest',
                      value: '${lo.toStringAsFixed(3)} mm',
                    ),
                    StatTile(
                      label: 'Highest',
                      value: '${hi.toStringAsFixed(3)} mm',
                    ),
                    StatTile(
                      label: 'Range',
                      value: '${(hi - lo).toStringAsFixed(3)} mm',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  (hi - lo) < 0.2
                      ? 'Flat enough: the mesh compensates for this easily.'
                      : (hi - lo) < 0.5
                      ? 'Some warp. The mesh handles it, but check the bed screws.'
                      : 'Large variation. Check the bed is clean and seated properly.',
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
              ],
            ),
    );
  }

  Widget _calibrationPanel() {
    final items = [
      for (final (title, why, candidates) in _calibrations)
        if (candidates.firstWhere(
              (cmd) => c.has(cmd.split(' ').first),
              orElse: () => '',
            )
            case final cmd when cmd.isNotEmpty)
          (title, why, cmd),
    ];
    return Panel(
      title: 'Calibration',
      icon: Icons.tune_rounded,
      child: items.isEmpty
          ? Text(
              'No calibration commands found on this printer.',
              style: TextStyle(color: C.muted),
            )
          : Column(
              children: [
                for (final (title, why, cmd) in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      why,
                      style: TextStyle(color: C.muted, fontSize: 12),
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => _runCommand(title, cmd, why),
                      child: const Text('Run'),
                    ),
                  ),
                if (c.has('SAVE_CONFIG'))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Most results need saving, which restarts Klipper.',
                            style: TextStyle(color: C.muted, fontSize: 12),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            if (await confirm(
                                  context,
                                  'Save calibration results?',
                                  message:
                                      'Runs SAVE_CONFIG. Klipper restarts.',
                                  action: 'Save & restart',
                                  danger: true,
                                ) &&
                                mounted) {
                              run(context, () => c.gcode('SAVE_CONFIG'));
                            }
                          },
                          child: const Text('Save results'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _filamentPanel() {
    final items = [
      for (final item in _filament)
        if (c.has(item.$3)) item,
    ];
    return Panel(
      title: 'Filament',
      icon: Icons.cable_rounded,
      child: items.isEmpty
          ? Text(
              'No load/unload macros found on this printer.',
              style: TextStyle(color: C.muted),
            )
          : Column(
              children: [
                for (final (title, why, cmd, icon) in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(icon, color: C.accent),
                    title: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      why,
                      style: TextStyle(color: C.muted, fontSize: 12),
                    ),
                    onTap: () => _runCommand(title, cmd, why),
                  ),
              ],
            ),
    );
  }

  Widget _maintenancePanel() {
    final items = settings.jsonList(_maintKey);
    final hours = _printHours;
    return Panel(
      title: 'Maintenance',
      icon: Icons.build_circle_outlined,
      trailing: IconButton(
        tooltip: 'Add reminder',
        icon: const Icon(Icons.add_rounded),
        onPressed: hours == null
            ? null
            : () async {
                final name = await askText(
                  context,
                  'New reminder',
                  hint: 'e.g. Replace PTFE tube',
                  action: 'Next',
                );
                if (name == null || name.isEmpty || !mounted) return;
                final every = await askNumber(
                  context,
                  'Every how many print hours?',
                  presets: const [25, 50, 100, 200, 500],
                  unit: ' h',
                );
                if (every == null || every <= 0) return;
                settings.setJsonList(_maintKey, [
                  ...items,
                  {'name': name, 'hours': every.toDouble(), 'since': hours},
                ]);
                setState(() {});
              },
      ),
      child: hours == null
          ? const LinearProgressIndicator()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${hours.toStringAsFixed(0)} print hours in total',
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
                const SizedBox(height: 10),
                for (final (i, m) in items.indexed) ...[
                  () {
                    final every = (m['hours'] as num).toDouble();
                    final used = (hours - (m['since'] as num).toDouble()).clamp(
                      0,
                      1e9,
                    );
                    final f = every <= 0 ? 0.0 : used / every;
                    final color = f >= 1
                        ? C.danger
                        : (f >= 0.8 ? C.warn : C.accent);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${m['name']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '${used.toStringAsFixed(0)} / ${every.toStringAsFixed(0)} h',
                                style: TextStyle(
                                  color: f >= 1 ? C.danger : C.muted,
                                  fontSize: 12,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Mark done',
                                icon: const Icon(Icons.check_rounded, size: 18),
                                onPressed: () async {
                                  if (!await confirm(
                                        context,
                                        'Mark "${m['name']}" as done?',
                                        action: 'Done',
                                      ) ||
                                      !mounted) {
                                    return;
                                  }
                                  items[i] = {...m, 'since': hours};
                                  settings.setJsonList(_maintKey, items);
                                  setState(() {});
                                },
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () {
                                  settings.setJsonList(
                                    _maintKey,
                                    [...items]..removeAt(i),
                                  );
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              value: f.clamp(0, 1).toDouble(),
                              minHeight: 6,
                              backgroundColor: C.surfaceHi,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    );
                  }(),
                ],
              ],
            ),
    );
  }

  Widget _powerPanel() => FutureBuilder<List<PowerDevice>>(
    future: _power,
    builder: (context, snap) {
      final devices = snap.data ?? const [];
      if (devices.isEmpty) return const SizedBox.shrink();
      return Panel(
        title: 'Power',
        icon: Icons.power_rounded,
        child: Column(
          children: [
            for (final d in devices)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(d.name),
                value: d.on,
                onChanged: (on) async {
                  if (!on &&
                      !await confirm(
                        context,
                        'Turn off ${d.name}?',
                        message: 'Anything powered by it stops immediately.',
                        action: 'Turn off',
                        danger: true,
                      )) {
                    return;
                  }
                  if (!context.mounted) return;
                  await run(context, () => c.setPower(d.name, on));
                  setState(() {});
                },
              ),
          ],
        ),
      );
    },
  );

  Widget _remotePanel() {
    final alerts = c.relay?.alerts;
    if (c.relay != null) {
      return Panel(
        title: 'Away from home',
        icon: Icons.public_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  c.viaRelay ? Icons.public_rounded : Icons.wifi_rounded,
                  color: C.accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.viaRelay ? 'Connected through your home bridge.' : 'Paired with your home bridge. It takes over when you leave home.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (alerts != null) ...[
              const SizedBox(height: 14),
              const Text(
                'Alerts with the app closed',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Your bridge sends finished / failed / paused / humidity alerts to a '
                'private ntfy topic. Install the free ntfy app, tap "+" and paste this topic:',
                style: TextStyle(color: C.muted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                decoration: BoxDecoration(
                  color: C.surfaceHi,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        alerts,
                        style: mono.copyWith(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: alerts));
                        toast(context, 'Topic copied');
                      },
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('https://docs.ntfy.sh/subscribe/phone/'),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Get the ntfy app'),
                ),
              ),
              Text(
                'Keep the topic private: anyone who has it can read your alerts.',
                style: TextStyle(color: C.muted, fontSize: 12),
              ),
            ],
          ],
        ),
      );
    }
    return Panel(
      title: 'Away from home',
      icon: Icons.public_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Printer Hub talks to the printer directly on your Wi-Fi, so nothing '
            'goes through anyone\'s cloud. To check prints from outside, put this '
            'phone and a computer on the printer\'s network on Tailscale (free), '
            'then add the printer again with its Tailscale address.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://tailscale.com/download'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Get Tailscale'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _consolePanel() => Panel(
    title: 'Console',
    icon: Icons.terminal,
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Send G-code and read the printer\'s replies.',
            style: TextStyle(color: C.muted, fontSize: 13),
          ),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ConsolePage(client: c)),
          ),
          child: const Text('Open'),
        ),
      ],
    ),
  );
}
