import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/tools_page.dart';
import 'package:printer_hub/history_page.dart';
import 'package:printer_hub/screen_page.dart';
import 'package:printer_hub/u1_panels.dart';
import 'package:printer_hub/update.dart';
import 'package:printer_hub/wall_page.dart';
import 'package:printer_hub/whats_new.dart';

void main() {
  test('applyDelta parses a Moonraker status payload and merges partials', () {
    final s = PrinterStatus();

    // Full first snapshot (shape of printer.objects.subscribe result.status).
    s.applyDelta({
      'extruder': {'temperature': 210.4, 'target': 215.0},
      'heater_bed': {'temperature': 59.8, 'target': 60.0},
      'print_stats': {
        'state': 'printing',
        'filename': 'benchy.gcode',
        'print_duration': 1000.0,
        'info': {'current_layer': 12, 'total_layer': 140},
      },
      'virtual_sdcard': {'progress': 0.25},
    });

    expect(s.state, 'printing');
    expect(s.filename, 'benchy.gcode');
    expect(s.hotend, 210.4);
    expect(s.bedTarget, 60.0);
    expect(s.progress, closeTo(0.25, 1e-9));
    expect(s.currentLayer, 12);
    expect(s.totalLayers, 140);
    expect(s.eta, closeTo(3000, 1e-6)); // 1000s for 25% -> 3000s left

    // Delta update: only extruder temp changed. Everything else must persist.
    s.applyDelta({
      'extruder': {'temperature': 214.9},
    });

    expect(s.hotend, 214.9);
    expect(s.hotendTarget, 215.0); // unchanged, not reset to 0
    expect(s.state, 'printing');
    expect(s.progress, closeTo(0.25, 1e-9));
  });

  test('Creality CFS boxes, fans, chamber and light are read', () {
    final s = PrinterStatus()
      ..applyDelta({
        'box': {
          'T1': {
            'state': 'connect',
            'temperature': '25',
            'dry_and_humidity': '35',
            'color_value': ['0000000', '03ddf57', '-1', '0ffffff'],
            'material_type': ['000001', '000001', '-1', '000002'],
          },
          'T3': {'state': 'None', 'color_value': ['-1', '-1', '-1', '-1']},
        },
        'output_pin fan0': {'value': 0.5},
        'output_pin fan2': {'value': 0.0},
        'output_pin LED': {'value': 1.0},
        PrinterStatus.chamberHeaters.first: {'temperature': 27.0, 'target': 0.0},
      });

    expect(s.cfs, hasLength(1)); // disconnected T3 is skipped
    final box = s.cfs.single;
    expect(box.humidity, 35);
    expect(box.slots.map((x) => x.label), ['1A', '1B', '1C', '1D']);
    expect(box.slots[1].color, 0xFF3DDF57);
    expect(box.slots[2].empty, isTrue);

    expect(s.fans.map((f) => f.label), ['Part cooling', 'Chamber exhaust']);
    expect(s.fans.first.value, 0.5);
    expect(s.led, isTrue);
    expect(s.hasChamber && s.chamberHeatable, isTrue);
    expect(s.chamber, 27.0);
  });

  test('parseCfsColor', () {
    expect(parseCfsColor('0ff1e1e'), 0xFFFF1E1E);
    expect(parseCfsColor('-1'), isNull);
    expect(parseCfsColor('zz'), isNull);
  });

  test('U1 cavity LED reads as the light', () {
    final s = PrinterStatus();
    expect(s.led, isNull);
    s.applyDelta({'led cavity_led': {'color_data': [[0.0, 0.0, 0.0, 0.0]]}});
    expect(s.led, isFalse);
    s.applyDelta({'led cavity_led': {'color_data': [[0.0, 0.0, 0.0, 1.0]]}});
    expect(s.led, isTrue);
  });

  test('U1 DragonBreath heater, cavity sensor, fans and filter', () {
    final s = PrinterStatus();
    s.applyDelta({
      'heater_generic dragonbreath': {'temperature': 31.0, 'target': 50.0},
      'temperature_sensor cavity': {'temperature': 28.0},
      'fan_generic exhaust_fan': {'speed': 0.5},
      'output_pin dragonbreath_filter': {'value': 1.0},
    });
    expect(s.chamberHeatable, isTrue);
    expect(s.chamberHeater, 'heater_generic dragonbreath');
    expect(s.chamber, 31.0);
    expect(s.chamberTarget, 50.0);
    expect(s.fans.map((f) => (f.label, f.value)),
        [('Exhaust', 0.5), ('Heater filter', 1.0)]);
  });

  test('U1 cavity sensor alone is a chamber reading', () {
    final s = PrinterStatus()
      ..applyDelta({'temperature_sensor cavity': {'temperature': 28.0}});
    expect(s.hasChamber, isTrue);
    expect(s.chamberHeatable, isFalse);
    expect(s.chamber, 28.0);
  });

  test('pngSize reads the IHDR size', () {
    final b = Uint8List(24)
      ..setAll(0, [0x89, 0x50, 0x4E, 0x47])
      ..buffer.asByteData().setUint32(16, 480)
      ..buffer.asByteData().setUint32(20, 320);
    expect(pngSize(b), (480, 320));
    expect(pngSize(Uint8List(10)), isNull);
  });

  test('U1 AFC lanes show as an editable filament box', () {
    final s = PrinterStatus()
      ..applyDelta({
        'AFC_lane E1': {'map': 'T1', 'load': true, 'color': '#F8F81C', 'material': 'PETG'},
        'AFC_lane E0': {'map': 'T0', 'load': false, 'color': '#000000', 'material': 'PLA'},
      });
    final box = s.cfs.single;
    expect(box.slots.map((x) => (x.label, x.lane, x.color, x.material)), [
      ('T0', 'E0', null, 'PLA'),
      ('T1', 'E1', 0xFFF8F81C, 'PETG'),
    ]);
  });

  test('Spoolman spool from JSON', () {
    final sp = Spool.fromJson({
      'id': 3,
      'remaining_weight': 812.4,
      'filament': {'name': 'Basic PLA', 'material': 'PLA', 'color_hex': 'FF0000', 'vendor': {'name': 'Sunlu'}},
    });
    expect((sp.id, sp.name, sp.material, sp.color, sp.remaining),
        (3, 'Sunlu Basic PLA', 'PLA', 0xFFFF0000, 812.4));
  });

  test('filament check matches tools to lanes', () {
    final lanes = [
      CfsSlot('T0', 0xFF000000, 'PLA', null, 'E0'),
      CfsSlot('T1', null, 'PLA', null, 'E1'),
    ];
    final needs = toolNeeds({'filament_type': 'PLA;PETG;ABS', 'filament_colour': '#FF8000;#000000;#FFFFFF'}, lanes);
    expect(needs.map((n) => (n.tool, n.type, n.lane?.lane, needMismatch(n))), [
      (0, 'PLA', 'E0', false),
      (1, 'PETG', 'E1', true), // empty lane
      (2, 'ABS', null, true), // no lane feeds T2
    ]);
    expect(toolNeeds({}, lanes), isEmpty);
  });

  test('wall sorts problems first', () {
    PrinterStatus st(String state, {bool online = true}) => PrinterStatus()
      ..online = online
      ..applyDelta({'print_stats': {'state': state}});
    expect([st('paused'), st('printing'), st('standby'), st('standby', online: false)].map(wallRank),
        [0, 1, 2, 0]);
  });

  test("what's new lists versions since the last one seen", () {
    expect(compareVersions('1.10.0', '1.9.9'), 1);
    expect(compareVersions('1.5.0', '1.5.0'), 0);
    expect(notesSince('1.4.0', '1.5.1').map((n) => n.$1), ['1.5.1', '1.5.0']);
    expect(notesSince('1.5.1', '1.5.1'), isEmpty);
    expect(kWhatsNew.first.$1, kAppVersion, reason: 'add notes for the new version');
  });

  test('history finds its bridge snapshots', () {
    final job = PrintJob('sub/My Part (v2).gcode', 'completed',
        DateTime.fromMillisecondsSinceEpoch(1794164500000), 60, 1, true);
    expect(
        snapshotsFor(job, [
          'My_Part_v2___1794164593__end.jpg',
          'My_Part_v2___1794164593__first.jpg',
          'My_Part_v2___1794199999__first.jpg', // another run
          'Other__1794164593__first.jpg',
        ]),
        ['My_Part_v2___1794164593__first.jpg', 'My_Part_v2___1794164593__end.jpg']);
  });

  test('spool checks: grams needed against grams left', () {
    final lane = CfsSlot('T0', 0xFF000000, 'PLA', null, 'E0', 7);
    final needs = toolNeeds({'filament_type': 'PLA', 'filament_weight': [30.0]}, [lane]);
    expect(needs.single.grams, 30.0);
    expect(lowSpool(needs.single, [Spool(7, 'x', 'PLA', null, 20)]), isTrue);
    expect(lowSpool(needs.single, [Spool(7, 'x', 'PLA', null, 500)]), isFalse);
    expect(lowSpool(needs.single, const []), isFalse);
  });

  test('history job spool ids and spool price per kg', () {
    expect(jobSpoolIds({'auxiliary_data': [{'name': 'spool_ids', 'value': [3, 5]}]}), [3, 5]);
    expect(jobSpoolIds({'auxiliary_data': []}), isEmpty);
    expect(Spool.fromJson({'id': 1, 'price': 20, 'initial_weight': 1000, 'filament': {}}).pricePerKg, 20);
    expect(Spool.fromJson({'id': 1, 'filament': {'price': 15, 'weight': 750}}).pricePerKg, 20);
  });

  test('lanes carry their linked spool', () {
    final s = PrinterStatus()
      ..applyDelta({'AFC_lane E0': {'map': 'T0', 'load': true, 'color': '#000000', 'material': 'PLA', 'spool_id': 4}});
    expect(s.cfs.single.slots.single.spoolId, 4);
  });

  test('settings backup round-trips', () async {
    SharedPreferences.setMockInitialValues({'printers': <String>['{}'], 'wallSort': true});
    await settings.load();
    final b = settings.exportAll();
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    await settings.importAll(jsonDecode(jsonEncode(b)) as Map<String, dynamic>);
    expect(settings.flag('wallSort', false), isTrue);
    expect(settings.strings('printers'), ['{}']);
  });

  test('history orders pictures: first, timed, end', () {
    final job = PrintJob('a.gcode', 'completed', DateTime.fromMillisecondsSinceEpoch(1000000), 60, 1, true);
    expect(snapshotsFor(job, ['a__1000__end.jpg', 'a__1000__t20.jpg', 'a__1000__first.jpg', 'a__1000__t10.jpg']),
        ['a__1000__first.jpg', 'a__1000__t10.jpg', 'a__1000__t20.jpg', 'a__1000__end.jpg']);
  });

  test('spool QR labels round-trip', () {
    expect(spoolFromQr(spoolQr(12)), 12);
    expect(spoolFromQr('http://192.168.68.64:7912/spool/show/7'), 7);
    expect(spoolFromQr('PHB1:xyz'), isNull);
  });

  test('filament per week buckets jobs by Monday', () {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime(2026, 11, 8); // a Sunday
    PrintJob job(DateTime at) => PrintJob('a.gcode', 'completed', at, 60, 1000, true);
    final w = gramsPerWeek([job(DateTime(2026, 11, 3)), job(DateTime(2026, 10, 27)), job(DateTime(2025, 1, 1))], now,
        weeks: 2);
    expect(w.map((e) => e.$1), [DateTime(2026, 10, 26), DateTime(2026, 11, 2)]);
    expect(w[0].$2, closeTo(w[1].$2, 0.001));
    expect(w[1].$2, greaterThan(0));
  });

  test('ntfy poll lines become recent alerts, newest first', () {
    final a = parseNtfyPoll('{"event":"open"}\n'
        '{"event":"message","time":100,"title":"U1: print finished","message":"cube"}\n'
        '{"event":"message","time":200,"title":"U1: first layer done","message":"x","attachment":{"url":"https://n/p.jpg"}}\n');
    expect(a.map((x) => x.title), ['U1: first layer done', 'U1: print finished']);
    expect(a.first.picture, 'https://n/p.jpg');
  });
}

