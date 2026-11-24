import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/insights.dart';
import 'package:printer_hub/moonraker.dart';

PrintJob job(String status, int day, {double h = 1, double mm = 1000, String? m}) =>
    PrintJob('f$day.gcode', status, DateTime(2026, 11, day, 10), h * 3600, mm, true, material: m);

void main() {
  final jobs = [
    job('completed', 1, h: 2, m: 'PLA'),
    job('completed', 2, h: 5, mm: 9000, m: 'PLA'),
    job('error', 3, m: 'PETG'),
    job('completed', 4, m: 'PETG'),
    job('cancelled', 4, m: 'PLA'),
    job('completed', 5, h: 3, m: 'PA-CF'),
  ];

  test('success rate and grouping', () {
    expect(successRate(jobs), closeTo(4 / 6, 1e-9));
    final by = rateBy(jobs, (j) => j.material);
    expect(by.first.$1, 'PLA');
    expect(by.first.$3, 3);
  });

  test('records and streaks', () {
    final r = records(jobs);
    expect(r.longest!.filename, 'f2.gcode');
    expect(r.heaviest!.filename, 'f2.gcode');
    expect(r.bestStreak, 2);
    expect(r.currentStreak, 1);
    expect(r.printDays, 5);
  });

  test('prints per day ends today', () {
    final d = printsPerDay(jobs, days: 7, now: DateTime(2026, 11, 5, 20));
    expect(d.last, 1);
    expect(d[d.length - 2], 2);
  });

  test('filter and reasons', () {
    expect(filterJobs(jobs, material: 'pla').length, 3);
    expect(filterJobs(jobs, status: 'completed', from: DateTime(2026, 11, 3)).length, 2);
    expect(reasonBreakdown({'a': 'Spaghetti', 'b': 'Spaghetti', 'c': 'Warping'}).first, ('Spaghetti', 2));
  });

  test('monthly cost', () {
    final c = monthlyCost(jobs, pricePerKg: 20, watts: 1000, pricePerKwh: 0.5);
    expect(c.single.$1, '2026-11');
    expect(c.single.$3, closeTo(13 * 0.5, 1e-9));
    expect(gramsFromMm(1000), closeTo(2.98, 0.01));
  });

  test('queue and finish-at', () {
    final t = queueFinishTimes([3600, null, 1800], from: DateTime(2026, 1, 1, 10), currentLeft: 600);
    expect(t.map((x) => '${x.hour}:${x.minute}'), ['11:10', '11:10', '11:40']);
    expect(startForFinish(DateTime(2026, 1, 1, 18), 7200, now: DateTime(2026, 1, 1, 9)), DateTime(2026, 1, 1, 16));
    expect(startForFinish(DateTime(2026, 1, 1, 10), 7200, now: DateTime(2026, 1, 1, 9)), isNull);
  });

  test('layer for height', () {
    expect(layerForHeight(10, layer: 0.2, first: 0.2), 50);
    expect(layerForHeight(0.1, layer: 0.2), 1);
    expect(layerForHeight(1.0, layer: 0.2, first: 0.3), 5);
  });

  test('maintenance', () {
    expect(wearFactor('PA-CF'), 3);
    expect(nozzleHours(jobs, DateTime(2026, 11, 5)), 9);
    expect(maintenanceTemplate('K2 Plus').any((t) => t.$1.contains('CFS')), isTrue);
    expect(dueTasks([{'name': 'Belts', 'hours': 100, 'since': 0}, {'name': 'Nozzle', 'hours': 500, 'since': 0}], 120), ['Belts']);
    expect(meshDrifted(0.2, 0.35), isTrue);
    expect(versionChanges({'klipper': 'v1'}, {'klipper': 'v2', 'new': 'x'}), ['klipper: v1 → v2']);
  });

  test('filament', () {
    final s = [Spool(1, 'Bambu', 'pla', 0xFFE53935, 150, 20), Spool(2, 'X', 'PLA', null, 800), Spool(3, 'Y', 'PETG', 0xFF000000, 50)];
    expect(inventory(s).first, ('PLA', 950.0, 2));
    expect(shoppingList(s), contains('red'));
    expect(shoppingList(s).split('\n').length, 3);
    expect(pricePerGram(s[0]), 0.02);
    expect(colorName(0xFF8B0000), 'dark red');
    expect(colorName(0xFFFFFFFE), 'white');
    expect(materialWarning('ABS', hasChamber: false), isNotNull);
    expect(materialWarning('ABS', hasChamber: true, chamberTemp: 50), isNull);
    expect(materialWarning('PLA', hasChamber: false), isNull);
  });

  test('tool changes from metadata', () {
    expect(toolChanges({'tool_changes': 4}), 4);
    expect(toolChanges({'total_toolchanges': '7'}), 7);
    expect(toolChanges({}), isNull);
  });

  test('files', () {
    final f = [
      GcodeFile('a/x.gcode', 10, DateTime(2026, 1, 1)),
      GcodeFile('b/x.gcode', 10, DateTime(2026, 11, 1)),
      GcodeFile('y.gcode', 5, DateTime(2026, 11, 1)),
    ];
    expect(duplicates(f).single.length, 2);
    expect(olderThan(f, 30, now: DateTime(2026, 11, 20)).length, 1);
    expect(totalSize(f), 25);
  });

  test('rule text and dry run', () {
    final r = {'on': 'progress', 'at': '50', 'do': '@notify Halfway', 'label': 'Alert: Halfway', 'days': [1, 2], 'from': '22:00', 'to': '07:00'};
    expect(ruleText(r, const {}), 'At 50% → Alert: Halfway (Mon Tue, 22:00–07:00)');
    final d = ruleDryRun(r, const {}, DateTime(2026, 11, 23, 23)); // Monday 23:00
    expect(d, contains('"Halfway"'));
    expect(d, contains('allowed to run right now'));
    expect(ruleDryRun({...r, 'off': true}, const {}, DateTime(2026, 11, 23, 23)), contains('switched off'));
    expect(ruleDryRun({'on': 'complete', 'do': 'M84'}, const {'complete': 'Print finishes'}, DateTime(2026, 11, 23)),
        contains('run the G-code "M84"'));
  });

  test('units, windows, snooze, suggestion', () {
    expect(fmtTemp(100, fahrenheit: true), '212°F');
    expect(fmtHm(DateTime(2026, 1, 1, 18, 5), twelve: true), '6:05 PM');
    expect(fmtHm(DateTime(2026, 1, 1, 0, 5), twelve: true), '12:05 AM');
    final mon23 = DateTime(2026, 11, 23, 23, 30); // a Monday
    expect(inWindow(mon23, days: [1], from: '22:00', to: '07:00'), isTrue);
    expect(inWindow(mon23, days: [2]), isFalse);
    expect(inWindow(DateTime(2026, 11, 23, 12), from: '22:00', to: '07:00'), isFalse);
    expect(snoozeUntil('tomorrow', now: DateTime(2026, 1, 1, 20)), DateTime(2026, 1, 2, 8));
    expect(snoozed(DateTime(2026, 1, 2).millisecondsSinceEpoch, now: DateTime(2026, 1, 1)), isTrue);
    expect(suggestPrinter([('K2', true, 350, 350), ('U1', true, 270, 270), ('V', false, 200, 200)], needX: 260), 'U1');
  });
}
