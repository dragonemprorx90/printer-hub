import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/camera.dart';
import 'package:printer_hub/discovery.dart';
import 'package:printer_hub/gcode.dart';
import 'package:printer_hub/history_page.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/settings.dart';
import 'package:printer_hub/settings_page.dart';
import 'package:printer_hub/update.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });

  test('update: version comparison and platform asset', () {
    expect(isNewer('v1.2.0', '1.1.0'), isTrue);
    expect(isNewer('1.1.0', '1.1.0'), isFalse);
    expect(isNewer('v1.0.9', '1.1.0'), isFalse);
    expect(isNewer('2.0', '1.9.9'), isTrue);
    expect(isNewer('1.1.1+5', '1.1.0'), isTrue);
    final assets = [
      {'name': 'PrinterHub-1.2.0.ipa', 'browser_download_url': 'u/ipa'},
      {'name': 'PrinterHub-1.2.0.apk', 'browser_download_url': 'u/apk'},
      {'name': 'PrinterHub-1.2.0.dmg', 'browser_download_url': 'u/dmg'},
    ];
    expect(pickAsset(assets, platform: 'ios'), 'u/ipa');
    expect(pickAsset(assets, platform: 'android'), 'u/apk');
    expect(pickAsset(assets, platform: 'macos'), 'u/dmg');
    expect(pickAsset(assets, platform: 'linux'), isNull);
  });

  test('gcode: picks the largest embedded thumbnail', () {
    final small = base64.encode([1, 2, 3]);
    final big = base64.encode([9, 8, 7, 6]);
    final head = '; generated\n'
        '; thumbnail begin 96x96 ${small.length}\n; $small\n; thumbnail end\n'
        '; thumbnail begin 300x300 ${big.length}\n; ${big.substring(0, 4)}\n; ${big.substring(4)}\n; thumbnail end\n'
        'G28\n';
    expect(parseThumbnail(head), [9, 8, 7, 6]);
    expect(parseThumbnail('G28\nG1 X10\n'), isNull);
  });

  test('gcode: splits extrusion moves into layers, ignores travel', () {
    final m = parseGcode([
      'G90', 'M83',
      'G1 Z0.2 F600',
      'G1 X10 Y10 F9000', // travel
      'G1 X20 Y10 E1.0', // layer 1
      'G1 X20 Y20 E1.0 ; comment',
      'G1 Z0.4',
      'G0 X30 Y30', // travel
      'G1 X40 Y30 E0.5', // layer 2
      'G1 X40 Y40 E-0.8', // retract, not a line
    ].join('\n'));
    expect(m.layers, hasLength(2));
    expect(m.z, [0.2, 0.4]);
    expect(m.layers[0].toList(), [10, 10, 20, 10, 20, 10, 20, 20]);
    expect(m.layers[1].toList(), [30, 30, 40, 30]);
    expect(m.segments, 3);
    expect(m.maxX, 40);
  });

  test('gcode: absolute extrusion and G92 resets', () {
    final m = parseGcode('M82\nG1 Z0.3\nG92 E0\nG1 X5 Y0 E1\nG1 X5 Y5 E1\nG1 X0 Y5 E2\n');
    expect(m.layers.single.length ~/ 4, 2); // the E1→E1 move is travel
  });

  test('history: material from metadata or filename', () {
    expect(jobMaterial({'metadata': {'filament_type': 'PETG;PLA'}, 'filename': 'x'}), 'PETG');
    expect(jobMaterial({'filename': 'Body1_PLA_1h28m17s.gcode'}), 'PLA');
    expect(jobMaterial({'filename': 'part-abs-v2.gcode'}), 'ABS');
    expect(jobMaterial({'filename': 'PLACEHOLDER.gcode'}), isNull);
  });

  test('history: filament grams, cost and CSV', () {
    // 1 m of 1.75 mm PLA ≈ 2.98 g.
    expect(filamentGrams(1000), closeTo(2.98, 0.01));
    final job = PrintJob('a,b.gcode', 'completed', DateTime.utc(2026, 1, 2), 3600, 1000, true,
        material: 'PLA');
    // 2.98 g at 20/kg + 1 h × 350 W × 0.30/kWh.
    expect(jobCost(job), closeTo(0.0596 + 0.105, 0.001));
    final csv = historyCsv([job]).trim().split('\n');
    expect(csv.first, startsWith('file,status'));
    expect(csv.last, startsWith('"a,b.gcode",completed,2026-01-02'));
  });

  test('camera: MJPEG splitter yields whole frames across chunks', () {
    final s = JpegSplitter();
    final f1 = [0xFF, 0xD8, 1, 2, 0xFF, 0xD9];
    final f2 = [0xFF, 0xD8, 3, 0xFF, 0xD9];
    final stream = [...'--b\r\n'.codeUnits, ...f1, ...'\r\n--b\r\n'.codeUnits, ...f2];
    final a = s.add(stream.sublist(0, 9));
    final b = s.add(stream.sublist(9));
    expect([...a, ...b].map((f) => f.toList()), [f1, f2]);
    expect(s.add([0xFF, 0xD8, 9]), isEmpty); // incomplete frame is held
    expect(s.add([0xFF, 0xD9]).single.toList(), [0xFF, 0xD8, 9, 0xFF, 0xD9]);
  });

  test('printers round-trip through a share code', () {
    final p = [
      const Printer(name: 'K2 Plus', host: '192.168.68.53'),
      const Printer(name: 'U1', host: '10.0.0.7', port: 7126, apiKey: 'k'),
    ];
    final back = importPrinters(exportPrinters(p));
    expect(back.map((x) => x.key), ['192.168.68.53:7125', '10.0.0.7:7126']);
    expect(back.last.apiKey, 'k');
    expect(() => importPrinters('hello'), throwsFormatException);
  });

  test('discovery scans only private networks', () {
    expect(lanPrefixes(['192.168.68.21', '10.1.2.3', '172.20.0.9', '8.8.8.8', '172.40.1.1', '::1']),
        unorderedEquals(['192.168.68', '10.1.2', '172.20.0']));
  });

  test('status: mesh, objects, extruders, offsets', () {
    final s = PrinterStatus()
      ..applyDelta({
        'extruder': {'temperature': 200, 'target': 210, 'pressure_advance': 0.04},
        'extruder1': {'temperature': 30, 'target': 0},
        'toolhead': {'extruder': 'extruder', 'axis_maximum': [350, 350, 360, 0]},
        'gcode_move': {'homing_origin': [0, 0, -0.05, 0]},
        'bed_mesh': {
          'profile_name': 'default',
          'probed_matrix': [
            [0.1, -0.1],
            [0.0, 0.2],
          ],
        },
        'exclude_object': {
          'objects': [
            {'name': 'CUBE', 'center': [10, 20], 'polygon': [[0, 0], [20, 0], [20, 40]]},
          ],
          'excluded_objects': ['CUBE'],
          'current_object': null,
        },
      });
    expect(s.extruders, ['extruder', 'extruder1']);
    expect(s.toolTarget('extruder'), 210);
    expect(s.pressureAdvance, 0.04);
    expect(s.zOffset, -0.05);
    expect(s.axisMax.take(2), [350, 350]);
    expect(s.mesh, [
      [0.1, -0.1],
      [0.0, 0.2],
    ]);
    expect(s.objects.single.polygon.last, (20.0, 40.0));
    expect(s.objects.single.center, (10.0, 20.0));
    expect(s.excludedObjects, {'CUBE'});
    expect(s.currentObject, isNull);
  });

  test('settings: presets and favourites persist', () {
    settings.setPresets('bed', [0, 65]);
    expect(settings.presets('bed'), [0, 65]);
    expect(settings.presets('nozzle'), contains(210)); // default
    settings.toggleFavourite('macros.x', 'PURGE');
    expect(settings.isFavourite('macros.x', 'PURGE'), isTrue);
    settings.toggleFavourite('macros.x', 'PURGE');
    expect(settings.isFavourite('macros.x', 'PURGE'), isFalse);
  });
}
