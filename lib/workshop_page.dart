import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'insights.dart';
import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

/// Workshop: stats, records, maintenance log, parts, filament inventory and
/// notes for one printer. Everything here only reads the printer; nothing is
/// sent to it.
class WorkshopPage extends StatefulWidget {
  final MoonrakerClient client;
  final Printer printer;
  const WorkshopPage({super.key, required this.client, required this.printer});
  @override
  State<WorkshopPage> createState() => _WorkshopPageState();
}

class _WorkshopPageState extends State<WorkshopPage> {
  List<PrintJob>? _jobs;
  List<Spool>? _spools;
  String? _error;
  String get _k => widget.printer.key;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jobs = await widget.client.allHistory();
      List<Spool>? spools;
      try {
        if (await widget.client.hasSpoolman()) spools = await widget.client.spools();
      } catch (_) {}
      if (mounted) setState(() => (_jobs = jobs, _spools = spools, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Workshop · ${widget.printer.name}'),
            bottom: const TabBar(isScrollable: true, tabs: [
              Tab(text: 'Stats'),
              Tab(text: 'Maintenance'),
              Tab(text: 'Filament'),
              Tab(text: 'Notes'),
            ]),
          ),
          body: _error != null
              ? StateView.error(_error!, onRetry: _load)
              : _jobs == null
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(children: [
                      _list(_stats()),
                      _list(_maintenance()),
                      _list(_filament()),
                      _list(_notes()),
                    ]),
        ),
      );

  Widget _list(List<Widget> w) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [for (final (i, x) in w.indexed) ...[if (i > 0) const SizedBox(height: 12), Reveal(index: i, child: x)]],
        ),
      );

  Widget _row(String a, String b, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(a, overflow: TextOverflow.ellipsis)),
          Text(b, style: T.value.copyWith(fontSize: 14, color: color)),
        ]),
      );

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    toast(context, '$what copied');
  }

  // ------------------------------------------------------------ stats

  Map<String, String> get _reasons => {
        for (final e in (jsonDecode(settings.text('failReasons.$_k', '{}')) as Map).entries) '${e.key}': '${e.value}',
      };

  List<Widget> _stats() {
    final jobs = _jobs!;
    if (jobs.isEmpty) return [const StateView.empty(Icons.history_rounded, 'No prints yet.')];
    final r = records(jobs);
    final hours = jobs.fold(0.0, (a, j) => a + j.duration) / 3600;
    final grams = jobs.fold(0.0, (a, j) => a + gramsFromMm(j.filament, settings.number('filamentDensity', 1.24)));
    final cur = settings.text('currency', r'$');
    String pct(double v) => '${(v * 100).round()}%';
    final days = printsPerDay(jobs);
    final reasons = reasonBreakdown(_reasons);
    final costs = monthlyCost(jobs,
        pricePerKg: settings.number('filamentPrice', 20),
        watts: settings.number('printerWatts', 350),
        pricePerKwh: settings.number('kwhPrice', 0.30));
    return [
      Panel(
        title: 'Odometer',
        icon: Icons.speed_rounded,
        child: Wrap(spacing: 24, runSpacing: 12, children: [
          StatTile(label: 'Prints', value: '${jobs.length}'),
          StatTile(label: 'Print hours', value: hours.toStringAsFixed(0)),
          StatTile(label: 'Filament', value: '${(grams / 1000).toStringAsFixed(2)} kg'),
          StatTile(label: 'Success', value: pct(successRate(jobs))),
          StatTile(label: 'Print days', value: '${r.printDays}'),
          StatTile(label: 'Avg print', value: fmtDuration(hours * 3600 / jobs.length)),
          StatTile(label: 'Energy', value: '${(hours * settings.number('printerWatts', 350) / 1000).toStringAsFixed(0)} kWh'),
        ]),
      ),
      Panel(
        title: 'This month',
        icon: Icons.compare_arrows_rounded,
        child: Builder(builder: (_) {
          final (n, h, kg) = monthTotals(jobs);
          final (n0, h0, kg0) = monthTotals(jobs, offset: 1);
          String d(num a, num b, String unit, [int dp = 0]) =>
              '${a.toStringAsFixed(dp)}$unit${b == 0 ? '' : ' (${a >= b ? '+' : ''}${(a - b).toStringAsFixed(dp)} vs last month)'}';
          return Column(children: [
            _row('Prints', d(n, n0, '')),
            _row('Print hours', d(h, h0, ' h')),
            _row('Filament', d(kg, kg0, ' kg', 2)),
          ]);
        }),
      ),
      Panel(
        title: 'Records',
        icon: Icons.emoji_events_outlined,
        child: Column(children: [
          if (r.longest != null) _row('Longest: ${r.longest!.filename}', fmtDuration(r.longest!.duration)),
          if (r.heaviest != null)
            _row('Heaviest: ${r.heaviest!.filename}', '${gramsFromMm(r.heaviest!.filament).round()} g'),
          _row('Best run of good prints', '${r.bestStreak}'),
          _row('Current run', '${r.currentStreak}', color: r.currentStreak > 0 ? C.ink(C.accent) : null),
        ]),
      ),
      Panel(
        title: 'Last 12 weeks',
        icon: Icons.calendar_month_rounded,
        child: _Heatmap(days),
      ),
      Panel(
        title: 'When you print',
        icon: Icons.schedule_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Bars(labels: const ['M', 'T', 'W', 'T', 'F', 'S', 'S'], values: hoursByWeekday(jobs), unit: 'h'),
          const SizedBox(height: 12),
          Text('Starts by hour of day', style: T.caption.copyWith(color: C.muted)),
          const SizedBox(height: 4),
          _Bars(
              labels: [for (var h = 0; h < 24; h++) h % 6 == 0 ? '$h' : ''],
              values: [for (final n in startsByHour(jobs)) n.toDouble()],
              unit: ''),
        ]),
      ),
      Panel(
        title: 'Printed most',
        icon: Icons.repeat_rounded,
        child: Column(children: [for (final (n, c) in mostPrinted(jobs)) _row(n, '$c×')]),
      ),
      Panel(
        title: 'Success by material',
        icon: Icons.category_outlined,
        child: Column(children: [
          for (final (m, rate, n) in rateBy(jobs, (j) => j.material).take(8)) _row('$m · $n prints', pct(rate)),
        ]),
      ),
      Panel(
        title: 'Success by month',
        icon: Icons.bar_chart_rounded,
        child: Column(children: [
          for (final (m, rate, n) in (rateBy(jobs, (j) => monthKey(j.start))..sort((a, b) => b.$1.compareTo(a.$1))).take(6))
            _row('$m · $n prints', pct(rate)),
        ]),
      ),
      Panel(
        title: 'Cost per month',
        icon: Icons.payments_outlined,
        child: Column(children: [
          for (final (m, f, e) in costs.take(6))
            _row('$m  (filament $cur${f.toStringAsFixed(2)} + power $cur${e.toStringAsFixed(2)})',
                '$cur${(f + e).toStringAsFixed(2)}'),
        ]),
      ),
      Panel(
        title: 'Filament cost by material',
        icon: Icons.pie_chart_outline_rounded,
        child: Column(children: [
          for (final (m, c) in costByMaterial(jobs, settings.number('filamentPrice', 20)).take(8))
            _row(m, '$cur${c.toStringAsFixed(2)}'),
        ]),
      ),
      Panel(
        title: 'Why prints failed',
        icon: Icons.report_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (reasons.isEmpty) Hint('Tag failed prints below to see what goes wrong most.'),
          for (final (reason, n) in reasons) _row(reason, '$n'),
          const SizedBox(height: 8),
          for (final j in jobs.where((j) => !jobOk(j) && j.status != 'in_progress').take(15))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(j.filename, overflow: TextOverflow.ellipsis),
              subtitle: Text('${fmtDate(j.start)} · ${j.status}', style: T.caption.copyWith(color: C.muted)),
              trailing: DropdownButton<String>(
                value: _reasons[jobKey(j)],
                hint: const Text('Why?'),
                underline: const SizedBox(),
                items: [for (final r in failureReasons) DropdownMenuItem(value: r, child: Text(r))],
                onChanged: (v) {
                  final m = _reasons..[jobKey(j)] = v!;
                  settings.setText('failReasons.$_k', jsonEncode(m));
                  setState(() {});
                },
              ),
            ),
        ]),
      ),
      Panel(
        title: 'Export',
        icon: Icons.ios_share_rounded,
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: () => _copy(
                const JsonEncoder.withIndent(' ').convert([
                  for (final j in jobs)
                    {
                      'file': j.filename,
                      'status': j.status,
                      'start': j.start.toIso8601String(),
                      'seconds': j.duration.round(),
                      'filament_mm': j.filament.round(),
                      'material': j.material,
                      'reason': _reasons[jobKey(j)],
                      'note': settings.text('jobNote.$_k.${jobKey(j)}'),
                    },
                ]),
                'History JSON'),
            icon: const Icon(Icons.data_object_rounded),
            label: const Text('Copy history as JSON'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => _copy(
                '${widget.printer.name}: ${jobs.length} prints, ${hours.toStringAsFixed(0)} h, '
                '${(grams / 1000).toStringAsFixed(1)} kg of filament, ${pct(successRate(jobs))} success, '
                'best run ${r.bestStreak} good prints in a row.',
                'Stats'),
            icon: const Icon(Icons.short_text_rounded),
            label: const Text('Copy stats summary'),
          ),
        ]),
      ),
    ];
  }

  // ------------------------------------------------------------ maintenance

  String get _maintKey => 'maint.$_k';
  List<Map<String, dynamic>> get _log => settings.jsonList('maintLog.$_k');
  List<Map<String, dynamic>> get _parts => settings.jsonList('parts.$_k');

  List<Widget> _maintenance() {
    final jobs = _jobs!;
    final hours = jobs.fold(0.0, (a, j) => a + j.duration) / 3600;
    final due = dueTasks(settings.jsonList(_maintKey), hours);
    final nozzleSince = DateTime.fromMillisecondsSinceEpoch(settings.number('nozzleSince.$_k', 0).toInt());
    final wear = nozzleHours(jobs, nozzleSince);
    final nozzleLife = settings.number('nozzleLife', 500);
    return [
      Panel(
        title: 'Due now',
        icon: Icons.notification_important_outlined,
        child: due.isEmpty
            ? Hint('Nothing due. Reminders live in Tools → Maintenance.')
            : Column(children: [for (final d in due) _row(d, 'due', color: C.ink(C.warn))]),
      ),
      Panel(
        title: 'Ready-made tasks',
        icon: Icons.playlist_add_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Common reminders for this kind of printer. Adds any you don\'t have yet to Tools → Maintenance.',
              style: T.small.copyWith(color: C.muted)),
          const SizedBox(height: 8),
          for (final (name, every) in maintenanceTemplate(widget.printer.name)) _row(name, 'every ${every.round()} h'),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () {
              final have = settings.jsonList(_maintKey);
              final names = {for (final m in have) '${m['name']}'};
              settings.setJsonList(_maintKey, [
                ...have,
                for (final (name, every) in maintenanceTemplate(widget.printer.name))
                  if (!names.contains(name)) {'name': name, 'hours': every, 'since': hours},
              ]);
              toast(context, 'Added to Maintenance');
              setState(() {});
            },
            child: const Text('Add these reminders'),
          ),
        ]),
      ),
      Panel(
        title: 'Nozzle wear',
        icon: Icons.hardware_outlined,
        trailing: TextButton(
          onPressed: () async {
            if (!await confirm(context, 'New nozzle fitted?', message: 'Starts the wear count from now.', action: 'Yes')) return;
            settings.setNumber('nozzleSince.$_k', DateTime.now().millisecondsSinceEpoch.toDouble());
            _addLog('Fitted a new nozzle');
          },
          child: const Text('New nozzle'),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _row('Wear hours (CF / GF count ×3, PA / PC ×1.5)', '${wear.toStringAsFixed(0)} / ${nozzleLife.round()} h',
              color: wear >= nozzleLife ? C.ink(C.danger) : null),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (wear / nozzleLife).clamp(0, 1).toDouble(),
              color: wear >= nozzleLife ? C.danger : C.accent,
            ),
          ),
          if (nozzleSince.millisecondsSinceEpoch == 0)
            Padding(padding: const EdgeInsets.only(top: 8), child: Hint('Counting from the first print. Tap New nozzle when you change it.')),
        ]),
      ),
      Panel(
        title: 'Maintenance log',
        icon: Icons.history_edu_rounded,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (_log.isNotEmpty)
            IconButton(
              tooltip: 'Copy the log',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => _copy(
                  [for (final e in _log) '${fmtDate(DateTime.fromMillisecondsSinceEpoch(e['at'] as int))}  ${e['text']}'].join('\n'),
                  'Maintenance log'),
            ),
          IconButton(
            tooltip: 'Log maintenance',
            icon: const Icon(Icons.add_rounded),
            onPressed: () async {
              final t = await askText(context, 'What did you do?', hint: 'e.g. Lubricated Z rods', action: 'Log');
              if (t != null && t.trim().isNotEmpty) _addLog(t.trim());
            },
          ),
        ]),
        child: _log.isEmpty
            ? Hint('Log what you fix or clean, with the date.')
            : Column(children: [
                for (final (i, e) in _log.reversed.indexed.take(30))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${e['text']}'),
                    subtitle: Text(fmtDate(DateTime.fromMillisecondsSinceEpoch(e['at'] as int)),
                        style: T.caption.copyWith(color: C.muted)),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        final l = _log..removeAt(_log.length - 1 - i);
                        settings.setJsonList('maintLog.$_k', l);
                        setState(() {});
                      },
                    ),
                  ),
              ]),
      ),
      Panel(
        title: 'Spare parts',
        icon: Icons.inventory_2_outlined,
        trailing: IconButton(
          tooltip: 'Add part',
          icon: const Icon(Icons.add_rounded),
          onPressed: () async {
            final name = await askText(context, 'Spare part', hint: 'e.g. 0.4 mm nozzle', action: 'Next');
            if (name == null || name.trim().isEmpty || !mounted) return;
            final n = await askNumber(context, 'How many?', presets: const [1, 2, 5, 10], unit: '');
            if (n == null) return;
            settings.setJsonList('parts.$_k', [..._parts, {'name': name.trim(), 'n': n, 'low': 1}]);
            setState(() {});
          },
        ),
        child: _parts.isEmpty
            ? Hint('Keep count of spare nozzles, PTFE tube, hotends and so on.')
            : Column(children: [
                for (final (i, p) in _parts.indexed)
                  Row(children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final n = await askNumber(context, 'Warn when ${p['name']} is down to', presets: const [0, 1, 2, 5], unit: '');
                          if (n == null) return;
                          final l = _parts;
                          l[i] = {...l[i], 'low': n};
                          settings.setJsonList('parts.$_k', l);
                          setState(() {});
                        },
                        child: Text('${p['name']}  ·  warn at ${p['low'] ?? 1}', style: T.small),
                      ),
                    ),
                    if ((p['n'] as int) <= (p['low'] as int? ?? 1))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text('low', style: T.label.copyWith(color: C.ink(C.warn))),
                      ),
                    IconButton(
                        tooltip: 'One fewer',
                        icon: const Icon(Icons.remove_rounded, size: 18),
                        onPressed: () => _setPart(i, (p['n'] as int) - 1)),
                    Text('${p['n']}', style: T.value),
                    IconButton(
                        tooltip: 'One more',
                        icon: const Icon(Icons.add_rounded, size: 18),
                        onPressed: () => _setPart(i, (p['n'] as int) + 1)),
                  ]),
              ]),
      ),
    ];
  }

  void _setPart(int i, int n) {
    final p = _parts;
    if (n < 0) {
      p.removeAt(i);
    } else {
      p[i] = {...p[i], 'n': n};
    }
    settings.setJsonList('parts.$_k', p);
    setState(() {});
  }

  void _addLog(String text) {
    settings.setJsonList('maintLog.$_k', [..._log, {'text': text, 'at': DateTime.now().millisecondsSinceEpoch}]);
    setState(() {});
  }

  // ------------------------------------------------------------ filament

  List<Map<String, dynamic>> get _localSpools => settings.jsonList('localSpools');

  List<Widget> _filament() {
    final spools = _spools ??
        [
          for (final (i, s) in _localSpools.indexed)
            Spool(-1 - i, '${s['name']}', '${s['material']}', s['color'] as int?, (s['grams'] as num).toDouble(),
                (s['price'] as num?)?.toDouble()),
        ];
    final cur = settings.text('currency', r'$');
    final list = shoppingList(spools, limit: settings.number('shopLimit', 200));
    return [
      Panel(
        title: 'Inventory',
        icon: Icons.warehouse_outlined,
        trailing: _spools == null
            ? IconButton(tooltip: 'Add spool', icon: const Icon(Icons.add_rounded), onPressed: _addLocalSpool)
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_spools == null)
            Hint('No Spoolman on this printer, so these spools are kept on this device.'),
          if (spools.isEmpty) Text('No spools yet.', style: TextStyle(color: C.muted)),
          for (final (m, g, n) in inventory(spools)) _row('$m · $n spools', '${(g / 1000).toStringAsFixed(2)} kg'),
          if (daysOfFilament(spools.fold(0.0, (a, s) => a + (s.remaining ?? 0)), _jobs!) case final d?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Hint('At the last 30 days\' pace this lasts about ${d.round()} days.'),
            ),
          const Divider(height: 24),
          for (final s in spools)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(
                radius: 10,
                backgroundColor: s.color == null ? C.surfaceHi : Color(s.color! | 0xFF000000),
              ),
              title: Text('${s.material} ${s.name}'.trim()),
              subtitle: Text(
                [
                  if (s.color != null) colorName(s.color!),
                  if (pricePerGram(s) != null) '$cur${pricePerGram(s)!.toStringAsFixed(3)}/g',
                ].join(' · '),
                style: T.caption.copyWith(color: C.muted),
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${(s.remaining ?? 0).round()} g', style: T.value.copyWith(fontSize: 14)),
                if (s.id < 0)
                  IconButton(
                    tooltip: 'Set grams left',
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    onPressed: () async {
                      final g = await askNumber(context, 'Grams left', unit: ' g');
                      if (g == null) return;
                      final l = _localSpools;
                      l[-1 - s.id] = {...l[-1 - s.id], 'grams': g};
                      settings.setJsonList('localSpools', l);
                      setState(() {});
                    },
                  ),
              ]),
              onLongPress: () => _logDrying(s),
            ),
        ]),
      ),
      Panel(
        title: 'Shopping list',
        icon: Icons.shopping_cart_outlined,
        trailing: list.isEmpty ? null : TextButton(onPressed: () => _copy(list, 'Shopping list'), child: const Text('Copy')),
        child: Text(list.isEmpty ? 'Every spool has more than ${settings.number('shopLimit', 200).round()} g.' : list,
            style: T.small.copyWith(color: list.isEmpty ? C.muted : C.text)),
      ),
      Panel(
        title: 'Drying guide',
        icon: Icons.local_fire_department_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (m, t, h) in dryPresets) _row(m, '$t°C · $h h'),
          const SizedBox(height: 8),
          Hint('Long-press a spool above to log that you dried it.'),
        ]),
      ),
      Panel(
        title: 'Drying log',
        icon: Icons.water_drop_outlined,
        child: settings.jsonList('dryLog').isEmpty
            ? Text('Nothing dried yet.', style: TextStyle(color: C.muted))
            : Column(children: [
                for (final e in settings.jsonList('dryLog').reversed.take(20))
                  _row('${e['spool']}', fmtDate(DateTime.fromMillisecondsSinceEpoch(e['at'] as int))),
              ]),
      ),
      Panel(
        title: 'Material notes',
        icon: Icons.sticky_note_2_outlined,
        trailing: IconButton(
          tooltip: 'Add note',
          icon: const Icon(Icons.add_rounded),
          onPressed: () async {
            final m = await askText(context, 'Material or brand', hint: 'e.g. eSun PETG', action: 'Next');
            if (m == null || m.trim().isEmpty || !mounted) return;
            final t = await askText(context, 'Note for ${m.trim()}', hint: '235°C, bed 80°C, slow first layer', action: 'Save');
            if (t == null) return;
            settings.setJsonList('materialNotes', [...settings.jsonList('materialNotes'), {'m': m.trim(), 't': t}]);
            setState(() {});
          },
        ),
        child: settings.jsonList('materialNotes').isEmpty
            ? Hint('Keep the temperatures and tips that work for each brand.')
            : Column(children: [
                for (final (i, n) in settings.jsonList('materialNotes').indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${n['m']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${n['t']}'),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        settings.setJsonList('materialNotes', settings.jsonList('materialNotes')..removeAt(i));
                        setState(() {});
                      },
                    ),
                  ),
              ]),
      ),
    ];
  }

  Future<void> _addLocalSpool() async {
    final m = await askText(context, 'Material', hint: 'PLA', action: 'Next');
    if (m == null || m.trim().isEmpty || !mounted) return;
    final name = await askText(context, 'Brand and colour', hint: 'Sunlu red', action: 'Next');
    if (name == null || !mounted) return;
    final g = await askNumber(context, 'Grams on the spool', presets: const [250, 500, 1000], unit: ' g');
    if (g == null) return;
    settings.setJsonList('localSpools', [..._localSpools, {'material': m.trim().toUpperCase(), 'name': name.trim(), 'grams': g}]);
    setState(() {});
  }

  void _logDrying(Spool s) {
    settings.setJsonList('dryLog', [
      ...settings.jsonList('dryLog'),
      {'spool': '${s.material} ${s.name}'.trim(), 'at': DateTime.now().millisecondsSinceEpoch},
    ]);
    toast(context, 'Logged drying for ${s.material} ${s.name}');
    setState(() {});
  }

  // ------------------------------------------------------------ notes

  List<Widget> _notes() {
    final jobs = _jobs!.take(30).toList();
    final checklist = settings.strings('checklist');
    return [
      Panel(
        title: 'Pre-print checklist',
        icon: Icons.checklist_rounded,
        trailing: IconButton(
          tooltip: 'Add item',
          icon: const Icon(Icons.add_rounded),
          onPressed: () async {
            final t = await askText(context, 'Checklist item', hint: 'e.g. Plate is clean', action: 'Add');
            if (t == null || t.trim().isEmpty) return;
            settings.setStrings('checklist', [...checklist, t.trim()]);
            setState(() {});
          },
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show before every print'),
            value: settings.flag('checklistOn', false),
            onChanged: (v) => setState(() => settings.setFlag('checklistOn', v)),
          ),
          for (final (i, t) in checklist.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.check_box_outline_blank_rounded, size: 18),
              title: Text(t),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  settings.setStrings('checklist', [...checklist]..removeAt(i));
                  setState(() {});
                },
              ),
            ),
          if (checklist.isEmpty) Hint('e.g. "Plate is clean", "Glue on for PETG", "Spool has enough left".'),
        ]),
      ),
      Panel(
        title: 'Print notes',
        icon: Icons.edit_note_rounded,
        child: Column(children: [
          for (final j in jobs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(j.filename, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                settings.text('jobNote.$_k.${jobKey(j)}').isEmpty
                    ? '${fmtDate(j.start)} · tap to add a note'
                    : settings.text('jobNote.$_k.${jobKey(j)}'),
                style: T.caption.copyWith(color: C.muted),
              ),
              onTap: () async {
                final t = await askText(context, 'Note', initial: settings.text('jobNote.$_k.${jobKey(j)}'), action: 'Save');
                if (t == null) return;
                settings.setText('jobNote.$_k.${jobKey(j)}', t);
                setState(() {});
              },
            ),
        ]),
      ),
    ];
  }
}

/// 12 weeks of print days, one square per day, darker = more prints.
class _Heatmap extends StatelessWidget {
  final List<int> days;
  const _Heatmap(this.days);
  @override
  Widget build(BuildContext context) {
    final most = days.fold(1, (a, b) => b > a ? b : a);
    final total = days.fold(0, (a, b) => a + b);
    return Semantics(
      label: '$total prints in the last ${days.length} days',
      child: Wrap(spacing: 3, runSpacing: 3, children: [
        for (final n in days)
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: n == 0 ? C.surfaceHi : C.accent.withValues(alpha: 0.25 + 0.75 * n / most),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ]),
    );
  }
}

/// The pre-print checklist from Workshop → Notes, when it's switched on.
/// True when every item is ticked (or there's no checklist).
Future<bool> preflight(BuildContext context) async {
  final items = settings.strings('checklist');
  if (!settings.flag('checklistOn', false) || items.isEmpty) return true;
  final ticked = <int>{};
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Before you print'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (i, t) in items.indexed)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t),
              value: ticked.contains(i),
              onChanged: (v) => set(() => v! ? ticked.add(i) : ticked.remove(i)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: ticked.length == items.length ? () => Navigator.pop(ctx, true) : null,
            child: const Text('All good'),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}

/// Simple labelled bars (no axes), tallest = full height.
class _Bars extends StatelessWidget {
  final List<String> labels;
  final List<double> values;
  final String unit;
  const _Bars({required this.labels, required this.values, required this.unit});
  @override
  Widget build(BuildContext context) {
    final most = values.fold(0.0, (a, b) => b > a ? b : a);
    return Semantics(
      label: [for (var i = 0; i < values.length; i++) if (labels[i].isNotEmpty) '${labels[i]} ${values[i].round()}$unit'].join(', '),
      child: SizedBox(
        height: 72,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Container(
                    height: most == 0 ? 2 : 2 + 52 * values[i] / most,
                    decoration: BoxDecoration(color: C.accent.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(3)),
                  ),
                  const SizedBox(height: 4),
                  Text(labels[i], style: T.caption.copyWith(color: C.muted)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Every printer's history side by side, and all of them together.
class FleetPage extends StatefulWidget {
  final List<Printer> printers;
  const FleetPage({super.key, required this.printers});
  @override
  State<FleetPage> createState() => _FleetPageState();
}

class _FleetPageState extends State<FleetPage> {
  late final Future<List<(Printer, List<PrintJob>?)>> _data = Future.wait([
    for (final p in widget.printers)
      clientFor(p).allHistory().then<(Printer, List<PrintJob>?)>((j) => (p, j)).catchError((_) => (p, null)),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('All printers')),
        body: FutureBuilder<List<(Printer, List<PrintJob>?)>>(
          future: _data,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            final all = [for (final (_, j) in rows) ...?j];
            String h(List<PrintJob> j) => (j.fold(0.0, (a, x) => a + x.duration) / 3600).toStringAsFixed(0);
            String kg(List<PrintJob> j) => (j.fold(0.0, (a, x) => a + gramsFromMm(x.filament)) / 1000).toStringAsFixed(2);
            return ListView(padding: const EdgeInsets.all(16), children: [
              Panel(
                title: 'Together',
                icon: Icons.groups_2_outlined,
                child: Wrap(spacing: 24, runSpacing: 12, children: [
                  StatTile(label: 'Prints', value: '${all.length}'),
                  StatTile(label: 'Print hours', value: h(all)),
                  StatTile(label: 'Filament', value: '${kg(all)} kg'),
                  StatTile(label: 'Success', value: '${(successRate(all) * 100).round()}%'),
                ]),
              ),
              const SizedBox(height: 12),
              for (final (p, j) in rows) ...[
                Panel(
                  title: p.name,
                  icon: Icons.print_rounded,
                  child: j == null
                      ? Text('Not reachable right now.', style: TextStyle(color: C.muted))
                      : Wrap(spacing: 24, runSpacing: 12, children: [
                          StatTile(label: 'Prints', value: '${j.length}'),
                          StatTile(label: 'Print hours', value: h(j)),
                          StatTile(label: 'Filament', value: '${kg(j)} kg'),
                          StatTile(label: 'Success', value: '${(successRate(j) * 100).round()}%'),
                          StatTile(label: 'Share of hours', value: all.isEmpty ? '—' : '${(double.parse(h(j)) * 100 / (double.parse(h(all)) == 0 ? 1 : double.parse(h(all)))).round()}%'),
                        ]),
                ),
                const SizedBox(height: 12),
              ],
            ]);
          },
        ),
      );
}
