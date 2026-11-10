import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/moonraker.dart';

/// A tiny Moonraker: answers JSON-RPC over a websocket, records G-code
/// scripts, and reports [z] / [state]. Scripts finish after [delay].
class FakeMoonraker {
  final HttpServer server;
  final scripts = <String>[];
  double z;
  String state;
  Duration delay;
  FakeMoonraker._(this.server, this.z, this.state, this.delay);

  static Future<FakeMoonraker> start({double z = 20, String state = 'standby'}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = FakeMoonraker._(s, z, state, Duration.zero);
    s.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.write('{"result": {}}');
        return req.response.close();
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) async {
        final m = jsonDecode('$raw') as Map;
        final status = {
          'print_stats': {'state': f.state},
          'toolhead': {'homed_axes': 'xyz'},
          'gcode_move': {'gcode_position': [10, 10, f.z, 0], 'homing_origin': [0, 0, 0, 0]},
        };
        Object? result = switch (m['method']) {
          'printer.objects.list' => {'objects': status.keys.toList()},
          'printer.objects.subscribe' || 'printer.objects.query' => {'status': status},
          _ => <String, Object>{},
        };
        if (m['method'] == 'printer.gcode.script') {
          f.scripts.add('${m['params']['script']}');
          await Future.delayed(f.delay);
          result = 'ok';
        }
        ws.add(jsonEncode({'jsonrpc': '2.0', 'id': m['id'], 'result': result}));
      });
    });
    return f;
  }
}

Future<MoonrakerClient> connect(FakeMoonraker f) async {
  final c = MoonrakerClient(host: '127.0.0.1', port: f.server.port)..connect();
  for (var i = 0; i < 100 && !c.status.online; i++) {
    await Future.delayed(const Duration(milliseconds: 20));
  }
  expect(c.status.online, isTrue);
  return c;
}

void main() {
  test('Z toward the bed stops at Z 0; refused when unhomed or already there', () {
    expect(safeZStep(-10, z: 4, zHomed: true), -4); // the K2 crash: 10 mm asked, 4 mm allowed
    expect(safeZStep(-1, z: 4, zHomed: true), -1);
    expect(safeZStep(-1, z: 0, zHomed: true), isNull);
    expect(safeZStep(-1, z: 4, zHomed: false), isNull);
    expect(safeZStep(10, z: -2, zHomed: false), 10, reason: 'moving away is always allowed');
  });

  test('homing lifts the nozzle clear of the bed first', () {
    expect(homeLift(0.2, zHomed: true), closeTo(2.8, 1e-9));
    expect(homeLift(12, zHomed: true), 0);
    expect(homeLift(0.2, zHomed: false), 0, reason: 'unhomed Z can\'t be moved safely');
  });

  test('live Z offset stays within limits, and can always come back', () {
    expect(zOffsetAllowed(-0.45, -0.05), isTrue);
    expect(zOffsetAllowed(-0.5, -0.01), isFalse);
    expect(zOffsetAllowed(-0.8, 0.05), isTrue);
    expect(zOffsetAllowed(1.0, 0.01), isFalse);
  });

  test('the client sends a clamped, waited move and refuses a second tap meanwhile', () async {
    final f = await FakeMoonraker.start(z: 4);
    final c = await connect(f);

    f.delay = const Duration(milliseconds: 300);
    final first = c.jog('Z', -10);
    await Future.delayed(const Duration(milliseconds: 100));
    await expectLater(c.jog('Z', -10), throwsA(isA<MoonrakerError>()));
    expect(await first, -4);
    expect(f.scripts.single, contains('G1 Z-4.000 F600'));
    expect(f.scripts.single, endsWith('M400'));

    f
      ..delay = Duration.zero
      ..z = 1;
    await c.home();
    expect(f.scripts.last, startsWith('G91\nG1 Z2.00 F600\nG90\nG28'));

    await f.server.close(force: true);
  });

  test('home, moves and motors-off are refused during a print', () async {
    final f = await FakeMoonraker.start(state: 'printing');
    final c = await connect(f);
    await expectLater(c.home(), throwsA(isA<MoonrakerError>()));
    await expectLater(c.jog('X', 10), throwsA(isA<MoonrakerError>()));
    await expectLater(c.motorsOff(), throwsA(isA<MoonrakerError>()));
    expect(f.scripts, isEmpty);
    await c.setSpeed(1000);
    expect(f.scripts.last, 'M220 S300');
    await f.server.close(force: true);
  });
}
