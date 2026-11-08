import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:printer_hub/orca_link.dart';

void main() {
  test('printer slugs', () {
    expect(printerSlug('K2 Plus'), 'k2-plus');
    expect(printerSlug('BuOmar U1!'), 'buomar-u1');
  });

  test('Orca (OctoPrint upload) reaches Printer Hub', () async {
    final got = <OrcaUpload>[];
    final link = OrcaLink(onUpload: got.add, printers: () => const [], port: 17126);
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
}
