import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/moonraker.dart';

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
        PrinterStatus.chamberHeater: {'temperature': 27.0, 'target': 0.0},
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
}
