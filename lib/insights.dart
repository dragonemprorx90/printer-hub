// Pure logic behind the Workshop screens: stats, records, maintenance,
// queue timing, inventory, units. No Flutter imports, so it's all testable.
import 'dart:math' as math;

import 'moonraker.dart';

// ---------------------------------------------------------------- history

bool jobOk(PrintJob j) => j.status == 'completed';
bool jobFailed(PrintJob j) => j.status == 'error' || j.status == 'klippy_shutdown';

/// Success rate in 0..1 of finished jobs (completed / completed+failed+cancelled).
double successRate(Iterable<PrintJob> jobs) {
  final done = jobs.where((j) => j.status != 'in_progress' && j.status != 'interrupted');
  if (done.isEmpty) return 0;
  return done.where(jobOk).length / done.length;
}

/// Success rate grouped by a key (material, month…), sorted by count, biggest first.
List<(String, double, int)> rateBy(Iterable<PrintJob> jobs, String? Function(PrintJob) key) {
  final m = <String, List<PrintJob>>{};
  for (final j in jobs) {
    m.putIfAbsent(key(j) ?? 'Unknown', () => []).add(j);
  }
  return [for (final e in m.entries) (e.key, successRate(e.value), e.value.length)]
    ..sort((a, b) => b.$3.compareTo(a.$3));
}

String monthKey(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';

class Records {
  final PrintJob? longest, heaviest;
  final int bestStreak, currentStreak, printDays;
  Records(this.longest, this.heaviest, this.bestStreak, this.currentStreak, this.printDays);
}

/// Longest and heaviest completed print, best and current run of
/// successful prints in a row, and how many different days had a print.
Records records(List<PrintJob> jobs) {
  final sorted = [...jobs]..sort((a, b) => a.start.compareTo(b.start));
  PrintJob? longest, heaviest;
  var best = 0, run = 0;
  for (final j in sorted) {
    if (jobOk(j)) {
      run++;
      best = math.max(best, run);
      if (longest == null || j.duration > longest.duration) longest = j;
      if (heaviest == null || j.filament > heaviest.filament) heaviest = j;
    } else if (j.status != 'in_progress') {
      run = 0;
    }
  }
  final days = {for (final j in jobs) dayKey(j.start)}.length;
  return Records(longest, heaviest, best, run, days);
}

/// Print hours started on each weekday, Monday first.
List<double> hoursByWeekday(Iterable<PrintJob> jobs) {
  final out = List<double>.filled(7, 0);
  for (final j in jobs) {
    out[j.start.weekday - 1] += j.duration / 3600;
  }
  return out;
}

/// Prints started in each hour of the day (0–23).
List<int> startsByHour(Iterable<PrintJob> jobs) {
  final out = List<int>.filled(24, 0);
  for (final j in jobs) {
    out[j.start.hour]++;
  }
  return out;
}

/// Files printed most, (name, times), most first.
List<(String, int)> mostPrinted(Iterable<PrintJob> jobs, {int top = 10}) {
  final m = <String, int>{};
  for (final j in jobs) {
    final n = j.filename.split('/').last;
    m[n] = (m[n] ?? 0) + 1;
  }
  return ([for (final e in m.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2))).take(top).toList();
}

/// (prints, hours, kg) for the calendar month [offset] months back (0 = this one).
(int, double, double) monthTotals(Iterable<PrintJob> jobs, {int offset = 0, DateTime? now}) {
  final n = now ?? DateTime.now();
  final m = DateTime(n.year, n.month - offset);
  final mine = [for (final j in jobs) if (j.start.year == m.year && j.start.month == m.month) j];
  return (
    mine.length,
    mine.fold(0.0, (a, j) => a + j.duration) / 3600,
    mine.fold(0.0, (a, j) => a + gramsFromMm(j.filament)) / 1000,
  );
}

/// (prints, hours) for the week [offset] weeks back (weeks start on Monday).
(int, double) weekTotals(Iterable<PrintJob> jobs, {int offset = 0, DateTime? now}) {
  final n = now ?? DateTime.now();
  final monday = DateTime(n.year, n.month, n.day - (n.weekday - 1) - 7 * offset);
  final end = monday.add(const Duration(days: 7));
  final mine = [for (final j in jobs) if (!j.start.isBefore(monday) && j.start.isBefore(end)) j];
  return (mine.length, mine.fold(0.0, (a, j) => a + j.duration) / 3600);
}

/// Filament cost per material at one price per kg, most first.
List<(String, double)> costByMaterial(Iterable<PrintJob> jobs, double Function(String? material) pricePerKg) {
  final m = <String, double>{};
  for (final j in jobs) {
    final k = j.material ?? 'Unknown';
    m[k] = (m[k] ?? 0) + gramsFromMm(j.filament) / 1000 * pricePerKg(j.material);
  }
  return [for (final e in m.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
}

/// When the last print ended (start + duration), or null.
DateTime? lastPrintEnd(Iterable<PrintJob> jobs) {
  DateTime? best;
  for (final j in jobs) {
    final end = j.start.add(Duration(seconds: j.duration.round()));
    if (j.status != 'in_progress' && (best == null || end.isAfter(best))) best = end;
  }
  return best;
}

/// The day with the most prints: (day, prints), or null.
(DateTime, int)? bestDay(Iterable<PrintJob> jobs) {
  final m = <String, (DateTime, int)>{};
  for (final j in jobs) {
    final k = dayKey(j.start);
    final (d, n) = m[k] ?? (DateTime(j.start.year, j.start.month, j.start.day), 0);
    m[k] = (d, n + 1);
  }
  if (m.isEmpty) return null;
  return m.values.reduce((a, b) => b.$2 > a.$2 ? b : a);
}

/// Success rate of the newest [n] finished prints (jobs newest first).
double recentSuccess(List<PrintJob> jobs, {int n = 10}) =>
    successRate(jobs.where((j) => j.status != 'in_progress').take(n));

String dayKey(DateTime t) => '${t.year}-${t.month}-${t.day}';

/// Prints per day for the last [days] days, oldest first (calendar heat-map).
List<int> printsPerDay(Iterable<PrintJob> jobs, {int days = 84, DateTime? now}) {
  final today = now ?? DateTime.now();
  final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: days - 1));
  final out = List.filled(days, 0);
  for (final j in jobs) {
    final d = DateTime(j.start.year, j.start.month, j.start.day).difference(start).inDays;
    if (d >= 0 && d < days) out[d]++;
  }
  return out;
}

/// Grams of filament from a length in mm (1.75 mm, density in g/cm³).
double gramsFromMm(double mm, [double density = 1.24]) =>
    math.pi * math.pow(0.0875, 2) * (mm / 10) * density;

/// Filament + electricity cost per month, newest first.
List<(String, double, double)> monthlyCost(Iterable<PrintJob> jobs,
    {required double pricePerKg, required double watts, required double pricePerKwh}) {
  final m = <String, (double, double)>{};
  for (final j in jobs) {
    final k = monthKey(j.start);
    final (f, e) = m[k] ?? (0.0, 0.0);
    m[k] = (
      f + gramsFromMm(j.filament) / 1000 * pricePerKg,
      e + j.duration / 3600 * watts / 1000 * pricePerKwh,
    );
  }
  return [for (final e in m.entries) (e.key, e.value.$1, e.value.$2)]
    ..sort((a, b) => b.$1.compareTo(a.$1));
}

/// Jobs matching a History filter. Empty / null fields don't filter.
List<PrintJob> filterJobs(Iterable<PrintJob> jobs,
        {String? status, String? material, String? text, DateTime? from, DateTime? to}) =>
    [
      for (final j in jobs)
        if ((status == null || status.isEmpty || j.status == status) &&
            (material == null || material.isEmpty || (j.material ?? '').toUpperCase() == material.toUpperCase()) &&
            (text == null || text.isEmpty || j.filename.toLowerCase().contains(text.toLowerCase())) &&
            (from == null || !j.start.isBefore(from)) &&
            (to == null || j.start.isBefore(to)))
          j,
    ];

const failureReasons = [
  'Bed adhesion',
  'Spaghetti',
  'Clog / under-extrusion',
  'Layer shift',
  'Ran out of filament',
  'Warping',
  'Power cut',
  'Other',
];

/// Count of each tagged failure reason, biggest first.
List<(String, int)> reasonBreakdown(Map<String, String> tags) {
  final m = <String, int>{};
  for (final r in tags.values) {
    m[r] = (m[r] ?? 0) + 1;
  }
  return [for (final e in m.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
}

/// How a file did before: (times printed, times it finished, average
/// real print time of the finished ones).
(int, int, double?) fileRecord(Iterable<PrintJob> jobs, String path) {
  final mine = [for (final j in jobs) if (j.filename == path) j];
  final ok = mine.where(jobOk).toList();
  return (mine.length, ok.length, ok.isEmpty ? null : ok.fold(0.0, (a, j) => a + j.duration) / ok.length);
}

/// History key for a job, for notes and tags kept on the device.
String jobKey(PrintJob j) => '${j.filename}@${j.start.millisecondsSinceEpoch ~/ 1000}';

/// A price for a print: (filament, power, machine wear, labour, total with markup).
(double, double, double, double, double) quote({
  required double grams,
  required double hours,
  required double pricePerKg,
  required double watts,
  required double pricePerKwh,
  double wearPerHour = 0,
  double labour = 0,
  double markupPct = 0,
}) {
  final fil = grams / 1000 * pricePerKg;
  final power = hours * watts / 1000 * pricePerKwh;
  final wear = hours * wearPerHour;
  final cost = fil + power + wear + labour;
  return (fil, power, wear, labour, cost * (1 + markupPct / 100));
}

// ---------------------------------------------------------------- calculators

/// Klipper rotation_distance after asking for [requested] mm and measuring [actual].
double rotationDistance(double old, double requested, double actual) => old * actual / requested;

/// New flow % from a single-wall test: expected vs measured wall thickness.
double flowFix(double flowPct, double expected, double measured) => flowPct * expected / measured;

/// Value on a tower at [height] mm: start + (height / every) steps of [step].
double towerValue(double start, double step, double height, {double every = 1}) =>
    start + (height / every).floor() * step;

/// Scale % to make a part come out at its designed size.
double shrinkScale(double designed, double measured) => designed / measured * 100;

/// Filament length (m) for grams, and the other way (1.75 mm unless given).
double metresFromGrams(double g, {double density = 1.24, double diameter = 1.75}) =>
    g / (density * math.pi * math.pow(diameter / 20, 2) * 100);

/// Fastest print speed (mm/s) a hotend's flow limit allows.
double maxSpeed(double flowMm3s, double layer, double width) => flowMm3s / (layer * width);

/// Grams left on a spool you weighed, minus the empty spool.
double netGrams(double gross, double emptySpool) => math.max(0, gross - emptySpool);

/// Layers in a part.
int layerCount(double height, double layer, {double? first}) =>
    layer <= 0 ? 0 : 1 + ((height - (first ?? layer)) / layer).ceil().clamp(0, 1 << 20);

/// Does a part fit a build volume, either way round on the plate?
bool fits(List<double> part, List<double> volume) =>
    part.length >= 3 &&
    volume.length >= 3 &&
    part[2] <= volume[2] &&
    ((part[0] <= volume[0] && part[1] <= volume[1]) || (part[1] <= volume[0] && part[0] <= volume[1]));

// ---------------------------------------------------------------- queue

/// When each queued job will finish, one after another, starting [from]
/// plus whatever is left of the current print.
List<DateTime> queueFinishTimes(List<double?> durations, {required DateTime from, double currentLeft = 0}) {
  var t = from.add(Duration(seconds: currentLeft.round()));
  return [
    for (final d in durations) t = t.add(Duration(seconds: (d ?? 0).round())),
  ];
}

/// When to start a print of [seconds] so it ends at [finish]. Null if that's
/// already past.
DateTime? startForFinish(DateTime finish, double seconds, {DateTime? now}) {
  final s = finish.subtract(Duration(seconds: seconds.round()));
  return s.isBefore(now ?? DateTime.now()) ? null : s;
}

/// The layer that prints at [mm] height (1-based), from the slicer's first
/// layer and layer heights.
int layerForHeight(double mm, {required double layer, double? first}) {
  final f = first ?? layer;
  if (mm <= f || layer <= 0) return 1;
  return ((mm - f) / layer).ceil() + 1;
}

/// Seconds the print is running behind (+) or ahead (−) of the slicer's
/// estimate, once there's enough to go on (5%).
double? paceVsSlicer(double elapsed, double progress, double? estimate) {
  if (estimate == null || estimate <= 0 || progress < 0.05 || elapsed <= 0) return null;
  return elapsed / progress - estimate;
}

/// "12m slower" / "8m faster" / "on time" (within 2 minutes).
String paceText(double secs) {
  final m = (secs.abs() / 60).round();
  if (m < 2) return 'on time';
  final t = m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
  return secs > 0 ? '$t slower' : '$t faster';
}

/// A short status to paste anywhere.
String statusShare(String printer, String file, double progress, double? eta, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final done = eta == null ? '' : ', done about ${fmtHm(n.add(Duration(seconds: eta.round())))}';
  return '$printer: ${file.split('/').last} is ${(progress * 100).round()}% done$done.';
}

// ---------------------------------------------------------------- maintenance

/// Abrasive filaments wear a brass nozzle faster: they count extra hours.
double wearFactor(String? material) {
  final m = (material ?? '').toUpperCase();
  if (m.contains('CF') || m.contains('GF') || m.contains('GLOW') || m.contains('WOOD')) return 3;
  if (m.contains('PA') || m.contains('PC')) return 1.5;
  return 1;
}

/// Weighted nozzle hours since [since].
double nozzleHours(Iterable<PrintJob> jobs, DateTime since) => jobs
    .where((j) => !j.start.isBefore(since))
    .fold(0.0, (a, j) => a + j.duration / 3600 * wearFactor(j.material));

/// (name, every N print hours) to start a printer with.
List<(String, double)> maintenanceTemplate(String printerName) {
  final n = printerName.toLowerCase();
  const common = [
    ('Clean the nozzle', 25.0),
    ('Clean the build plate', 25.0),
    ('Check belt tension', 100.0),
    ('Lubricate linear rails / rods', 200.0),
    ('Check screws and frame', 200.0),
    ('Replace the nozzle', 500.0),
  ];
  if (n.contains('k2') || n.contains('creality')) {
    return [...common, ('Clean the CFS feeders', 100.0), ('Replace the cutter blade', 400.0), ('Clean the chamber fan filter', 150.0)];
  }
  if (n.contains('u1') || n.contains('snapmaker')) {
    return [...common, ('Clean the toolhead docks', 100.0), ('Check toolhead offsets', 150.0), ('Wipe the purge area', 50.0)];
  }
  return [...common, ('Replace the PTFE tube', 300.0)];
}

/// Print hours per day over the last 30 days.
double hoursPerDay(Iterable<PrintJob> jobs, {DateTime? now}) {
  final n = now ?? DateTime.now();
  return jobs.where((j) => n.difference(j.start).inDays < 30).fold(0.0, (a, j) => a + j.duration / 3600) / 30;
}

/// Days until [hoursLeft] more print hours at your recent pace, or null.
double? daysUntil(double hoursLeft, double perDay) => perDay <= 0 ? null : (hoursLeft <= 0 ? 0 : hoursLeft / perDay);

/// Tasks due (used >= every), from maintenance items as saved by the Tools tab.
List<String> dueTasks(List<Map<String, dynamic>> items, double hours) => [
      for (final m in items)
        if ((m['hours'] as num) > 0 && hours - (m['since'] as num) >= (m['hours'] as num)) '${m['name']}',
    ];

/// Bed screw help from a mesh (rows front to back, columns left to right):
/// how far each corner sits above the lowest one, in mm and screw turns
/// ([pitch] mm per turn, 0.7 for M4). Lowering the high corners to the
/// lowest one keeps the nozzle clear of the bed.
List<(String, double, double)> screwHelp(List<List<double>> mesh, {double pitch = 0.7}) {
  if (mesh.isEmpty || mesh.first.isEmpty) return const [];
  final corners = {
    'Front left': mesh.first.first,
    'Front right': mesh.first.last,
    'Back left': mesh.last.first,
    'Back right': mesh.last.last,
  };
  final low = corners.values.reduce(math.min);
  return [for (final e in corners.entries) (e.key, e.value - low, (e.value - low) / pitch)];
}

/// "about 1/4 turn" for a fraction of a turn.
String turnsText(double turns) {
  final t = turns.abs();
  if (t < 0.06) return 'leave it';
  const steps = [(0.125, '1/8'), (0.25, '1/4'), (0.375, '3/8'), (0.5, '1/2'), (0.75, '3/4'), (1.0, '1')];
  for (final (v, label) in steps) {
    if (t <= v + 0.06) return 'about $label turn';
  }
  return 'about ${t.toStringAsFixed(1)} turns';
}

/// Mesh range grew by more than [limit] mm since a saved mesh.
bool meshDrifted(double savedRange, double nowRange, {double limit = 0.1}) =>
    nowRange - savedRange > limit;

/// Lines like "Klipper: v0.12 → v0.13" for versions that changed.
List<String> versionChanges(Map<String, String> before, Map<String, String> now) => [
      for (final e in now.entries)
        if (before[e.key] != null && before[e.key] != e.value) '${e.key}: ${before[e.key]} → ${e.value}',
    ];

// ---------------------------------------------------------------- filament

/// Spools grouped by material, with total grams, biggest first.
List<(String, double, int)> inventory(Iterable<Spool> spools) {
  final m = <String, (double, int)>{};
  for (final s in spools) {
    final k = s.material.isEmpty ? 'Unknown' : s.material.toUpperCase();
    final (g, n) = m[k] ?? (0.0, 0);
    m[k] = (g + (s.remaining ?? 0), n + 1);
  }
  return [for (final e in m.entries) (e.key, e.value.$1, e.value.$2)]..sort((a, b) => b.$2.compareTo(a.$2));
}

/// Shopping list text for spools under [limit] grams.
String shoppingList(Iterable<Spool> spools, {double limit = 200}) {
  final low = [for (final s in spools) if ((s.remaining ?? 0) < limit) s];
  if (low.isEmpty) return '';
  return [
    'Filament to buy:',
    for (final s in low)
      '- ${s.material} ${s.name} ${s.color == null ? '' : colorName(s.color!)} (${(s.remaining ?? 0).round()} g left)'
          .replaceAll(RegExp(r'\s+'), ' ').trim(),
  ].join('\n');
}

/// Days your filament lasts at the last 30 days' pace, or null without use.
double? daysOfFilament(double gramsOnHand, Iterable<PrintJob> jobs, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final used = jobs
      .where((j) => n.difference(j.start).inDays < 30)
      .fold(0.0, (a, j) => a + gramsFromMm(j.filament));
  if (used <= 0) return null;
  return gramsOnHand / (used / 30);
}

/// Price per gram, or null without a price.
double? pricePerGram(Spool s) => s.pricePerKg == null ? null : s.pricePerKg! / 1000;

const _names = <String, int>{
  'black': 0x000000, 'white': 0xFFFFFF, 'grey': 0x808080, 'silver': 0xC0C0C0,
  'red': 0xE53935, 'dark red': 0x8B0000, 'orange': 0xFF8C00, 'yellow': 0xFFD600,
  'gold': 0xD4AF37, 'green': 0x43A047, 'dark green': 0x1B5E20, 'lime': 0xA4D600,
  'teal': 0x008080, 'cyan': 0x00BCD4, 'blue': 0x1E88E5, 'navy': 0x1A237E,
  'purple': 0x8E24AA, 'pink': 0xF06292, 'magenta': 0xD81B60, 'brown': 0x6D4C41,
  'beige': 0xE8D9B5, 'skin': 0xF1C27D,
};

/// The nearest plain colour name for an ARGB or RGB value ("dark red").
String colorName(int argb) {
  int r(int c) => (c >> 16) & 0xFF;
  int g(int c) => (c >> 8) & 0xFF;
  int b(int c) => c & 0xFF;
  var best = '';
  num dist = double.infinity;
  for (final e in _names.entries) {
    final d = math.pow(r(argb) - r(e.value), 2) * 2 +
        math.pow(g(argb) - g(e.value), 2) * 4 +
        math.pow(b(argb) - b(e.value), 2) * 3;
    if (d < dist) {
      dist = d;
      best = e.key;
    }
  }
  return best;
}

/// A warning for materials that want a warm, closed chamber, or null.
String? materialWarning(String? material, {required bool hasChamber, double? chamberTemp}) {
  final m = (material ?? '').toUpperCase();
  final hot = ['ABS', 'ASA', 'PC', 'PA', 'NYLON'].any(m.contains);
  if (!hot) return null;
  if (!hasChamber) return '$m prints best in a closed, heated chamber. This printer has none: expect warping.';
  if (chamberTemp != null && chamberTemp < 35) {
    return 'Chamber is ${chamberTemp.round()}°C. $m warps less if you heat it to 45–60°C first.';
  }
  return null;
}

/// Preheat presets: (material, nozzle, bed, chamber; 0 = leave it).
const preheatPresets = [
  ('PLA', 210, 60, 0),
  ('PETG', 240, 75, 0),
  ('ABS', 255, 100, 50),
  ('ASA', 260, 100, 50),
  ('TPU', 225, 50, 0),
];

/// Drying presets: (material, °C, hours).
const dryPresets = [
  ('PLA', 50, 4),
  ('PETG', 65, 4),
  ('TPU', 55, 6),
  ('ABS', 70, 4),
  ('ASA', 70, 4),
  ('PA / Nylon', 80, 8),
  ('PC', 75, 6),
  ('PVA', 55, 6),
];

/// Tool changes in a multi-tool print, from slicer metadata when it says.
int? toolChanges(Map<String, dynamic> meta) {
  for (final k in ['tool_changes', 'total_toolchanges', 'filament_change_count']) {
    final v = meta[k];
    if (v is num) return v.toInt();
    if (v is String && int.tryParse(v) != null) return int.parse(v);
  }
  return null;
}

// ---------------------------------------------------------------- files

/// Groups of paths with the same file name and size (likely copies).
List<List<GcodeFile>> duplicates(Iterable<GcodeFile> files) {
  final m = <String, List<GcodeFile>>{};
  for (final f in files) {
    m.putIfAbsent('${f.name}|${f.size}', () => []).add(f);
  }
  return [for (final v in m.values) if (v.length > 1) v];
}

List<GcodeFile> olderThan(Iterable<GcodeFile> files, int days, {DateTime? now}) {
  final cut = (now ?? DateTime.now()).subtract(Duration(days: days));
  return [for (final f in files) if (f.modified.isBefore(cut)) f];
}

int totalSize(Iterable<GcodeFile> files) => files.fold(0, (a, f) => a + f.size);

// ---------------------------------------------------------------- units & rules

double toF(double c) => c * 9 / 5 + 32;

/// "215°C" or "419°F" depending on the setting.
String fmtTemp(double c, {bool fahrenheit = false}) =>
    fahrenheit ? '${toF(c).round()}°F' : '${c.round()}°C';

/// "18:42" or "6:42 PM".
String fmtHm(DateTime t, {bool twelve = false}) {
  final m = t.minute.toString().padLeft(2, '0');
  if (!twelve) return '${t.hour.toString().padLeft(2, '0')}:$m';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Rule window: [days] are 1=Mon..7=Sun (empty = every day), [from]/[to]
/// "HH:MM" (empty = all day; may wrap past midnight).
bool inWindow(DateTime t, {List<int> days = const [], String from = '', String to = ''}) {
  if (days.isNotEmpty && !days.contains(t.weekday)) return false;
  if (from.isEmpty || to.isEmpty) return true;
  int mins(String s) => int.parse(s.split(':')[0]) * 60 + int.parse(s.split(':')[1]);
  final now = t.hour * 60 + t.minute, a = mins(from), b = mins(to);
  return a <= b ? now >= a && now < b : now >= a || now < b;
}

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "At 50% → Send me a picture (weekdays 22:00–07:00)".
String ruleText(Map r, Map<String, String> triggers) {
  final when = switch (r['on']) {
    'time' => 'Every day at ${r['at']}',
    'progress' => 'At ${r['at']}%',
    'interval' => 'Every ${r['at']} min while printing',
    'layer' => 'At layer ${r['at']}',
    'idle' => 'Idle for ${r['at']} min',
    final o => triggers[o] ?? '$o',
  };
  final days = [for (final d in (r['days'] as List?) ?? const []) _dayNames[(int.tryParse('$d') ?? 1) - 1]];
  final window = [
    if (days.isNotEmpty) days.join(' '),
    if ('${r['from'] ?? ''}'.isNotEmpty) '${r['from']}–${r['to']}',
  ].join(', ');
  return '$when → ${r['label'] ?? r['do']}${window.isEmpty ? '' : ' ($window)'}';
}

/// What a rule would do right now, in words, without doing it.
String ruleDryRun(Map r, Map<String, String> triggers, DateTime now) {
  final g = '${r['do'] ?? ''}';
  final what = g == '@picture'
      ? 'send you an alert with a camera picture'
      : g == '@keep'
          ? 'save a camera picture to History'
          : g.startsWith('@dry')
              ? 'start drying filament (${g.split(' ').skip(1).join('°C, ')} h)'
              : g.startsWith('@notify')
                  ? 'send you the alert "${g.substring(7).trim()}"'
                  : g.startsWith('@power')
                      ? 'turn the power device ${g.split(' ').skip(1).join(' ')}'
                      : g.startsWith('@webhook')
                      ? 'POST the printer state to ${g.substring(8).trim()}'
                      : 'run the G-code "$g" on the printer';
  final days = [for (final d in (r['days'] as List?) ?? const []) int.tryParse('$d') ?? 0];
  final allowed = inWindow(now, days: days, from: '${r['from'] ?? ''}', to: '${r['to'] ?? ''}');
  return [
    'When: ${ruleText(r, triggers).split(' → ').first}.',
    'It would $what.',
    r['off'] == true ? 'The rule is switched off, so it won\'t run.' : allowed ? 'It is allowed to run right now.' : 'It would not run right now (outside its days or hours).',
  ].join('\n');
}

/// Snooze until: 1 h from now, or tomorrow 08:00.
DateTime snoozeUntil(String kind, {DateTime? now}) {
  final n = now ?? DateTime.now();
  return kind == 'tomorrow' ? DateTime(n.year, n.month, n.day + 1, 8) : n.add(const Duration(hours: 1));
}

/// Is a printer's alert snoozed (ms since epoch stored)?
bool snoozed(int? untilMs, {DateTime? now}) =>
    untilMs != null && (now ?? DateTime.now()).millisecondsSinceEpoch < untilMs;

/// Best idle printer for a job: smallest bed that fits it, among idle ones.
/// Each candidate is (name, idle, bedX, bedY).
String? suggestPrinter(List<(String, bool, double, double)> printers, {double needX = 0, double needY = 0}) {
  final fit = [
    for (final p in printers)
      if (p.$2 && p.$3 >= needX && p.$4 >= needY) p,
  ]..sort((a, b) => (a.$3 * a.$4).compareTo(b.$3 * b.$4));
  return fit.isEmpty ? null : fit.first.$1;
}

/// Everything that needs you across the printers, most urgent first.
/// Each printer: (name, status, maintenance items, print hours or null, spare parts).
List<String> attentionItems(
    List<(String, PrinterStatus, List<Map<String, dynamic>>, double?, List<Map<String, dynamic>>)> all,
    {double humidityLimit = 45}) {
  final urgent = <String>[], later = <String>[];
  for (final (name, s, maint, hours, parts) in all) {
    if (!s.online) {
      urgent.add('$name is offline');
      continue;
    }
    if (s.state == 'error') urgent.add('$name: print failed');
    if (s.state == 'paused') urgent.add('$name is paused${s.message == null ? '' : ': ${s.message}'}');
    if (s.failureWatch?['failing'] == true) urgent.add('$name: possible print failure');
    for (final b in s.cfs) {
      if ((b.humidity ?? 0) >= humidityLimit) later.add('$name ${b.name}: humidity ${b.humidity!.round()}%');
    }
    if (hours != null) {
      for (final t in dueTasks(maint, hours)) {
        later.add('$name: $t is due');
      }
    }
    for (final p in parts) {
      if ((p['n'] as int) <= (p['low'] as int? ?? 1)) later.add('$name: ${p['name']} running low (${p['n']})');
    }
  }
  return [...urgent, ...later];
}

/// The printer that finishes soonest and when: (name, seconds left), or null.
(String, double)? nextDone(List<(String, PrinterStatus)> all) {
  (String, double)? best;
  for (final (n, s) in all) {
    final eta = s.eta;
    if (!s.online || s.state != 'printing' || eta == null) continue;
    if (best == null || eta < best.$2) best = (n, eta);
  }
  return best;
}

/// "2 printing · 1 idle · 1 offline".
String fleetSummary(List<PrinterStatus> all) {
  final printing = all.where((s) => s.online && s.state == 'printing').length;
  final paused = all.where((s) => s.online && s.state == 'paused').length;
  final off = all.where((s) => !s.online).length;
  final idle = all.length - printing - paused - off;
  return [
    if (printing > 0) '$printing printing',
    if (paused > 0) '$paused paused',
    if (idle > 0) '$idle idle',
    if (off > 0) '$off offline',
  ].join(' · ');
}
