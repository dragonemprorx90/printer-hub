import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'charts.dart';
import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Filament mass in grams for a length in mm (cylinder × density).
double filamentGrams(double mm, {double diameter = 1.75, double density = 1.24}) {
  final r = diameter / 2;
  return math.pi * r * r * mm / 1000 * density;
}

double jobCost(PrintJob j) {
  final grams = filamentGrams(j.filament,
      diameter: settings.number('filamentDiameter', 1.75),
      density: settings.number('filamentDensity', 1.24));
  final material = grams / 1000 * settings.number('filamentPrice', 20);
  final energy = j.duration / 3600 *
      settings.number('printerWatts', 350) / 1000 *
      settings.number('kwhPrice', 0.30);
  return material + energy;
}

String money(double v) => '${settings.text('currency', '\$')}${v.toStringAsFixed(2)}';

String _csvCell(Object? v) {
  final s = '${v ?? ''}';
  return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// History as CSV (one row per job).
String historyCsv(List<PrintJob> jobs) {
  final rows = [
    ['file', 'status', 'started', 'duration_s', 'filament_mm', 'material', 'est_cost'],
    for (final j in jobs)
      [
        j.filename,
        j.status,
        j.start.toIso8601String(),
        j.duration.round(),
        j.filament.round(),
        j.material ?? '',
        jobCost(j).toStringAsFixed(2),
      ],
  ];
  return '${rows.map((r) => r.map(_csvCell).join(',')).join('\n')}\n';
}

class HistoryTab extends StatefulWidget {
  final MoonrakerClient client;
  const HistoryTab({super.key, required this.client});
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  List<PrintJob>? _jobs;
  HistoryTotals? _totals;
  String? _error;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _jobs = null;
      _error = null;
    });
    try {
      final jobs = await widget.client.allHistory();
      final totals = await widget.client.historyTotals();
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _totals = totals;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _export() async {
    final jobs = _jobs;
    if (jobs == null) return;
    try {
      final saved = await FilePicker.saveFile(
        fileName: 'print-history-${fmtDate(DateTime.now())}.csv',
        bytes: Uint8List.fromList(utf8.encode(historyCsv(jobs))),
        mimeType: 'text/csv',
      );
      if (saved != null && mounted) toast(context, 'Exported ${jobs.length} jobs');
    } catch (e) {
      if (mounted) toast(context, 'Export failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, style: const TextStyle(color: C.danger)),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    final jobs = _jobs;
    if (jobs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final shown = [
      for (final j in jobs)
        if (_filter == 'all' ||
            (_filter == 'failed' ? (j.status == 'error' || j.status == 'klippy_shutdown') : j.status == _filter))
          j,
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: shown.length + 1,
            itemBuilder: (context, i) {
              if (i > 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _JobTile(job: shown[i - 1], client: widget.client),
                );
              }
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _StatsPanel(jobs: jobs, totals: _totals, onExport: _export),
                const SizedBox(height: 16),
                LayoutBuilder(builder: (context, c) {
                  final monthly = _MonthlyPanel(jobs: jobs);
                  final materials = _MaterialsPanel(jobs: jobs);
                  if (c.maxWidth < 700) {
                    return Column(children: [monthly, const SizedBox(height: 16), materials]);
                  }
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 3, child: monthly),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: materials),
                  ]);
                }),
                const SizedBox(height: 16),
                Wrap(spacing: 8, children: [
                  for (final (key, label) in const [
                    ('all', 'All'),
                    ('completed', 'Completed'),
                    ('cancelled', 'Cancelled'),
                    ('failed', 'Failed'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _filter == key,
                      onSelected: (_) => setState(() => _filter = key),
                    ),
                ]),
                const SizedBox(height: 12),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _StatsPanel extends StatelessWidget {
  final List<PrintJob> jobs;
  final HistoryTotals? totals;
  final VoidCallback onExport;
  const _StatsPanel({required this.jobs, required this.totals, required this.onExport});

  @override
  Widget build(BuildContext context) {
    final done = jobs.where((j) => j.status == 'completed').length;
    final finished = jobs.where((j) => j.status != 'in_progress').length;
    final rate = finished == 0 ? '—' : '${(done * 100 / finished).round()}%';
    final filament = jobs.fold<double>(0, (a, j) => a + j.filament);
    final grams = filamentGrams(filament,
        diameter: settings.number('filamentDiameter', 1.75),
        density: settings.number('filamentDensity', 1.24));
    final cost = jobs.fold<double>(0, (a, j) => a + jobCost(j));
    final hours = jobs.fold<double>(0, (a, j) => a + j.duration);
    return Panel(
      title: 'All time',
      icon: Icons.insights_rounded,
      trailing: TextButton.icon(
        onPressed: onExport,
        icon: const Icon(Icons.download_rounded, size: 18),
        label: const Text('Export CSV'),
      ),
      child: Wrap(spacing: 28, runSpacing: 14, children: [
        StatTile(label: 'Prints', value: '${totals?.jobs ?? jobs.length}'),
        StatTile(label: 'Success rate', value: rate),
        StatTile(label: 'Print time', value: fmtDuration(totals?.printTime ?? hours)),
        StatTile(label: 'Filament', value: '${fmtFilament(filament)} · ${(grams / 1000).toStringAsFixed(2)} kg'),
        StatTile(label: 'Est. cost', value: money(cost)),
        StatTile(label: 'Longest', value: fmtDuration(totals?.longest)),
      ]),
    );
  }
}

class _MonthlyPanel extends StatelessWidget {
  final List<PrintJob> jobs;
  const _MonthlyPanel({required this.jobs});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final buckets = List<double>.filled(12, 0);
    final labels = <String>[];
    for (var i = 11; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i);
      labels.add(_months[m.month - 1]);
    }
    for (final j in jobs) {
      final ago = (now.year - j.start.year) * 12 + now.month - j.start.month;
      if (ago >= 0 && ago < 12) buckets[11 - ago]++;
    }
    return Panel(
      title: 'Prints per month',
      icon: Icons.bar_chart_rounded,
      child: BarChart(values: buckets, labels: labels),
    );
  }
}

class _MaterialsPanel extends StatelessWidget {
  final List<PrintJob> jobs;
  const _MaterialsPanel({required this.jobs});

  @override
  Widget build(BuildContext context) {
    final byMat = <String, (int, int)>{};
    for (final j in jobs) {
      final k = j.material ?? 'Unknown';
      final (n, ok) = byMat[k] ?? (0, 0);
      byMat[k] = (n + 1, ok + (j.status == 'completed' ? 1 : 0));
    }
    final rows = byMat.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    return Panel(
      title: 'By material',
      icon: Icons.category_outlined,
      child: Column(children: [
        for (final e in rows.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              SizedBox(
                  width: 80,
                  child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700))),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: e.value.$1 / jobs.length,
                    minHeight: 8,
                    backgroundColor: C.surfaceHi,
                  ),
                ),
              ),
              SizedBox(
                width: 92,
                child: Text(
                  '${e.value.$1} · ${(e.value.$2 * 100 / e.value.$1).round()}% ok',
                  textAlign: TextAlign.end,
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _JobTile extends StatelessWidget {
  final PrintJob job;
  final MoonrakerClient client;
  const _JobTile({required this.job, required this.client});

  /// Pictures the home bridge took at the first layer and the end.
  Future<void> _pictures(BuildContext context) async {
    final files = snapshotsFor(job, await client.snapshotFiles().catchError((_) => <String>[]));
    if (!context.mounted) return;
    if (files.isEmpty) {
      return toast(context, 'No pictures for this print (the home bridge takes them when it has a camera)');
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(job.filename.split('/').last, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final f in files)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(children: [
                    FutureBuilder<Uint8List>(
                      future: client.snapshotBytes(f),
                      builder: (_, s) => s.hasData
                          ? ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(s.data!))
                          : const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
                    ),
                    const SizedBox(height: 4),
                    Text(f.endsWith('__first.jpg') ? 'First layer' : 'End', style: TextStyle(color: C.muted)),
                  ]),
                ),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (job.status) {
      'completed' => (Icons.check_circle_rounded, C.accent),
      'cancelled' => (Icons.cancel_rounded, C.warn),
      'in_progress' => (Icons.timelapse_rounded, C.bed),
      _ => (Icons.error_rounded, C.danger),
    };
    final name = job.filename.split('/').last;
    return Tile(
      child: ListTile(
        onTap: () => _pictures(context),
        leading: Icon(icon, color: color, size: 28),
        title: Text(name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            fmtAgo(job.start),
            fmtDuration(job.duration),
            fmtFilament(job.filament),
            ?job.material,
            money(jobCost(job)),
          ].join(' · '),
          style: TextStyle(color: C.muted, fontSize: 12),
        ),
        trailing: job.exists
            ? IconButton(
                tooltip: 'Print again',
                icon: const Icon(Icons.replay_rounded),
                onPressed: () async {
                  if (await confirm(context, 'Print $name again?', action: 'Print') &&
                      context.mounted) {
                    run(context, () => client.startPrint(job.filename),
                        done: 'Print started');
                  }
                },
              )
            : null,
      ),
    );
  }
}
