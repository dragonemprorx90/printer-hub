import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'moonraker.dart';
import 'ui.dart';

/// DragonBreath chamber heater on a U1: status, filament drying, fault clear.
class HeaterPanel extends StatelessWidget {
  final PrinterStatus s;
  final MoonrakerClient client;
  const HeaterPanel({super.key, required this.s, required this.client});

  String _status(Map<String, dynamic> d) {
    if (d['connected'] != true) return 'Not connected';
    if (d['fault'] == true) return 'Fault: ${d['fault_reason'] ?? 'unknown'}';
    final mode = '${d['mode'] ?? 'off'}';
    if (mode == 'drying') return 'Drying filament at ${(d['target'] as num? ?? 0).round()}°C';
    if (d['heating'] == true) return 'Heating to ${(d['target'] as num? ?? 0).round()}°C';
    return mode == 'off' ? 'Off' : mode[0].toUpperCase() + mode.substring(1);
  }

  Future<void> _dry(BuildContext context) async {
    final t = await askNumber(context, 'Drying temperature', presets: const [40, 45, 50, 55, 60, 65]);
    if (t == null || !context.mounted) return;
    final h = await askNumber(context, 'Drying time', presets: const [2, 4, 6, 8, 12], unit: ' h');
    if (h == null || !context.mounted) return;
    final tc = t.clamp(30, 70), hc = h.clamp(1, 12);
    await run(context, () => client.heaterCommand('drying_start', {'target_c': tc, 'hours': hc}),
        done: 'Drying at $tc°C for $hc h');
  }

  @override
  Widget build(BuildContext context) {
    final d = s.dragon!;
    final drying = d['mode'] == 'drying';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Panel(
        title: 'DragonBreath heater',
        icon: Icons.local_fire_department_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_status(d),
              style: TextStyle(
                  color: d['fault'] == true ? C.danger : C.muted, fontWeight: FontWeight.w600)),
          if (drying) _DryCountdown(client: client),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            if (drying)
              OutlinedButton.icon(
                onPressed: () =>
                    run(context, () => client.heaterCommand('drying_stop'), done: 'Drying stopped'),
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop drying'),
              )
            else
              OutlinedButton.icon(
                onPressed: d['connected'] == true && s.state != 'printing' ? () => _dry(context) : null,
                icon: const Icon(Icons.dry_rounded),
                label: const Text('Dry filament'),
              ),
            if (d['fault'] == true)
              FilledButton.icon(
                onPressed: () => run(context, client.resetHeaterFault, done: 'Heater fault cleared'),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Clear fault'),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Drying time left, read from the heater every 30 s.
class _DryCountdown extends StatefulWidget {
  final MoonrakerClient client;
  const _DryCountdown({required this.client});
  @override
  State<_DryCountdown> createState() => _DryCountdownState();
}

class _DryCountdownState extends State<_DryCountdown> {
  int? _left;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _tick();
    _t = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  Future<void> _tick() async {
    try {
      final st = await widget.client.heaterState();
      final left = (st['drying']?['remaining_seconds'] as num?)?.toInt();
      if (mounted) setState(() => _left = left);
    } catch (_) {}
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _left == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${fmtDuration(_left)} left', style: TextStyle(color: C.muted)),
        );
}

const _materials = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'PA', 'PC', 'PVA'];
const _colors = [
  0xFFFFFF, 0x000000, 0x9E9E9E, 0xE53935, 0xFB8C00, 0xF8F81C, //
  0x43A047, 0x1E88E5, 0x3949AB, 0x8E24AA, 0xD81B60, 0x795548,
];

/// Edit an AFC lane's colour and material (U1).
Future<void> editLane(BuildContext context, MoonrakerClient client, CfsSlot slot) async {
  int? color = slot.color == null ? null : slot.color! & 0xFFFFFF;
  var material = slot.material.isEmpty ? 'PLA' : slot.material;
  final ok = await showDialog<Object>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text('Lane ${slot.label}'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Material'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in {..._materials, material})
                  ChoiceChip(
                      label: Text(m),
                      selected: m == material,
                      onSelected: (_) => set(() => material = m)),
              ]),
              const SizedBox(height: 16),
              const Text('Colour'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in _colors)
                  InkWell(
                    onTap: () => set(() => color = c),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF000000 | c),
                        border: Border.all(
                            color: c == color ? C.accent : C.border, width: c == color ? 3 : 1),
                      ),
                    ),
                  ),
              ]),
            ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'spool'), child: const Text('Choose spool')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (ok == 'spool') return chooseLaneSpool(context, client, slot);
  if (ok != true) return;
  await run(context, () => client.setLane(slot.lane!, color: color, material: material),
      done: 'Lane ${slot.label} updated');
}

/// After loading a new spool: pick it from Spoolman for this lane.
Future<void> chooseLaneSpool(BuildContext context, MoonrakerClient client, CfsSlot slot) async {
  List<Spool> spools;
  try {
    if (!await client.hasSpoolman()) throw 'Spoolman is not set up on this printer';
    spools = await client.spools();
  } catch (e) {
    if (context.mounted) toast(context, '$e', error: true);
    return;
  }
  if (!context.mounted) return;
  final pick = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(title: Text('Spool in lane ${slot.label}')),
        for (final s in spools)
          ListTile(
            leading: CircleAvatar(radius: 12, backgroundColor: s.color == null ? C.border : Color(s.color!)),
            title: Text(s.name.isEmpty ? 'Spool ${s.id}' : s.name),
            subtitle: Text([s.material, if (s.remaining != null) '${s.remaining!.round()} g left'].join(' · ')),
            selected: s.id == slot.spoolId,
            onTap: () => Navigator.pop(ctx, s.id),
          ),
        if (slot.spoolId != null)
          ListTile(
            leading: const Icon(Icons.link_off_rounded),
            title: const Text('No spool'),
            onTap: () => Navigator.pop(ctx, 0),
          ),
        if (spools.isEmpty) const ListTile(title: Text('No spools yet. Add one in Tools → Spools.')),
      ]),
    ),
  );
  if (pick == null || !context.mounted) return;
  await run(context, () => client.setLaneSpool(slot.lane!, pick),
      done: pick == 0 ? 'Lane ${slot.label} unlinked' : 'Spool set for lane ${slot.label}');
}

/// Timelapse videos recorded by the printer.
class TimelapsePanel extends StatefulWidget {
  final MoonrakerClient client;
  const TimelapsePanel({super.key, required this.client});
  @override
  State<TimelapsePanel> createState() => _TimelapsePanelState();
}

class _TimelapsePanelState extends State<TimelapsePanel> {
  late final _list =
      widget.client.timelapses().catchError((_) => <(String, int, DateTime)>[]);
  final _busy = <String>{};

  Future<void> _save(String path) async {
    setState(() => _busy.add(path));
    try {
      final bytes = await widget.client.timelapseBytes(path);
      final saved = await FilePicker.saveFile(fileName: path.split('/').last, bytes: bytes);
      if (saved != null && mounted) toast(context, 'Timelapse saved');
    } catch (e) {
      if (mounted) toast(context, 'Could not save it: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(path));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<(String, int, DateTime)>>(
        future: _list,
        builder: (context, snap) {
          final vids = snap.data ?? const [];
          if (vids.isEmpty) return const SizedBox.shrink();
          return Panel(
            title: 'Timelapses',
            icon: Icons.movie_outlined,
            child: Column(children: [
              for (final (path, size, at) in vids.take(20))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(path.replaceAll(RegExp(r'_\d{14}\.mp4$'), ''),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${fmtDate(at)} · ${(size / 1e6).toStringAsFixed(1)} MB'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    // ponytail: Play streams straight from Moonraker, so it's home-only.
                    if (!widget.client.viaRelay)
                      IconButton(
                        tooltip: 'Play',
                        icon: const Icon(Icons.play_circle_outline_rounded),
                        onPressed: () => launchUrl(widget.client.timelapseUrl(path)),
                      ),
                    _busy.contains(path)
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2)))
                        : IconButton(
                            tooltip: 'Save',
                            icon: const Icon(Icons.download_rounded),
                            onPressed: () => _save(path),
                          ),
                  ]),
                ),
            ]),
          );
        },
      );
}

/// Spoolman spools: set the active spool, or link one to a U1 lane.
class SpoolmanPanel extends StatefulWidget {
  final MoonrakerClient client;
  const SpoolmanPanel({super.key, required this.client});
  @override
  State<SpoolmanPanel> createState() => _SpoolmanPanelState();
}

class _SpoolmanPanelState extends State<SpoolmanPanel> {
  late Future<(List<Spool>, int?)?> _data = _load();

  Future<(List<Spool>, int?)?> _load() async {
    final c = widget.client;
    if (!await c.hasSpoolman()) return null;
    return (await c.spools(), await c.activeSpool());
  }

  void _reload() => setState(() => _data = _load());

  /// From a lane: its material and colour are already set, so only the
  /// weight is asked, and the new spool is linked to that lane.
  Future<void> _add() async {
    final c = widget.client;
    final lanes = [
      for (final b in c.status.cfs)
        for (final s in b.slots)
          if (s.lane != null && !s.empty) s,
    ];
    if (lanes.isEmpty) return _addManual();
    final pick = await showModalBottomSheet<Object>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Add the spool in…')),
          for (final l in lanes)
            ListTile(
              leading: CircleAvatar(radius: 12, backgroundColor: Color(l.color!)),
              title: Text('Lane ${l.label} · ${l.material}'),
              onTap: () => Navigator.pop(ctx, l),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Another spool (choose material and colour)'),
            onTap: () => Navigator.pop(ctx, 'manual'),
          ),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick is! CfsSlot) return _addManual();
    final g = await askNumber(context, 'Filament weight on the spool',
        presets: const [1000, 750, 500, 250], unit: ' g');
    if (g == null || g <= 0 || !mounted) return;
    await run(context, () async {
      final id = await c.addSpool(
          vendor: 'Generic', material: pick.material, color: pick.color!, grams: g.toDouble());
      await c.setLaneSpool(pick.lane!, id);
    }, done: 'Spool added to lane ${pick.label}');
    _reload();
  }

  Future<void> _addManual() async {
    final vendor = TextEditingController(text: 'Generic');
    final grams = TextEditingController(text: '1000');
    var material = 'PLA';
    var color = _colors.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Add spool'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: vendor, decoration: const InputDecoration(labelText: 'Brand')),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in _materials)
                  ChoiceChip(label: Text(m), selected: m == material, onSelected: (_) => set(() => material = m)),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in _colors)
                  InkWell(
                    onTap: () => set(() => color = c),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF000000 | c),
                        border: Border.all(color: c == color ? C.accent : C.border, width: c == color ? 3 : 1),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: grams,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Filament weight', suffixText: 'g'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final name = vendor.text.trim().isEmpty ? 'Generic' : vendor.text.trim();
    await run(
        context,
        () => widget.client.addSpool(
            vendor: name, material: material, color: color, grams: double.tryParse(grams.text) ?? 1000),
        done: 'Spool added');
    _reload();
  }

  Future<void> _pick(Spool sp, int? active) async {
    final c = widget.client;
    final lanes = [
      for (final b in c.status.cfs)
        for (final s in b.slots)
          if (s.lane != null) s,
    ];
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(sp.name.isEmpty ? 'Spool ${sp.id}' : sp.name), subtitle: Text(sp.material)),
          ListTile(
            leading: Icon(sp.id == active ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(sp.id == active ? 'Stop using this spool' : 'Use as the active spool'),
            onTap: () => Navigator.pop(ctx, 'active'),
          ),
          for (final l in lanes)
            ListTile(
              leading: const Icon(Icons.input_rounded),
              title: Text('Load in lane ${l.label}'),
              onTap: () => Navigator.pop(ctx, l.lane),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'active') {
      await run(context, () => c.setActiveSpool(sp.id == active ? null : sp.id), done: 'Active spool updated');
    } else {
      await run(context, () => c.setLaneSpool(choice, sp.id), done: 'Spool linked to lane');
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(List<Spool>, int?)?>(
        future: _data,
        builder: (context, snap) {
          final d = snap.data;
          if (d == null) return const SizedBox.shrink();
          final (spools, active) = d;
          return Panel(
            title: 'Spools',
            icon: Icons.album_outlined,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Add spool', icon: const Icon(Icons.add_rounded), onPressed: _add),
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _reload),
            ]),
            child: spools.isEmpty
                ? Text('No spools yet. Add them in Spoolman.', style: TextStyle(color: C.muted))
                : Column(children: [
                    for (final sp in spools)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 14,
                          backgroundColor: sp.color == null ? C.border : Color(sp.color!),
                        ),
                        title: Text(sp.name.isEmpty ? 'Spool ${sp.id}' : sp.name,
                            style: TextStyle(fontWeight: sp.id == active ? FontWeight.w800 : null)),
                        subtitle: Text([
                          sp.material,
                          if (sp.remaining != null) '${sp.remaining!.round()} g left',
                          if (sp.id == active) 'active',
                        ].where((x) => x.isNotEmpty).join(' · ')),
                        onTap: () => _pick(sp, active),
                      ),
                  ]),
          );
        },
      );
}

/// What each tool in a gcode file needs, and the lane that feeds it now.
typedef ToolNeed = ({int tool, String type, int? color, CfsSlot? lane, double? grams});

List<ToolNeed> toolNeeds(Map<String, dynamic> meta, List<CfsSlot> lanes) {
  final types = '${meta['filament_type'] ?? ''}'.split(';');
  final colors = '${meta['filament_colour'] ?? ''}'.split(';');
  final weights = (meta['filament_weight'] as List?) ?? const [];
  if (types.join().trim().isEmpty) return const [];
  return [
    for (var i = 0; i < types.length; i++)
      (
        tool: i,
        type: types[i].trim(),
        color: i < colors.length ? parseCfsColor(colors[i].replaceAll('#', '')) : null,
        lane: lanes.where((l) => l.label == 'T$i').firstOrNull,
        grams: i < weights.length ? (weights[i] as num?)?.toDouble() : null,
      ),
  ];
}

bool needMismatch(ToolNeed n) =>
    n.lane == null || n.lane!.empty || n.lane!.material.toUpperCase() != n.type.toUpperCase();

/// Grams left on the lane's Spoolman spool, if it has one.
double? spoolLeft(ToolNeed n, List<Spool> spools) =>
    spools.where((s) => s.id == n.lane?.spoolId).firstOrNull?.remaining;

/// In the print sheet: which lane feeds each tool, with a warning and remap.
class FilamentCheck extends StatefulWidget {
  final Map<String, dynamic> meta;
  final MoonrakerClient client;
  const FilamentCheck({super.key, required this.meta, required this.client});
  @override
  State<FilamentCheck> createState() => _FilamentCheckState();
}

class _FilamentCheckState extends State<FilamentCheck> {
  Map<String, dynamic> get meta => widget.meta;
  MoonrakerClient get client => widget.client;
  late final Future<List<Spool>> _spools = () async {
    try {
      return await client.hasSpoolman() ? await client.spools() : <Spool>[];
    } catch (_) {
      return <Spool>[];
    }
  }();

  Future<void> _remap(BuildContext context, ToolNeed n, List<CfsSlot> lanes) async {
    final lane = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Feed T${n.tool} (${n.type}) from')),
          for (final l in lanes)
            ListTile(
              leading: CircleAvatar(
                  radius: 12, backgroundColor: l.color == null ? C.border : Color(l.color!)),
              title: Text('Lane ${l.lane} · ${l.empty ? 'empty' : l.material}'),
              subtitle: Text('now feeds ${l.label}'),
              onTap: () => Navigator.pop(ctx, l.lane),
            ),
        ]),
      ),
    );
    if (lane == null || !context.mounted) return;
    await run(context, () => client.setLaneMap(lane, n.tool), done: 'T${n.tool} now uses lane $lane');
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<PrinterStatus>(
        stream: client.stream,
        initialData: client.status,
        builder: (context, snap) {
          final lanes = [
            for (final b in snap.data!.cfs)
              for (final s in b.slots)
                if (s.lane != null) s,
          ];
          if (lanes.isEmpty) return const SizedBox.shrink();
          final needs = toolNeeds(meta, lanes);
          if (needs.isEmpty) return const SizedBox.shrink();
          return FutureBuilder<List<Spool>>(
            future: _spools,
            builder: (context, sp) => _list(context, needs, lanes, sp.data ?? const []),
          );
        },
      );

  Widget _list(BuildContext context, List<ToolNeed> needs, List<CfsSlot> lanes, List<Spool> spools) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Filament', style: TextStyle(color: C.muted, fontSize: 12)),
            for (final n in needs)
              InkWell(
                onTap: () => _remap(context, n, lanes),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    CircleAvatar(
                        radius: 8, backgroundColor: n.color == null ? C.border : Color(n.color!)),
                    const SizedBox(width: 6),
                    Text('T${n.tool} ${n.type}'),
                    const Icon(Icons.arrow_right_alt_rounded, size: 18),
                    CircleAvatar(
                        radius: 8,
                        backgroundColor: n.lane?.color == null ? C.border : Color(n.lane!.color!)),
                    const SizedBox(width: 6),
                    Text(n.lane == null ? 'no lane' : '${n.lane!.lane} ${n.lane!.empty ? 'empty' : n.lane!.material}'),
                    if (n.grams != null)
                      Text(' · ${n.grams!.toStringAsFixed(0)} g'
                          '${spoolLeft(n, spools) == null ? '' : ' of ${spoolLeft(n, spools)!.round()} g left'}',
                          style: TextStyle(color: C.muted)),
                    if (needMismatch(n) || lowSpool(n, spools)) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: lowSpool(n, spools) ? 'Not enough filament left on this spool' : 'Wrong or no filament',
                        child: const Icon(Icons.warning_amber_rounded, size: 16, color: C.warn),
                      ),
                    ],
                  ]),
                ),
              ),
          ]);
}

/// The spool has less than the print needs (plus 5 g to spare).
bool lowSpool(ToolNeed n, List<Spool> spools) {
  final left = spoolLeft(n, spools);
  return left != null && n.grams != null && left < n.grams! + 5;
}

/// Printer host health: CPU, memory, storage, versions and any warnings.
class HealthPanel extends StatefulWidget {
  final MoonrakerClient client;
  const HealthPanel({super.key, required this.client});
  @override
  State<HealthPanel> createState() => _HealthPanelState();
}

class _HealthPanelState extends State<HealthPanel> {
  late var _data = widget.client.health();

  @override
  Widget build(BuildContext context) => FutureBuilder<(List<(String, String)>, List<String>)>(
        future: _data,
        builder: (context, snap) {
          final d = snap.data;
          if (d == null || d.$1.isEmpty) return const SizedBox.shrink();
          final (rows, problems) = d;
          return Panel(
            title: 'Printer health',
            icon: Icons.monitor_heart_outlined,
            trailing: IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => setState(() => _data = widget.client.health()),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final p in problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.warning_amber_rounded, size: 18, color: C.warn),
                    const SizedBox(width: 6),
                    Expanded(child: Text(p)),
                  ]),
                ),
              if (problems.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('No problems found', style: TextStyle(color: C.muted)),
                ),
              Wrap(spacing: 28, runSpacing: 12, children: [
                for (final (k, v) in rows) StatTile(label: k, value: v),
              ]),
            ]),
          );
        },
      );
}

const _triggers = {
  'first_layer': 'First layer is done',
  'progress': 'Print reaches…',
  'paused': 'Print pauses',
  'heater_fault': 'Chamber heater faults',
  'complete': 'Print finishes',
  'error': 'Print fails',
  'cancelled': 'Print is cancelled',
  'time': 'Every day at…',
};

/// "When X, do Y" rules, run by the home bridge even with the app closed.
class RulesPanel extends StatefulWidget {
  final MoonrakerClient client;
  const RulesPanel({super.key, required this.client});
  @override
  State<RulesPanel> createState() => _RulesPanelState();
}

class _RulesPanelState extends State<RulesPanel> {
  late Future<List<Map<String, dynamic>>> _rules = widget.client.rules();

  List<(String, String)> _actions(PrinterStatus s) => [
        ('Send me a picture', '@picture'),
        if (s.raw.containsKey(PrinterStatus.cavityLed)) ('Light off', 'SET_LED LED=cavity_led WHITE=0'),
        if (s.raw.containsKey('output_pin LED')) ('Light off', 'SET_PIN PIN=LED VALUE=0'),
        ('All heaters off', 'TURN_OFF_HEATERS'),
        if (s.chamberHeatable) ('Chamber heater off', 'M141 S0'),
        if (s.raw.containsKey(PrinterStatus.dragonFilter)) ('Heater filter off', 'SET_PIN PIN=dragonbreath_filter VALUE=0'),
        ('Motors off', 'M84'),
      ];

  Future<void> _add() async {
    final c = widget.client;
    final on = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('When…')),
          for (final e in _triggers.entries)
            ListTile(title: Text(e.value), onTap: () => Navigator.pop(ctx, e.key)),
        ]),
      ),
    );
    if (on == null || !mounted) return;
    String? at;
    if (on == 'time') {
      final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 22, minute: 0));
      if (t == null || !mounted) return;
      at = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    } else if (on == 'progress') {
      final p = await askNumber(context, 'At what progress?', presets: const [25, 50, 75, 90], unit: '%');
      if (p == null || p <= 0 || p > 100 || !mounted) return;
      at = '$p';
    }
    final acts = _actions(c.status);
    final pick = await showModalBottomSheet<(String, String)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('…do this')),
          for (final a in acts) ListTile(title: Text(a.$1), onTap: () => Navigator.pop(ctx, a)),
          ListTile(title: const Text('Custom G-code…'), onTap: () => Navigator.pop(ctx, ('', ''))),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    var (label, gcode) = pick;
    if (gcode.isEmpty) {
      final g = await askText(context, 'G-code to run', hint: 'e.g. M84', action: 'Add');
      if (g == null || g.isEmpty || !mounted) return;
      (label, gcode) = (g, g);
    }
    final list = [...await _rules, {'on': on, 'at': ?at, 'do': gcode, 'label': label}];
    if (!mounted) return;
    await run(context, () => c.setRules(list), done: 'Rule added');
    setState(() => _rules = c.rules());
  }

  Future<void> _remove(List<Map<String, dynamic>> all, int i) async {
    final list = [...all]..removeAt(i);
    await run(context, () => widget.client.setRules(list));
    setState(() => _rules = widget.client.rules());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _rules,
        builder: (context, snap) {
          final rules = snap.data ?? const [];
          return Panel(
            title: 'Rules',
            icon: Icons.rule_rounded,
            trailing: IconButton(tooltip: 'Add rule', icon: const Icon(Icons.add_rounded), onPressed: _add),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (rules.isEmpty)
                Text('Run something automatically, like "print finishes → light off". '
                    'Your home bridge runs rules, even with the app closed.',
                    style: TextStyle(color: C.muted)),
              for (final (i, r) in rules.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bolt_rounded),
                  title: Text('${switch (r['on']) {
                        'time' => 'Every day at ${r['at']}',
                        'progress' => 'At ${r['at']}%',
                        final o => _triggers[o] ?? o,
                      }}'
                      ' → ${r['label'] ?? r['do']}'),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _remove(rules, i),
                  ),
                ),
            ]),
          );
        },
      );
}
