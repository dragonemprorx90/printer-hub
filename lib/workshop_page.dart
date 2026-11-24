import 'dart:convert';

import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  final int initialTab; // 0 Stats, 1 Maintenance, 2 Filament, 3 Notes, 4 Quote, 5 Calculators
  const WorkshopPage({super.key, required this.client, required this.printer, this.initialTab = 0});
  @override
  State<WorkshopPage> createState() => _WorkshopPageState();
}

class _WorkshopPageState extends State<WorkshopPage> {
  List<PrintJob>? _jobs;
  List<Spool>? _spools;
  String? _error;
  String get _k => widget.printer.key;
  String _noteFind = '';

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
        length: 6,
        initialIndex: widget.initialTab,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Workshop · ${widget.printer.name}'),
            bottom: const TabBar(isScrollable: true, tabs: [
              Tab(text: 'Stats'),
              Tab(text: 'Maintenance'),
              Tab(text: 'Filament'),
              Tab(text: 'Notes'),
              Tab(text: 'Quote'),
              Tab(text: 'Calculators'),
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
                      _QuoteTab(client: widget.client),
                      const _CalcTab(),
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
          const SizedBox(width: 12),
          // Long values (costs with a breakdown, "in about 12 days") get the
          // room they need but never push the row off a phone screen.
          Flexible(
            child: Text(b,
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: T.value.copyWith(fontSize: 14, color: color)),
          ),
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
      RepaintBoundary(
        key: _cardKey,
        child: Panel(
        title: '${widget.printer.name} · odometer',
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
      )),
      Panel(
        title: 'This month',
        icon: Icons.compare_arrows_rounded,
        child: Builder(builder: (_) {
          final (n, h, kg) = monthTotals(jobs);
          final (n0, h0, kg0) = monthTotals(jobs, offset: 1);
          String d(num a, num b, String unit, [int dp = 0]) =>
              '${a.toStringAsFixed(dp)}$unit${b == 0 ? '' : ' (${a >= b ? '+' : ''}${(a - b).toStringAsFixed(dp)} vs last month)'}';
          final (wn, wh) = weekTotals(jobs);
          final (wn0, wh0) = weekTotals(jobs, offset: 1);
          return Column(children: [
            _row('Prints this week', '$wn${wn0 == 0 ? '' : ' (${wn >= wn0 ? '+' : ''}${wn - wn0} vs last week)'}'),
            _row('Hours this week', '${wh.toStringAsFixed(0)} h${wh0 == 0 ? '' : ' (last week ${wh0.toStringAsFixed(0)} h)'}'),
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
          if (bestDay(jobs) case (final d, final n)) _row('Busiest day: ${fmtDate(d)}', '$n prints'),
          _row('Success of the last 10', pct(recentSuccess(jobs))),
          if (estimateRatio(jobs) case final r?)
            _row('Slicer estimates', r >= 1 ? '${((r - 1) * 100).round()}% short of real time' : '${((1 - r) * 100).round()}% longer than real time'),
          _row('Current run', '${r.currentStreak}', color: r.currentStreak > 0 ? C.ink(C.accent) : null),
        ]),
      ),
      Panel(
        title: 'Last 7 days',
        icon: Icons.view_day_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var d = 0; d < 7; d++)
            Builder(builder: (_) {
              final day = DateTime.now().subtract(Duration(days: d));
              final mine = [for (final j in jobs) if (dayKey(j.start) == dayKey(day)) j];
              return _row(
                  d == 0 ? 'Today' : d == 1 ? 'Yesterday' : fmtDate(day),
                  mine.isEmpty
                      ? '—'
                      : '${mine.length} · ${fmtDuration(mine.fold<double>(0, (a, j) => a + j.duration))}'
                          '${mine.any((j) => !jobOk(j) && j.status != 'in_progress') ? ' · ${mine.where((j) => !jobOk(j) && j.status != 'in_progress').length} not finished' : ''}');
            }),
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
          for (final (m, rate, n) in rateBy(jobs, (j) => j.material).take(8))
            _row('$m · $n prints · avg ${fmtDuration([for (final j in jobs) if ((j.material ?? 'Unknown') == m) j.duration].fold(0.0, (a, b) => a + b) / n)}',
                pct(rate)),
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
        title: 'Monthly budget',
        icon: Icons.savings_outlined,
        trailing: TextButton(
          onPressed: () async {
            final b = await askNumber(context, 'Spend at most per month', presets: const [10, 25, 50, 100], unit: ' $cur');
            if (b == null) return;
            settings.setNumber('budget', b.toDouble());
            setState(() {});
          },
          child: Text(settings.number('budget', 0) > 0 ? 'Change' : 'Set'),
        ),
        child: Builder(builder: (_) {
          final budget = settings.number('budget', 0);
          final now = costs.where((c) => c.$1 == monthKey(DateTime.now())).firstOrNull;
          final spent = now == null ? 0.0 : now.$2 + now.$3;
          if (budget <= 0) return Hint('Set a monthly budget to see how this month is going (${widget.printer.name} only).');
          final f = spent / budget;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _row('This month', '$cur${spent.toStringAsFixed(2)} of $cur${budget.toStringAsFixed(0)}',
                color: f >= 1 ? C.ink(C.danger) : f >= 0.8 ? C.ink(C.warn) : null),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: f.clamp(0, 1).toDouble(), color: f >= 1 ? C.danger : f >= 0.8 ? C.warn : C.accent),
            ),
          ]);
        }),
      ),
      Panel(
        title: 'Filament cost by material',
        icon: Icons.pie_chart_outline_rounded,
        child: Column(children: [
          for (final (m, c) in costByMaterial(jobs, settings.pricePerKg).take(8))
            _row(m, '$cur${c.toStringAsFixed(2)}'),
        ]),
      ),
      Panel(
        title: 'First layers',
        icon: Icons.photo_library_outlined,
        trailing: TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _FirstLayers(client: widget.client, jobs: jobs))),
          child: const Text('Compare'),
        ),
        child: Hint('Your home bridge saves a picture after the first layer. Compare the last prints side by side.'),
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
            onPressed: _saveCard,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Save the odometer as a picture'),
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

  final _cardKey = GlobalKey();

  /// The odometer panel as a PNG, to share.
  Future<void> _saveCard() async {
    final b = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    try {
      final img = await b.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return;
      final saved = await FilePicker.saveFile(
          fileName: '${widget.printer.name.replaceAll(RegExp(r'[^\w-]+'), '_')}-stats.png', bytes: png.buffer.asUint8List());
      if (saved != null && mounted) toast(context, 'Picture saved');
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e', error: true);
    }
  }

  // ------------------------------------------------------------ maintenance

  String get _maintKey => 'maint.$_k';
  List<Map<String, dynamic>> get _log => settings.jsonList('maintLog.$_k');
  List<Map<String, dynamic>> get _parts => settings.jsonList('parts.$_k');

  List<Widget> _maintenance() {
    final jobs = _jobs!;
    final hours = jobs.fold(0.0, (a, j) => a + j.duration) / 3600;
    final due = dueTasks(settings.jsonList(_maintKey), hours);
    final perDay = hoursPerDay(jobs);
    final upcoming = [
      for (final m in settings.jsonList(_maintKey))
        if ((m['hours'] as num) > 0)
          ('${m['name']}', daysUntil((m['hours'] as num) - (hours - (m['since'] as num)), perDay)),
    ]..sort((a, b) => (a.$2 ?? 1e9).compareTo(b.$2 ?? 1e9));
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
        title: 'Coming up',
        icon: Icons.event_outlined,
        child: perDay <= 0
            ? Hint('Shows when each reminder falls due once you have printed in the last 30 days.')
            : Column(children: [
                for (final (name, d) in upcoming.take(6))
                  _row(name, d == null ? '—' : d < 1 ? 'now' : 'in about ${d.round()} days'),
                _row('Your pace', '${perDay.toStringAsFixed(1)} print hours a day'),
              ]),
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
          if (daysUntil(nozzleLife - wear, perDay) case final d? when wear < nozzleLife)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('At your pace, about ${d.round()} days left on this nozzle.', style: T.small.copyWith(color: C.muted)),
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
    final lowParts = [
      for (final part in _parts)
        if ((part['n'] as int) <= (part['low'] as int? ?? 1)) '- ${part['name']} (${part['n']} left)',
    ];
    final spoolList = shoppingList(spools, limit: settings.number('shopLimit', 200));
    final list = [
      if (spoolList.isNotEmpty) spoolList,
      if (lowParts.isNotEmpty) ['Spare parts to buy:', ...lowParts].join('\n'),
    ].join('\n\n');
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
                  if (s.id < 0 && settings.number('localSpool.$_k', -1).round() == -1 - s.id) 'in use',
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
              onLongPress: () => _spoolMenu(s),
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
          Hint('Long-press a spool above to log that you dried it (or, without Spoolman, to say it\'s in use).'),
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
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (settings.jsonList('materialNotes').isNotEmpty)
            IconButton(
              tooltip: 'Copy all notes',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => _copy([for (final n in settings.jsonList('materialNotes')) '${n['m']}: ${n['t']}'].join('\n'), 'Notes'),
            ),
          IconButton(
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
        ]),
        child: settings.jsonList('materialNotes').isEmpty
            ? Hint('Keep the temperatures and tips that work for each brand.')
            : Column(children: [
                for (final (i, n) in settings.jsonList('materialNotes').indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${n['m']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${n['t']}'),
                    onTap: () async {
                      final t = await askText(context, 'Note for ${n['m']}', initial: '${n['t']}', action: 'Save');
                      if (t == null) return;
                      final l = settings.jsonList('materialNotes');
                      l[i] = {...l[i], 't': t};
                      settings.setJsonList('materialNotes', l);
                      setState(() {});
                    },
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

  Future<void> _spoolMenu(Spool s) async {
    final local = s.id < 0;
    final inUse = local && settings.number('localSpool.$_k', -1).round() == -1 - s.id;
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('${s.material} ${s.name}'.trim())),
          ListTile(leading: const Icon(Icons.water_drop_outlined), title: const Text('Log that I dried it'), onTap: () => Navigator.pop(ctx, 'dry')),
          if (local)
            ListTile(
              leading: Icon(inUse ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(inUse ? 'Stop using it on ${widget.printer.name}' : 'In use on ${widget.printer.name}'),
              subtitle: const Text('Each print\'s filament comes off it'),
              onTap: () => Navigator.pop(ctx, 'use'),
            ),
          if (local)
            ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Remove'), onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick == 'dry') return _logDrying(s);
    if (pick == 'use') {
      settings.setNumber('localSpool.$_k', inUse ? -1 : (-1 - s.id).toDouble());
    } else if (pick == 'remove') {
      if (!await confirm(context, 'Remove this spool?', action: 'Remove', danger: true) || !mounted) return;
      settings.setJsonList('localSpools', _localSpools..removeAt(-1 - s.id));
      settings.setNumber('localSpool.$_k', -1);
    }
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
    final find = _noteFind.toLowerCase();
    final jobs = [
      for (final j in _jobs!.take(find.isEmpty ? 30 : 500))
        if (find.isEmpty ||
            j.filename.toLowerCase().contains(find) ||
            settings.text('jobNote.$_k.${jobKey(j)}').toLowerCase().contains(find))
          j,
    ];
    final checklist = settings.strings('checklist');
    return [
      Panel(
        title: 'Pinned note',
        icon: Icons.push_pin_outlined,
        trailing: TextButton(
          onPressed: () async {
            final t = await askText(context, 'Note pinned to ${widget.printer.name}',
                initial: settings.text('pinNote.$_k'), hint: 'e.g. 0.6 mm nozzle fitted', action: 'Pin');
            if (t == null) return;
            settings.setText('pinNote.$_k', t.trim());
            setState(() {});
          },
          child: Text(settings.text('pinNote.$_k').isEmpty ? 'Add' : 'Change'),
        ),
        child: Text(settings.text('pinNote.$_k').isEmpty ? 'Shows at the top of the Overview.' : settings.text('pinNote.$_k'),
            style: T.small.copyWith(color: settings.text('pinNote.$_k').isEmpty ? C.muted : C.text)),
      ),
      TextField(
        decoration: const InputDecoration(isDense: true, hintText: 'Search notes and prints', prefixIcon: Icon(Icons.search_rounded)),
        onChanged: (v) => setState(() => _noteFind = v),
      ),
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
  late final Future<List<(Printer, List<QueuedJob>)>> _queues = Future.wait([
    for (final p in widget.printers)
      clientFor(p).queue().then<(Printer, List<QueuedJob>)>((q) => (p, q.$1)).catchError((_) => (p, <QueuedJob>[])),
  ]);

  /// Slicer estimates for queued files, for finish times.
  final _est = <String, double?>{};

  Future<void> _estimates(Printer p, List<QueuedJob> jobs) async {
    for (final j in jobs.take(10)) {
      final k = '${p.key}|${j.filename}';
      if (_est.containsKey(k)) continue;
      _est[k] = null;
      final m = await clientFor(p).metadata(j.filename).catchError((_) => <String, dynamic>{});
      if (mounted) setState(() => _est[k] = (m['estimated_time'] as num?)?.toDouble());
    }
  }

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
              FutureBuilder<List<(Printer, List<QueuedJob>)>>(
                future: _queues,
                builder: (context, q) {
                  final qs = [for (final (p, jobs) in q.data ?? const <(Printer, List<QueuedJob>)>[]) if (jobs.isNotEmpty) (p, jobs)];
                  if (qs.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Panel(
                      title: 'Queues',
                      icon: Icons.queue_rounded,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final (p, jobs) in qs) ...[
                          Builder(builder: (_) {
                            _estimates(p, jobs);
                            return const SizedBox.shrink();
                          }),
                          Text('${p.name} · ${jobs.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          for (final (i, j) in jobs.take(10).indexed)
                            Builder(builder: (_) {
                              final st = clientFor(p).status;
                              final times = queueFinishTimes([
                                for (final x in jobs.take(10))
                                  if (_est['${p.key}|${x.filename}'] case final e?) e * st.etaFactor else null,
                              ],
                                  from: DateTime.now(), currentLeft: st.state == 'printing' ? (st.eta ?? 0) : 0);
                              final known = _est['${p.key}|${j.filename}'] != null;
                              return Text('  ${j.filename.split('/').last}${known ? ' · done ${fmtTime(times[i])}' : ''}',
                                  style: T.small.copyWith(color: C.muted), overflow: TextOverflow.ellipsis);
                            }),
                          const SizedBox(height: 8),
                        ],
                      ]),
                    ),
                  );
                },
              ),
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

/// What to charge for a print: pick a file (or type the grams and hours),
/// then add machine wear, your time and a markup.
class _QuoteTab extends StatefulWidget {
  final MoonrakerClient client;
  const _QuoteTab({required this.client});
  @override
  State<_QuoteTab> createState() => _QuoteTabState();
}

class _QuoteTabState extends State<_QuoteTab> {
  double _grams = 50, _hours = 2;
  String? _file;

  double _n(String k, double d) => settings.number('quote.$k', d);

  Future<void> _pickFile() async {
    final files = await widget.client.listFiles().catchError((_) => <GcodeFile>[]);
    if (!mounted || files.isEmpty) return;
    final f = await showModalBottomSheet<GcodeFile>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(children: [
          for (final f in files..sort((a, b) => b.modified.compareTo(a.modified)))
            ListTile(title: Text(f.name), onTap: () => Navigator.pop(ctx, f)),
        ]),
      ),
    );
    if (f == null) return;
    final m = await widget.client.metadata(f.path).catchError((_) => <String, dynamic>{});
    if (!mounted) return;
    setState(() {
      _file = f.name;
      _hours = ((m['estimated_time'] as num?) ?? _hours * 3600) / 3600;
      _grams = (m['filament_weight_total'] as num?)?.toDouble() ??
          (m['filament_total'] is num ? gramsFromMm((m['filament_total'] as num).toDouble()) : _grams);
    });
  }

  Widget _field(String label, double value, ValueChanged<double> set, {String suffix = ''}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextFormField(
          key: ValueKey('$label $value'),
          initialValue: value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
          onFieldSubmitted: (v) => setState(() => set(double.tryParse(v.replaceAll(',', '.')) ?? value)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cur = settings.text('currency', r'$');
    final q = quote(
      grams: _grams,
      hours: _hours,
      pricePerKg: settings.number('filamentPrice', 20),
      watts: settings.number('printerWatts', 350),
      pricePerKwh: settings.number('kwhPrice', 0.30),
      wearPerHour: _n('wear', 0.2),
      labour: _n('labour', 0),
      markupPct: _n('markup', 30),
    );
    String m(double v) => '$cur${v.toStringAsFixed(2)}';
    final text = '${_file ?? 'Print'}: ${_grams.round()} g, ${fmtDuration(_hours * 3600)}. Price ${m(q.$5)}.';
    return ListView(padding: const EdgeInsets.all(16), children: [
      Panel(
        title: 'The print',
        icon: Icons.description_outlined,
        trailing: TextButton(onPressed: _pickFile, child: const Text('From a file')),
        child: Column(children: [
          if (_file != null) Align(alignment: Alignment.centerLeft, child: Text(_file!, style: T.small.copyWith(color: C.muted))),
          _field('Filament', _grams, (v) => _grams = v, suffix: 'g'),
          _field('Print time', _hours, (v) => _hours = v, suffix: 'h'),
        ]),
      ),
      const SizedBox(height: 12),
      Panel(
        title: 'Your rates',
        icon: Icons.tune_rounded,
        child: Column(children: [
          _field('Machine wear per hour', _n('wear', 0.2), (v) => settings.setNumber('quote.wear', v), suffix: cur),
          _field('Your time (design, post-processing)', _n('labour', 0), (v) => settings.setNumber('quote.labour', v), suffix: cur),
          _field('Markup', _n('markup', 30), (v) => settings.setNumber('quote.markup', v), suffix: '%'),
          Hint('Filament price, power and electricity price come from Settings → Cost estimate.'),
        ]),
      ),
      const SizedBox(height: 12),
      Panel(
        title: 'Price',
        icon: Icons.sell_outlined,
        trailing: TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            toast(context, 'Quote copied');
          },
          child: const Text('Copy'),
        ),
        child: Column(children: [
          for (final (l, v) in [('Filament', q.$1), ('Power', q.$2), ('Machine wear', q.$3), ('Your time', q.$4)])
            Row(children: [Expanded(child: Text(l)), Text(m(v), style: T.value.copyWith(fontSize: 14))]),
          const Divider(height: 20),
          Row(children: [
            Expanded(child: Text('With ${_n('markup', 30).round()}% markup', style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(m(q.$5), style: T.hero),
          ]),
        ]),
      ),
    ]);
  }
}

/// Calibration maths. Nothing here talks to the printer: you type what you
/// measured and copy the answer into your config or slicer.
class _CalcTab extends StatefulWidget {
  const _CalcTab();
  @override
  State<_CalcTab> createState() => _CalcTabState();
}

class _CalcTabState extends State<_CalcTab> {
  final _v = <String, double>{
    'rd': 7.5, 'req': 100, 'act': 100, //
    'flow': 100, 'exp': 0.45, 'meas': 0.45,
    'paStart': 0, 'paStep': 0.005, 'paH': 10,
    'tStart': 230, 'tStep': -5, 'tEvery': 10, 'tH': 15,
    'des': 100, 'got': 100,
    'g': 1000, 'dens': 1.24,
    'vol': 24, 'lh': 0.2, 'lw': 0.45,
    'gross': 1180, 'empty': 250,
    'h': 50, 'lh2': 0.2,
    'nz': 0.4,
    'in': 1, 'price': 20, 'kg': 1,
    'px': 200, 'py': 200, 'pz': 100,
  };

  Widget _f(String k, String label, {String suffix = ''}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextFormField(
          initialValue: '${_v[k]}',
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
          onChanged: (t) {
            final n = double.tryParse(t.replaceAll(',', '.'));
            if (n != null) setState(() => _v[k] = n);
          },
        ),
      );

  Widget _answer(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          SelectableText(value, style: T.value),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              toast(context, 'Copied $value');
            },
          ),
        ]),
      );

  String _num(double v, [int dp = 3]) => v.isFinite ? v.toStringAsFixed(dp) : '—';

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final panels = [
      Panel(
        title: 'Extruder: rotation distance',
        icon: Icons.straighten_rounded,
        child: Column(children: [
          _f('rotation_distance now', 'rd'),
          _f('Asked to extrude', 'req', suffix: 'mm'),
          _f('Actually extruded', 'act', suffix: 'mm'),
          _answer('New rotation_distance', _num(rotationDistance(v['rd']!, v['req']!, v['act']!))),
        ]),
      ),
      Panel(
        title: 'Flow from a single wall',
        icon: Icons.opacity_rounded,
        child: Column(children: [
          _f('Flow now', 'flow', suffix: '%'),
          _f('Wall should be', 'exp', suffix: 'mm'),
          _f('Wall measures', 'meas', suffix: 'mm'),
          _answer('New flow', '${_num(flowFix(v['flow']!, v['exp']!, v['meas']!), 1)}%'),
        ]),
      ),
      Panel(
        title: 'Pressure advance tower',
        icon: Icons.stacked_line_chart_rounded,
        child: Column(children: [
          _f('Start value', 'paStart'),
          _f('Added per mm', 'paStep'),
          _f('Best-looking height', 'paH', suffix: 'mm'),
          _answer('Pressure advance', _num(towerValue(v['paStart']!, v['paStep']!, v['paH']!), 4)),
        ]),
      ),
      Panel(
        title: 'Temperature tower',
        icon: Icons.thermostat_rounded,
        child: Column(children: [
          _f('Bottom temperature', 'tStart', suffix: '°C'),
          _f('Change per block', 'tStep', suffix: '°C'),
          _f('Block height', 'tEvery', suffix: 'mm'),
          _f('Best-looking height', 'tH', suffix: 'mm'),
          _answer('Print at', '${_num(towerValue(v['tStart']!, v['tStep']!, v['tH']!, every: v['tEvery']!), 0)}°C'),
        ]),
      ),
      Panel(
        title: 'Shrinkage',
        icon: Icons.photo_size_select_small_rounded,
        child: Column(children: [
          _f('Designed size', 'des', suffix: 'mm'),
          _f('Printed size', 'got', suffix: 'mm'),
          _answer('Scale the model to', '${_num(shrinkScale(v['des']!, v['got']!), 2)}%'),
        ]),
      ),
      Panel(
        title: 'Filament weight to length',
        icon: Icons.linear_scale_rounded,
        child: Column(children: [
          _f('Weight', 'g', suffix: 'g'),
          _f('Density', 'dens', suffix: 'g/cm³'),
          _answer('Length (1.75 mm)', '${_num(metresFromGrams(v['g']!, density: v['dens']!), 0)} m'),
        ]),
      ),
    ];
    panels.addAll([
      Panel(
        title: 'Fastest speed for your hotend',
        icon: Icons.speed_rounded,
        child: Column(children: [
          _f('Max volumetric flow', 'vol', suffix: 'mm³/s'),
          _f('Layer height', 'lh', suffix: 'mm'),
          _f('Line width', 'lw', suffix: 'mm'),
          _answer('Up to', '${_num(maxSpeed(v['vol']!, v['lh']!, v['lw']!), 0)} mm/s'),
        ]),
      ),
      Panel(
        title: 'Weigh a spool',
        icon: Icons.scale_outlined,
        child: Column(children: [
          _f('On the scale', 'gross', suffix: 'g'),
          _f('Empty spool', 'empty', suffix: 'g'),
          _answer('Filament left', '${_num(netGrams(v['gross']!, v['empty']!), 0)} g · '
              '${_num(metresFromGrams(netGrams(v['gross']!, v['empty']!), density: v['dens']!), 0)} m'),
        ]),
      ),
      Panel(
        title: 'Layers and line width',
        icon: Icons.layers_outlined,
        child: Column(children: [
          _f('Part height', 'h', suffix: 'mm'),
          _f('Layer height', 'lh2', suffix: 'mm'),
          _answer('Layers', '${layerCount(v['h']!, v['lh2']!)}'),
          _f('Nozzle', 'nz', suffix: 'mm'),
          _answer('Line width to start with', '${_num(v['nz']! * 1.125, 2)} mm'),
          _answer('Layer height range', '${_num(v['nz']! * 0.25, 2)}–${_num(v['nz']! * 0.75, 2)} mm'),
        ]),
      ),
      Panel(
        title: 'Will it fit?',
        icon: Icons.aspect_ratio_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _f('Width (X)', 'px', suffix: 'mm'),
          _f('Depth (Y)', 'py', suffix: 'mm'),
          _f('Height (Z)', 'pz', suffix: 'mm'),
          const SizedBox(height: 8),
          for (final p in [for (final s in settings.strings('printers')) Printer.fromJson(jsonDecode(s))])
            if (clientFor(p).status.buildVolume case final vol?)
              _answer('${p.name} (${vol.map((x) => x.round()).join('×')})',
                  fits([v['px']!, v['py']!, v['pz']!], vol) ? 'fits' : 'too big')
            else
              _answer(p.name, 'size unknown (offline?)'),
        ]),
      ),
      Panel(
        title: 'Inches and millimetres',
        icon: Icons.swap_horiz_rounded,
        child: Column(children: [
          _f('Inches', 'in', suffix: 'in'),
          _answer('Millimetres', '${_num(v['in']! * 25.4, 2)} mm'),
          _answer('…and that many mm in inches', '${_num(v['in']! / 25.4, 4)} in'),
        ]),
      ),
      Panel(
        title: 'Price per gram',
        icon: Icons.payments_outlined,
        child: Column(children: [
          _f('Spool price', 'price', suffix: settings.text('currency', r'$')),
          _f('Spool weight', 'kg', suffix: 'kg'),
          _answer('Per gram', '${settings.text('currency', r'$')}${_num(v['price']! / (v['kg']! * 1000), 4)}'),
          _answer('Per kg', '${settings.text('currency', r'$')}${_num(v['price']! / v['kg']!, 2)}'),
        ]),
      ),
    ]);
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final (i, p) in panels.indexed) ...[if (i > 0) const SizedBox(height: 12), p],
    ]);
  }
}

/// First-layer pictures of recent prints, side by side.
class _FirstLayers extends StatefulWidget {
  final MoonrakerClient client;
  final List<PrintJob> jobs;
  const _FirstLayers({required this.client, required this.jobs});
  @override
  State<_FirstLayers> createState() => _FirstLayersState();
}

class _FirstLayersState extends State<_FirstLayers> {
  late final _files = widget.client.snapshotFiles().catchError((_) => <String>[]);
  String _kind = 'first'; // or 'end': the picture when the print finished

  Future<List<(PrintJob, String)>> get _pics async {
    final files = await _files;
    return [
      for (final j in widget.jobs.take(60))
        if (snapshotsFor(j, files).where((f) => f.endsWith('__$_kind.jpg')).firstOrNull case final f?) (j, f),
    ].take(24).toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_kind == 'first' ? 'First layers' : 'Finished prints'), actions: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: 'first', label: Text('First layer')), ButtonSegment(value: 'end', label: Text('Finished'))],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(width: 8),
        ]),
        body: FutureBuilder<List<(PrintJob, String)>>(
          future: _pics,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) {
              return const StateView.empty(Icons.photo_library_outlined,
                  'No first-layer pictures yet. They come from your home bridge with a camera.');
            }
            return GridView.extent(
              padding: const EdgeInsets.all(16),
              maxCrossAxisExtent: 320,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 4 / 3.6,
              children: [
                for (final (j, f) in snap.data!)
                  Tile(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: FutureBuilder<Uint8List>(
                          future: widget.client.snapshotBytes(f),
                          builder: (_, s) => s.data == null
                              ? Container(color: C.surfaceHi)
                              : InteractiveViewer(child: Image.memory(s.data!, fit: BoxFit.cover)),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('${jobOk(j) ? '✓' : '✕'} ${j.filename.split('/').last} · ${fmtDate(j.start)}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption),
                      ),
                    ]),
                  ),
              ],
            );
          },
        ),
      );
}
