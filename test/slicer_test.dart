import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:printer_hub/slicer.dart';

void main() {
  test('slicer API talks /slicer/* and reads presets and jobs', () async {
    final seen = <http.Request>[];
    final api = SlicerApi(MockClient((req) async {
      seen.add(req);
      return switch (req.url.path) {
        '/slicer/presets' => http.Response(
            jsonEncode({
              'printers': [
                {'id': 'u1', 'name': 'Snapmaker U1', 'tools': 4, 'process': '0.20 Standard',
                 'processes': ['0.20 Standard'], 'filaments': ['Generic PLA', 'Generic PETG']},
              ]
            }),
            200),
        '/slicer/jobs' => http.Response('{"id":"abc"}', 200),
        _ => http.Response('{"state":"done","files":["Sliced/cube.gcode"]}', 200),
      };
    }));

    final p = (await api.presets()).single;
    expect([p.id, p.tools, p.filaments.length], ['u1', 4, 2]);

    final id = await api.start(Uint8List.fromList([1, 2, 3]),
        name: 'cube.stl', printer: 'u1', process: '0.20 Standard',
        filaments: ['Generic PLA', 'Generic PETG'], tool: 1, folder: 'Sliced');
    expect(id, 'abc');
    final post = seen.last;
    expect(post.method, 'POST');
    expect(post.bodyBytes, [1, 2, 3]);
    expect(post.url.queryParameters, containsPair('filaments', 'Generic PLA;Generic PETG'));
    expect(post.url.queryParameters['tool'], '1');

    expect((await api.job(id))['files'], ['Sliced/cube.gcode']);
    expect(seen.last.url.path, '/slicer/jobs/abc');
  });

  test('slicer errors read well', () {
    expect(slicerError(400, '{"error":"Unknown printer"}'), 'Unknown printer');
    // Bridge can't reach the container / bridge too old (Moonraker's 404).
    expect(slicerError(502, 'Connection refused'), contains('COMPOSE_PROFILES'));
    expect(slicerError(404, '<html>404: Not Found</html>'), contains('slicer isn\'t running'));
    expect(slicerError(500, 'boom'), 'Slicer error (HTTP 500)');
  });
}
