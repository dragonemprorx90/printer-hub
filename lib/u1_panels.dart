import 'dart:convert';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'insights.dart';
import 'moonraker.dart';
import 'scan.dart';
import 'settings.dart';
import 'ui.dart';
import 'workshop_page.dart';

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
    // A material preset (the heater tops out at 70°C), or your own numbers.
    final preset = await showModalBottomSheet<(String, int, int)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Dry which filament?')),
          for (final (m, t, h) in dryPresets)
            ListTile(
              title: Text(m),
              trailing: Text('${t.clamp(30, 70)}°C · $h h${t > 70 ? ' (heater max)' : ''}'),
              onTap: () => Navigator.pop(ctx, (m, t, h)),
            ),
          ListTile(title: const Text('Choose temperature and time…'), onTap: () => Navigator.pop(ctx, ('', 0, 0))),
        ]),
      ),
    );
    if (preset == null || !context.mounted) return;
    int? t = preset.$2, h = preset.$3;
    if (preset.$1.isEmpty) {
      t = await askNumber(context, 'Drying temperature', presets: const [40, 45, 50, 55, 60, 65]);
      if (t == null || !context.mounted) return;
      h = await askNumber(context, 'Drying time', presets: const [2, 4, 6, 8, 12], unit: ' h');
      if (h == null || !context.mounted) return;
    }
    final tc = t.clamp(30, 70), hc = h.clamp(1, 12);
    if (!await confirm(context, 'Start drying at $tc°C for $hc h?', action: 'Start') || !context.mounted) return;
    await run(context, () => client.heaterCommand('drying_start', {'target_c': tc, 'hours': hc}),
        done: 'Drying at $tc°C for $hc h');
    settings.setJsonList('dryLog', [
      ...settings.jsonList('dryLog'),
      {'spool': preset.$1.isEmpty ? 'DragonBreath $tc°C' : 'DragonBreath ${preset.$1}', 'at': DateTime.now().millisecondsSinceEpoch},
    ]);
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
          child: Text('${fmtDuration(_left)} left · done ${fmtTime(DateTime.now().add(Duration(seconds: _left!.round())))}',
              style: TextStyle(color: C.muted)),
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
  late var _list =
      widget.client.timelapses().catchError((_) => <(String, int, DateTime)>[]);

  Future<void> _delete(String path) async {
    if (!await confirm(context, 'Delete this timelapse?',
            message: '${path.split('/').last} is removed from the printer.', action: 'Delete', danger: true) ||
        !mounted) {
      return;
    }
    await run(context, () => widget.client.deleteTimelapse(path), done: 'Deleted');
    setState(() => _list = widget.client.timelapses().catchError((_) => <(String, int, DateTime)>[]));
  }
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
              Align(
                alignment: Alignment.centerLeft,
                child: Text('${vids.length} videos · ${fmtBytes(vids.fold(0, (a, v) => a + v.$2))}',
                    style: T.small.copyWith(color: C.muted)),
              ),
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
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => _delete(path),
                    ),
                  ]),
                ),
            ]),
          );
        },
      );
}

String spoolQr(int id) => 'web+spoolman:s-$id';

/// Spool ID from a Spoolman label ("web+spoolman:s-12" or a /spool/show/12 URL).
int? spoolFromQr(String code) {
  final m = RegExp(r'(?:web\+spoolman:s-|/spool/show/)(\d+)').firstMatch(code.trim());
  return m == null ? null : int.parse(m[1]!);
}

/// Spoolman spools: set the active spool, or link one to a U1 lane.
class SpoolmanPanel extends StatefulWidget {
  final MoonrakerClient client;
  const SpoolmanPanel({super.key, required this.client});
  @override
  State<SpoolmanPanel> createState() => _SpoolmanPanelState();
}

class _SpoolmanPanelState extends State<SpoolmanPanel> {
  String _spoolFind = '', _spoolSort = '';
  late Future<(List<Spool>, int?)?> _data = _load();

  Future<(List<Spool>, int?)?> _load() async {
    final c = widget.client;
    if (!await c.hasSpoolman()) return null;
    return (await c.spools(), await c.activeSpool());
  }

  void _reload() => setState(() => _data = _load());

  /// Spoolman's own QR format, so its labels and this app read the same codes.
  Future<void> _label(Spool sp) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(sp.name.isEmpty ? 'Spool ${sp.id}' : sp.name),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 220,
              height: 220,
              child: QrImageView(data: spoolQr(sp.id), backgroundColor: Colors.white),
            ),
            const SizedBox(height: 8),
            Text('${sp.material} · #${sp.id}. Screenshot or print it and stick it on the spool.',
                textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );

  Future<void> _scan(List<Spool> spools, int? active) async {
    final code = await scanQr(context, 'Scan a spool label');
    if (code == null || !mounted) return;
    final id = spoolFromQr(code);
    final sp = spools.where((s) => s.id == id).firstOrNull;
    if (sp == null) return toast(context, 'Not a spool label from this Spoolman', error: true);
    await _pick(sp, active);
  }

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
            leading: const Icon(Icons.qr_code_rounded),
            title: const Text('Show QR label'),
            onTap: () => Navigator.pop(ctx, 'qr'),
          ),
          ListTile(
            leading: const Icon(Icons.scale_outlined),
            title: const Text('Set grams left'),
            subtitle: const Text('Weigh it and take off the empty spool'),
            onTap: () => Navigator.pop(ctx, 'grams'),
          ),
          if ((sp.remaining ?? 1) <= 5)
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Archive this empty spool'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
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
    if (choice == 'qr') return _label(sp);
    if (choice == 'grams') {
      final g = await askNumber(context, 'Grams left on ${sp.name.isEmpty ? 'the spool' : sp.name}',
          presets: const [100, 250, 500, 750, 1000], unit: ' g');
      if (g == null || g < 0 || !mounted) return;
      await run(context, () => c.setSpoolGrams(sp.id, g.toDouble()), done: 'Updated');
      return _reload();
    }
    if (choice == 'archive') {
      if (!await confirm(context, 'Archive this spool?', message: 'It is hidden in Spoolman, not deleted.', action: 'Archive') ||
          !mounted) {
        return;
      }
      await run(context, () => c.archiveSpool(sp.id), done: 'Archived');
      return _reload();
    }
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
          final (all, active) = d;
          final q = _spoolFind.toLowerCase();
          final spools = [
            for (final sp in all)
              if (q.isEmpty || '${sp.name} ${sp.material} ${sp.color == null ? '' : colorName(sp.color!)}'.toLowerCase().contains(q)) sp,
          ];
          if (_spoolSort == 'left') spools.sort((a, b) => (a.remaining ?? 1e9).compareTo(b.remaining ?? 1e9));
          if (_spoolSort == 'material') spools.sort((a, b) => a.material.compareTo(b.material));
          return Panel(
            title: 'Spools',
            icon: Icons.album_outlined,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (canScan)
                IconButton(
                    tooltip: 'Scan spool label',
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    onPressed: () => _scan(spools, active)),
              IconButton(tooltip: 'Add spool', icon: const Icon(Icons.add_rounded), onPressed: _add),
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _reload),
            ]),
            child: spools.isEmpty
                ? Text('No spools yet. Add them in Spoolman.', style: TextStyle(color: C.muted))
                : Column(children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          [for (final (m, g, n) in inventory(all)) '$m ${(g / 1000).toStringAsFixed(1)} kg ($n)'].join(' · '),
                          style: T.small.copyWith(color: C.muted)),
                    ),
                    if (all.length > 5)
                      Row(children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(isDense: true, hintText: 'Find a spool (brand, material, colour)', prefixIcon: Icon(Icons.search_rounded)),
                            onChanged: (v) => setState(() => _spoolFind = v),
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Sort',
                          icon: const Icon(Icons.sort_rounded),
                          initialValue: _spoolSort,
                          onSelected: (v) => setState(() => _spoolSort = v),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: '', child: Text('As in Spoolman')),
                            PopupMenuItem(value: 'left', child: Text('Least left first')),
                            PopupMenuItem(value: 'material', child: Text('By material')),
                          ],
                        ),
                      ]),
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
                          if (sp.color != null) colorName(sp.color!),
                          if (sp.remaining != null) '${sp.remaining!.round()} g left',
                          if (pricePerGram(sp) case final g?) '${settings.text('currency', r'$')}${g.toStringAsFixed(3)}/g',
                          if (sp.id == active) 'active',
                        ].where((x) => x.isNotEmpty).join(' · '),
                            style: TextStyle(color: (sp.remaining ?? 1e9) < 100 ? C.ink(C.warn) : null)),
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
          // Version changes since last time (Klipper, Moonraker, firmware…), kept on this device.
          final key = 'health.versions.${widget.client.host}:${widget.client.port}';
          final now = {for (final (k, v) in rows) if (k.toLowerCase().contains('version') || k == 'Klipper' || k == 'Moonraker') k: v};
          final before = {
            for (final e in (jsonDecode(settings.text(key, '{}')) as Map).entries) '${e.key}': '${e.value}',
          };
          final changes = versionChanges(before, now);
          if (changes.isNotEmpty) {
            final log = settings.strings('$key.log');
            settings.setStrings('$key.log', [...log, for (final c in changes) '${fmtDate(DateTime.now())} $c'].reversed.take(20).toList().reversed.toList());
          }
          if (now.isNotEmpty && jsonEncode(now) != jsonEncode(before)) settings.setText(key, jsonEncode(now));
          final log = settings.strings('$key.log');
          return Panel(
            title: 'Printer health',
            icon: Icons.monitor_heart_outlined,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Copy for a bug report',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: [for (final (k, v) in rows) '$k: $v', ...problems.map((p) => 'Problem: $p')].join('\n')));
                  toast(context, 'Printer health copied');
                },
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => setState(() => _data = widget.client.health()),
              ),
            ]),
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
              FutureBuilder<List<(String, String, String)>>(
                future: widget.client.updatesWaiting().catchError((_) => <(String, String, String)>[]),
                builder: (_, u) => (u.data ?? const []).isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text('Updates waiting (install them from the printer\'s web page)', style: T.label.copyWith(color: C.muted)),
                          for (final (n, now, next) in u.data!) Text('$n: $now → $next', style: T.small),
                        ]),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, children: [
                  for (final l in const ['klippy.log', 'moonraker.log'])
                    ActionChip(
                      avatar: const Icon(Icons.article_outlined, size: 16),
                      label: Text(l),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _LogPage(client: widget.client, name: l))),
                    ),
                ]),
              ),
              if (log.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Updates seen', style: T.label.copyWith(color: C.muted)),
                for (final l in log.reversed.take(5)) Text(l, style: T.small),
              ],
            ]),
          );
        },
      );
}

const _triggers = {
  'first_layer': 'First layer is done',
  'progress': 'Print reaches…',
  'interval': 'Every few minutes while printing',
  'paused': 'Print pauses',
  'heater_fault': 'Chamber heater faults',
  'complete': 'Print finishes',
  'error': 'Print fails',
  'cancelled': 'Print is cancelled',
  'time': 'Every day at…',
  'printing': 'Print starts',
  'runout': 'Filament runs out',
  'chamber_ready': 'Chamber reaches its temperature',
  'bed_cool': 'Bed has cooled after a print',
  'layer': 'Print reaches layer…',
  'idle': 'Printer has been idle for…',
  'dry_done': 'Filament drying finishes (DragonBreath)',
  'humidity': 'CFS humidity goes over the limit',
};

/// Optional time windows for a rule: (label, days, from, to).
const _windows = [
  ('Any time', <int>[], '', ''),
  ('Weekdays', [1, 2, 3, 4, 5], '', ''),
  ('Weekends', [6, 7], '', ''),
  ('At night (22:00–07:00)', <int>[], '22:00', '07:00'),
  ('In the day (08:00–20:00)', <int>[], '08:00', '20:00'),
];

/// One-tap rules people often want.
const ruleTemplates = [
  {'on': 'complete', 'do': '@picture', 'label': 'Send me a picture'},
  {'on': 'complete', 'do': 'TURN_OFF_HEATERS', 'label': 'All heaters off'},
  {'on': 'first_layer', 'do': '@picture', 'label': 'Send me a picture'},
  {'on': 'interval', 'at': '10', 'do': '@keep', 'label': 'Save a picture to History'},
  {'on': 'runout', 'do': '@picture', 'label': 'Send me a picture'},
  {'on': 'error', 'do': 'TURN_OFF_HEATERS', 'label': 'All heaters off'},
  {'on': 'bed_cool', 'do': '@notify Take the print off', 'label': 'Alert: Take the print off'},
  {'on': 'idle', 'at': '60', 'do': 'TURN_OFF_HEATERS', 'label': 'All heaters off'},
  {'on': 'chamber_ready', 'do': '@notify Chamber is warm, ready to print', 'label': 'Alert: Chamber is warm'},
  {'on': 'humidity', 'do': '@notify Filament is getting damp: dry it', 'label': 'Alert: dry the filament'},
  {'on': 'printing', 'do': '@picture', 'label': 'Send me a picture'},
  {'on': 'time', 'at': '23:00', 'do': '@notify Is anything still printing?', 'label': 'Alert: nightly check', 'days': [1, 2, 3, 4, 5, 6, 7]},
  {'on': 'progress', 'at': '50', 'do': '@notify Halfway there', 'label': 'Alert: Halfway there'},
];

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
        ('Save a picture to History', '@keep'),
        if (s.dragon != null) ('Dry filament…', '@dry'),
        if (s.raw.containsKey(PrinterStatus.cavityLed)) ('Light off', 'SET_LED LED=cavity_led WHITE=0'),
        if (s.raw.containsKey('output_pin LED')) ('Light off', 'SET_PIN PIN=LED VALUE=0'),
        if (s.raw.containsKey(PrinterStatus.cavityLed)) ('Light on', 'SET_LED LED=cavity_led WHITE=1'),
        if (s.raw.containsKey('output_pin LED')) ('Light on', 'SET_PIN PIN=LED VALUE=1'),
        ('Pause the print', 'PAUSE'),
        ('Part cooling fan off', 'M107'),
        if (widget.client.macros.isNotEmpty) ('Run a macro…', '@macro'),
        ('All heaters off', 'TURN_OFF_HEATERS'),
        if (s.chamberHeatable) ('Chamber heater off', 'M141 S0'),
        if (s.raw.containsKey(PrinterStatus.dragonFilter)) ('Heater filter off', 'SET_PIN PIN=dragonbreath_filter VALUE=0'),
        ('Motors off', 'M84'),
        ('Send me an alert…', '@notify'),
        ('Power device on or off…', '@power'),
        ('Call a webhook (Home Assistant…)…', '@webhook'),
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
    } else if (on == 'interval') {
      final m = await askNumber(context, 'Every how many minutes?', presets: const [5, 10, 15, 30], unit: ' min');
      if (m == null || m <= 0 || !mounted) return;
      at = '$m';
    } else if (on == 'idle') {
      final m = await askNumber(context, 'Idle for how many minutes?', presets: const [15, 30, 60, 120], unit: ' min');
      if (m == null || m <= 0 || !mounted) return;
      at = '$m';
    } else if (on == 'layer') {
      final l = await askNumber(context, 'At which layer?', presets: const [2, 10, 50, 100], unit: '');
      if (l == null || l <= 0 || !mounted) return;
      at = '$l';
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
    if (gcode == '@dry') {
      final t = await askNumber(context, 'Drying temperature', presets: const [40, 45, 50, 55, 60, 65]);
      if (t == null || !mounted) return;
      final h = await askNumber(context, 'Drying time', presets: const [2, 4, 6, 8, 12], unit: ' h');
      if (h == null || !mounted) return;
      final tc = t.clamp(30, 70), hc = h.clamp(1, 12);
      (label, gcode) = ('Dry filament $tc°C for $hc h', '@dry $tc $hc');
    }
    if (gcode == '@macro') {
      final m = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const ListTile(title: Text('Which macro?')),
            for (final m in widget.client.macros) ListTile(title: Text(m, style: mono), onTap: () => Navigator.pop(ctx, m)),
          ]),
        ),
      );
      if (m == null || !mounted) return;
      (label, gcode) = ('Run $m', m);
    }
    if (gcode == '@power') {
      final devices = await c.powerDevices().catchError((_) => <PowerDevice>[]);
      if (!mounted) return;
      if (devices.isEmpty) return toast(context, 'This printer has no power devices set up in Moonraker', error: true);
      final pick = await showModalBottomSheet<(String, String)>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            for (final d in devices)
              for (final a in const ['off', 'on'])
                ListTile(title: Text('${d.name} $a'), onTap: () => Navigator.pop(ctx, (d.name, a))),
          ]),
        ),
      );
      if (pick == null || !mounted) return;
      if (pick.$1.contains(' ')) return toast(context, 'Power device names with spaces can\'t be used in rules', error: true);
      (label, gcode) = ('Power ${pick.$1} ${pick.$2}', '@power ${pick.$1} ${pick.$2}');
    }
    if (gcode == '@notify') {
      final t = await askText(context, 'Alert text', hint: 'e.g. Take the print off', action: 'Next');
      if (t == null || t.trim().isEmpty || !mounted) return;
      (label, gcode) = ('Alert: ${t.trim()}', '@notify ${t.trim()}');
    }
    if (gcode == '@webhook') {
      final u = await askText(context, 'Webhook URL', hint: 'http://homeassistant.local:8123/api/webhook/…', action: 'Next');
      final uri = Uri.tryParse(u?.trim() ?? '');
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
        if (u != null && mounted) toast(context, 'That needs to start with http:// or https://', error: true);
        return;
      }
      (label, gcode) = ('Webhook ${uri.host}', '@webhook $uri');
    }
    if (!mounted) return;
    final win = await showModalBottomSheet<(String, List<int>, String, String)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Only…')),
          for (final w in _windows) ListTile(title: Text(w.$1), onTap: () => Navigator.pop(ctx, w)),
        ]),
      ),
    );
    if (win == null || !mounted) return;
    if (gcode.isEmpty) {
      final g = await askText(context, 'G-code to run', hint: 'e.g. M84', action: 'Add');
      if (g == null || g.isEmpty || !mounted) return;
      (label, gcode) = (g, g);
    }
    final list = [
      ...await _rules,
      {
        'on': on,
        'at': ?at,
        'do': gcode,
        'label': label,
        if (win.$2.isNotEmpty) 'days': win.$2,
        if (win.$3.isNotEmpty) ...{'from': win.$3, 'to': win.$4},
      },
    ];
    if (!mounted) return;
    await run(context, () => c.setRules(list), done: 'Rule added');
    setState(() => _rules = c.rules());
  }

  Future<void> _templates() async {
    final pick = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Add a ready-made rule')),
          for (final t in ruleTemplates)
            ListTile(title: Text(ruleText(t, _triggers)), onTap: () => Navigator.pop(ctx, Map<String, dynamic>.from(t))),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    final list = [...await _rules, pick];
    if (!mounted) return;
    await run(context, () => widget.client.setRules(list), done: 'Rule added');
    setState(() => _rules = widget.client.rules());
  }

  /// Does the rule's action once, now, from the app (asks first). The bridge-only
  /// actions (pictures, alerts, webhooks, drying) aren't run from here.
  Future<void> _runNow(Map<String, dynamic> r) async {
    final g = '${r['do'] ?? ''}'.trim();
    if (g.isEmpty || g.startsWith('@')) {
      return toast(context, 'That one runs on your home bridge only. Use Test to see what it does.');
    }
    if (!await confirm(context, 'Run "${r['label'] ?? g}" now?', message: 'Sends $g to the printer.', action: 'Run') || !mounted) {
      return;
    }
    await run(context, () => widget.client.gcode(g), done: 'Done');
  }

  /// Dry run: says what the rule would do. Nothing is sent to the printer.
  void _test(Map<String, dynamic> r) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Test rule (nothing is sent)'),
          content: Text(ruleDryRun(r, _triggers, DateTime.now())),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  Future<void> _more(String v, List<Map<String, dynamic>> rules) async {
    final c = widget.client;
    switch (v) {
      case 'off' || 'on':
        await run(context, () => c.setRules([for (final r in rules) {...r, 'off': v == 'off'}]),
            done: v == 'off' ? 'Every rule is off' : 'Every rule is on');
      case 'copy':
        Clipboard.setData(ClipboardData(text: jsonEncode(rules)));
        return toast(context, 'Rules copied. Paste them into another printer or a note.');
      case 'paste':
        final t = await askText(context, 'Paste rules', hint: 'The text from "Copy rules as text"', action: 'Add');
        if (t == null || t.trim().isEmpty || !mounted) return;
        try {
          final added = [for (final r in jsonDecode(t) as List) Map<String, dynamic>.from(r as Map)];
          if (added.any((r) => r['on'] is! String || r['do'] is! String)) throw const FormatException();
          await run(context, () => c.setRules([...rules, ...added]), done: 'Added ${added.length} rules');
        } on FormatException {
          if (mounted) toast(context, 'That isn\'t a list of Printer Hub rules', error: true);
          return;
        } on TypeError {
          if (mounted) toast(context, 'That isn\'t a list of Printer Hub rules', error: true);
          return;
        }
    }
    if (mounted) setState(() => _rules = c.rules());
  }

  Future<void> _snooze() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Snooze this printer\'s alerts'), subtitle: Text('Failures and faults still come through.')),
          ListTile(title: const Text('For 1 hour'), onTap: () => Navigator.pop(ctx, 'hour')),
          ListTile(title: const Text('Until 08:00 tomorrow'), onTap: () => Navigator.pop(ctx, 'tomorrow')),
          ListTile(title: const Text('Turn snooze off'), onTap: () => Navigator.pop(ctx, 'off')),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    final until = pick == 'off' ? 0 : snoozeUntil(pick).millisecondsSinceEpoch;
    await run(context, () => widget.client.dbSet('snooze', until),
        done: pick == 'off' ? 'Alerts back on' : 'Alerts snoozed until ${fmtTime(DateTime.fromMillisecondsSinceEpoch(until))}');
  }

  /// Changes only a rule's days / hours.
  Future<void> _window(List<Map<String, dynamic>> all, int i) async {
    final win = await showModalBottomSheet<(String, List<int>, String, String)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Only…')),
          for (final w in _windows) ListTile(title: Text(w.$1), onTap: () => Navigator.pop(ctx, w)),
        ]),
      ),
    );
    if (win == null || !mounted) return;
    final r = {...all[i]}..removeWhere((k, _) => k == 'days' || k == 'from' || k == 'to');
    if (win.$2.isNotEmpty) r['days'] = win.$2;
    if (win.$3.isNotEmpty) r.addAll({'from': win.$3, 'to': win.$4});
    final list = [...all]..[i] = r;
    await run(context, () => widget.client.setRules(list), done: 'Rule changed');
    setState(() => _rules = widget.client.rules());
  }

  Future<void> _remove(List<Map<String, dynamic>> all, int i) async {
    final list = [...all]..removeAt(i);
    await run(context, () => widget.client.setRules(list));
    setState(() => _rules = widget.client.rules());
  }

  Future<void> _toggle(List<Map<String, dynamic>> all, int i, bool on) async {
    final list = [...all];
    list[i] = {...list[i], 'off': !on};
    await run(context, () => widget.client.setRules(list));
    setState(() => _rules = widget.client.rules());
  }

  /// Copies a rule to every other printer (skipping ones that have it).
  Future<void> _copyToAll(Map<String, dynamic> rule) async {
    final others = [
      for (final s in settings.strings('printers')) Printer.fromJson(jsonDecode(s)),
    ].map(clientFor).where((c) => c != widget.client).toList();
    if (others.isEmpty) return toast(context, 'You have only one printer');
    var copied = 0;
    await run(context, () async {
      for (final c in others) {
        final list = await c.rules();
        if (list.any((r) => r['on'] == rule['on'] && r['at'] == rule['at'] && r['do'] == rule['do'])) continue;
        await c.setRules([...list, rule]);
        copied++;
      }
    });
    if (mounted) toast(context, 'Copied to $copied printer${copied == 1 ? '' : 's'}');
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _rules,
        builder: (context, snap) {
          final rules = snap.data ?? const [];
          return Panel(
            title: 'Rules',
            icon: Icons.rule_rounded,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => _more(v, rules),
                itemBuilder: (_) => [
                  if (rules.isNotEmpty) const PopupMenuItem(value: 'off', child: Text('Turn every rule off (holiday)')),
                  if (rules.any((r) => r['off'] == true)) const PopupMenuItem(value: 'on', child: Text('Turn every rule on')),
                  if (rules.isNotEmpty) const PopupMenuItem(value: 'copy', child: Text('Copy rules as text')),
                  const PopupMenuItem(value: 'paste', child: Text('Paste rules…')),
                ],
              ),
              IconButton(tooltip: 'Snooze alerts', icon: const Icon(Icons.notifications_paused_outlined), onPressed: _snooze),
              IconButton(tooltip: 'Ready-made rules', icon: const Icon(Icons.auto_awesome_outlined), onPressed: _templates),
              IconButton(tooltip: 'Add rule', icon: const Icon(Icons.add_rounded), onPressed: _add),
            ]),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (rules.isEmpty)
                Text('Run something automatically, like "print finishes → light off". '
                    'Your home bridge runs rules, even with the app closed.',
                    style: TextStyle(color: C.muted)),
              for (final (i, r) in rules.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Switch(value: r['off'] != true, onChanged: (on) => _toggle(rules, i, on)),
                  title: Text(ruleText(r, _triggers)),
                  subtitle: Text('Long-press to change when it may run', style: T.caption.copyWith(color: C.muted)),
                  onLongPress: () => _window(rules, i),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Run it now',
                      icon: const Icon(Icons.play_circle_outline_rounded),
                      onPressed: () => _runNow(r),
                    ),
                    IconButton(
                      tooltip: 'Test (nothing is sent)',
                      icon: const Icon(Icons.science_outlined),
                      onPressed: () => _test(r),
                    ),
                    IconButton(
                      tooltip: 'Duplicate (then change its days or hours)',
                      icon: const Icon(Icons.control_point_duplicate_rounded),
                      onPressed: () async {
                        final list = [...rules, Map<String, dynamic>.from(r)..remove('off')];
                        await run(context, () => widget.client.setRules(list), done: 'Rule duplicated');
                        setState(() => _rules = widget.client.rules());
                      },
                    ),
                    IconButton(
                      tooltip: 'Copy to all printers',
                      icon: const Icon(Icons.copy_all_rounded),
                      onPressed: () => _copyToAll(r),
                    ),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => _remove(rules, i),
                    ),
                  ]),
                ),
            ]),
          );
        },
      );
}

/// Saved bed-mesh ranges over time (in Moonraker's database), to spot a bed
/// that's slowly warping or a loose screw.
class MeshHistory extends StatefulWidget {
  final MoonrakerClient client;
  final double range;
  final String profile;
  const MeshHistory({super.key, required this.client, required this.range, required this.profile});
  @override
  State<MeshHistory> createState() => _MeshHistoryState();
}

class _MeshHistoryState extends State<MeshHistory> {
  late Future<List<Map>> _list = _load();

  Future<List<Map>> _load() async =>
      List<Map>.from(((await widget.client.dbGet('meshes').catchError((_) => null)) as List?) ?? const []);

  Future<void> _save() async {
    final list = [
      ...await _list,
      {'at': DateTime.now().toIso8601String(), 'range': widget.range, 'profile': widget.profile},
    ];
    // ponytail: keep the last 20; plenty to see a trend.
    final kept = list.length > 20 ? list.sublist(list.length - 20) : list;
    if (!mounted) return;
    await run(context, () => widget.client.dbSet('meshes', kept), done: 'Mesh saved to history');
    setState(() => _list = _load());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map>>(
        future: _list,
        builder: (context, snap) {
          final list = (snap.data ?? const []).reversed.take(5).toList();
          final drift = list.isNotEmpty && meshDrifted((list.first['range'] as num).toDouble(), widget.range);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            if (drift)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, size: 18, color: C.warn),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('The bed is more uneven than the mesh you saved on '
                        '${fmtDate(DateTime.parse('${list.first['at']}'))}. Check the bed screws and that the plate sits flat.'),
                  ),
                ]),
              ),
            Row(children: [
              Text('History', style: TextStyle(color: C.muted, fontSize: 12)),
              const Spacer(),
              TextButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Save this mesh'),
              ),
            ]),
            for (final m in list)
              Builder(builder: (_) {
                final r = (m['range'] as num).toDouble();
                final d = widget.range - r;
                return Text(
                  '${fmtDate(DateTime.parse('${m['at']}'))}: range ${r.toStringAsFixed(3)} mm'
                  '${d.abs() < 0.0005 ? '' : ' (now ${d > 0 ? '+' : ''}${d.toStringAsFixed(3)})'}',
                  style: TextStyle(fontSize: 13, color: d > 0.05 ? C.warn : null),
                );
              }),
          ]);
        },
      );
}

/// Head (0-3) a U1 lane feeds: "E2" -> 2.
int laneHead(CfsSlot l) => int.tryParse(l.lane!.replaceAll(RegExp(r'\D'), '')) ?? 0;

/// Default head for each tool: the current map if that head holds the right
/// material, else the first loaded head with the same material and nearest
/// colour, else the current map.
Map<int, int> defaultHeads(List<ToolNeed> needs, List<CfsSlot> lanes, List<int> current) {
  int dist(int a, int b) {
    int c(int v, int s) => (v >> s) & 0xFF;
    return [16, 8, 0].fold(0, (t, s) => t + (c(a, s) - c(b, s)).abs());
  }

  final out = <int, int>{};
  for (final n in needs) {
    final now = n.tool < current.length ? current[n.tool] : n.tool;
    bool fits(CfsSlot l) => !l.empty && l.material.toUpperCase() == n.type.toUpperCase();
    final nowLane = lanes.where((l) => laneHead(l) == now).firstOrNull;
    if (nowLane != null && fits(nowLane)) {
      out[n.tool] = now;
      continue;
    }
    final ok = lanes.where(fits).toList()
      ..sort((a, b) => n.color == null ? 0 : dist(a.color!, n.color!).compareTo(dist(b.color!, n.color!)));
    out[n.tool] = ok.isEmpty ? now : laneHead(ok.first);
  }
  return out;
}

/// The U1's "Print configuration": pick the head for each filament and the
/// print preferences, then start. Replaces Snapmaker's cloud-only screen.
Future<bool> snapmakerPrintSetup(BuildContext context, MoonrakerClient c, String file, Map<String, dynamic> meta) async {
  final lanes = [
    for (final b in c.status.cfs)
      for (final s in b.slots)
        if (s.lane != null) s,
  ];
  final needs = toolNeeds(meta, lanes);
  final heads = defaultHeads(needs, lanes, await c.extruderMap().catchError((_) => <int>[]));
  var bed = settings.flag('u1.bedLevel', true), flow = settings.flag('u1.flow', false), lapse = settings.flag('u1.timelapse', false);
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Print setup'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(file.split('/').last, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (meta['estimated_time'] is num)
                Text('${fmtDuration(meta['estimated_time'] as num)} · ${meta['filament_weight_total'] ?? '?'} g',
                    style: TextStyle(color: C.muted)),
              if (needs.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text('Filaments', style: TextStyle(fontWeight: FontWeight.w700)),
                for (final n in needs)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      Container(
                        width: 86,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                            color: n.color == null ? C.surfaceHi : Color(n.color!),
                            borderRadius: BorderRadius.circular(R.sm)),
                        child: Column(children: [
                          Text(n.type, style: TextStyle(color: _onColor(n.color), fontWeight: FontWeight.w700)),
                          if (n.grams != null)
                            Text('${n.grams!.toStringAsFixed(1)} g', style: TextStyle(color: _onColor(n.color), fontSize: 12)),
                        ]),
                      ),
                      const Icon(Icons.arrow_right_alt_rounded),
                      Expanded(
                        child: DropdownButton<int>(
                          isExpanded: true,
                          value: heads[n.tool],
                          items: [
                            for (final l in lanes)
                              DropdownMenuItem(
                                value: laneHead(l),
                                child: Row(children: [
                                  CircleAvatar(radius: 10, backgroundColor: l.color == null ? C.border : Color(l.color!)),
                                  const SizedBox(width: 8),
                                  Text('${laneHead(l) + 1} · ${l.empty ? 'empty' : l.material}'),
                                  if (!l.empty && l.material.toUpperCase() != n.type.toUpperCase()) ...[
                                    const SizedBox(width: 6),
                                    const Icon(Icons.warning_amber_rounded, size: 16, color: C.warn),
                                  ],
                                ]),
                              ),
                          ],
                          onChanged: (h) => set(() => heads[n.tool] = h!),
                        ),
                      ),
                    ]),
                  ),
              ],
              const SizedBox(height: 14),
              const Text('Print preferences', style: TextStyle(fontWeight: FontWeight.w700)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto bed leveling'),
                value: bed,
                onChanged: (v) => set(() => bed = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Extrusion flow calibration'),
                value: flow,
                onChanged: (v) => set(() => flow = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Timelapse'),
                value: lapse,
                onChanged: (v) => set(() => lapse = v),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.print_rounded),
              label: const Text('Print')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted || !await preflight(context) || !context.mounted) return false;
  settings
    ..setFlag('u1.bedLevel', bed)
    ..setFlag('u1.flow', flow)
    ..setFlag('u1.timelapse', lapse);
  var started = false;
  await run(context, () async {
    await c.startSnapmakerPrint(file, heads, bedLevel: bed, flowCalibrate: flow, timelapse: lapse);
    started = true;
  }, done: 'Print started');
  return started;
}

Color _onColor(int? argb) {
  if (argb == null) return C.text;
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  return (0.299 * r + 0.587 * g + 0.114 * b) > 150 ? Colors.black : Colors.white;
}

/// The end of a printer log, newest at the top, with a search box.
class _LogPage extends StatefulWidget {
  final MoonrakerClient client;
  final String name;
  const _LogPage({required this.client, required this.name});
  @override
  State<_LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<_LogPage> {
  late Future<String> _text = widget.client.logTail(widget.name);
  String _find = '';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.name), actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() => _text = widget.client.logTail(widget.name)),
          ),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: const InputDecoration(isDense: true, hintText: 'Find (e.g. error, shutdown)', prefixIcon: Icon(Icons.search_rounded)),
              onChanged: (v) => setState(() => _find = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: FutureBuilder<String>(
              future: _text,
              builder: (_, snap) {
                if (snap.hasError) return StateView.error('${snap.error}');
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final lines = [
                  for (final l in snap.data!.split('\n').reversed)
                    if (l.trim().isNotEmpty && (_find.isEmpty || l.toLowerCase().contains(_find))) l,
                ];
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => SelectableText(lines[i],
                      style: mono.copyWith(
                          fontSize: 12,
                          color: RegExp('error|shutdown|exception', caseSensitive: false).hasMatch(lines[i]) ? C.ink(C.danger) : null)),
                );
              },
            ),
          ),
        ]),
      );
}
