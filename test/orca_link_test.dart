import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/orca_link.dart';

void main() {
  test('printer slugs', () {
    expect(printerSlug('K2 Plus'), 'k2-plus');
    expect(printerSlug('BuOmar U1!'), 'buomar-u1');
  });

  test('Orca (OctoPrint upload) reaches Printer Hub', () async {
    final got = <OrcaUpload>[];
    final link = OrcaLink(onUpload: got.add, printers: () => const [], port: 17126, loadPorts: () => {}, savePorts: (_) {});
    await link.start();
    addTearDown(link.stop);

    final v = await http.get(Uri.parse('http://127.0.0.1:17126/api/version'));
    expect(jsonDecode(v.body)['text'], contains('OctoPrint'));

    final gcode = Uint8List.fromList(utf8.encode(';sliced\nG28\r\nG1 X10\n'));
    final req = http.MultipartRequest('POST', Uri.parse('http://127.0.0.1:17126/k2-plus/api/files/local'))
      ..headers['X-Api-Key'] = 'anything'
      ..fields['print'] = 'true'
      ..fields['path'] = ''
      ..files.add(http.MultipartFile.fromBytes('file', gcode, filename: 'cube_PLA_10m.gcode'));
    final r = await req.send();
    expect(r.statusCode, 201);
    expect(got.single.name, 'cube_PLA_10m.gcode');
    expect(got.single.bytes, gcode);
    expect(got.single.print, isTrue);
    expect(got.single.printer, 'k2-plus');

    final list = await http.get(Uri.parse('http://127.0.0.1:17126/hub/printers'));
    expect(jsonDecode(list.body), isEmpty);
  });

  test('filaments in Orca slot order, U1 lanes by tool', () {
    final s = PrinterStatus()
      ..applyDelta({
        'AFC_lane E1': {'map': 'T0', 'load': true, 'color': '#F8F81C', 'material': 'PETG'},
        'AFC_lane E0': {'map': 'T1', 'load': false, 'color': '#000000', 'material': 'PLA'},
      });
    expect(hubFilaments(s), [
      {'tool': 0, 'label': 'T0', 'material': 'PETG', 'color': '#F8F81C'},
      {'tool': 1, 'label': 'T1', 'material': '', 'color': null},
    ]);
  });

  test('browser requests and header-less actions are refused', () async {
    final link = OrcaLink(onUpload: (_) {}, printers: () => const [], port: 17127, loadPorts: () => {}, savePorts: (_) {});
    await link.start();
    addTearDown(link.stop);
    final fromPage = await http.get(Uri.parse('http://127.0.0.1:17127/hub/printers'),
        headers: {'Origin': 'https://evil.example'});
    expect(fromPage.statusCode, 403);
    final noHeader = await http.post(Uri.parse('http://127.0.0.1:17127/hub/action?printer=x&do=cancel'));
    expect(noHeader.statusCode, 403);
  });

  test('K2 CFS codes are hidden, not shown as materials', () {
    final s = PrinterStatus()
      ..applyDelta({
        'box': {
          'T1': {'state': 'connect', 'color_value': ['0ff1e1e'], 'material_type': ['000001']},
        },
      });
    expect(hubFilaments(s).single['material'], '');
    expect(hubFilaments(s).single['color'], '#FF1E1E');
  });

  test('proxy ports belong to a printer, not a list position', () {
    var m = assignProxyPorts({}, ['u1:7125', 'k2:7125'], 7130);
    expect(m, {'u1:7125': 7130, 'k2:7125': 7131});
    // Reordered list: same ports.
    m = assignProxyPorts(m, ['k2:7125', 'u1:7125'], 7130);
    expect(m, {'u1:7125': 7130, 'k2:7125': 7131});
    // U1 removed, new printer added: it must not get the U1's old port.
    m = assignProxyPorts(m, ['k2:7125', 'new:7125'], 7130);
    expect(m['new:7125'], 7132);
  });

  test('/hub/printers reports each printer its own proxy', () async {
    var saved = <String, int>{'b:7125': 17140};
    final list = [const Printer(name: 'A', host: 'a'), const Printer(name: 'B', host: 'b')];
    final link = OrcaLink(
        onUpload: (_) {}, printers: () => list, port: 17136, loadPorts: () => saved, savePorts: (m) => saved = m);
    await link.start();
    addTearDown(link.stop);
    final r = jsonDecode((await http.get(Uri.parse('http://127.0.0.1:17136/hub/printers'))).body) as List;
    expect({for (final p in r) p['name']: p['proxy']}, {'A': '127.0.0.1:17141', 'B': '127.0.0.1:17140'});
  });
}

