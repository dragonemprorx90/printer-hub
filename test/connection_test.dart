import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/slicer.dart';

void main() {
  test('printers keep their connection choice; old ones default to direct first', () {
    const p = Printer(name: 'U1', host: '192.168.68.66', connection: Connection.relay, slicerUrl: '100.85.247.10:7071');
    final back = Printer.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect([back.connection, back.slicerUrl], [Connection.relay, '100.85.247.10:7071']);
    expect(Printer.fromJson({'name': 'K2', 'host': '1.2.3.4'}).connection, Connection.auto);
    expect(Printer.fromJson({'name': 'K2', 'host': '1.2.3.4', 'connection': 'nonsense'}).connection, Connection.auto);
  });

  test('slicer address: host:port, a URL, or the default port', () {
    expect('${slicerBase('100.85.247.10:7071')}', 'http://100.85.247.10:7071');
    expect('${slicerBase(' nas.local ')}', 'http://nas.local:7070');
    expect('${slicerBase('https://nas.example/x')}', 'https://nas.example:7070');
    expect(slicerBase(''), isNull);
    expect(slicerBase(null), isNull);
  });

  test('slicing goes straight to the slicer address, unless remote access only', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final seen = <String>[];
    server.listen((r) async {
      seen.add('${r.method} ${r.uri}');
      await r.drain<void>();
      r.response.headers.contentType = ContentType.json;
      r.response.write(r.uri.path == '/slicer/presets'
          ? jsonEncode({'printers': [
              {'id': 'u1', 'name': 'Snapmaker U1', 'tools': 4, 'process': 'p', 'processes': ['p'], 'filaments': ['f']},
            ]})
          : '{"id":"j1"}');
      await r.response.close();
    });
    addTearDown(() => server.close(force: true));
    final addr = '127.0.0.1:${server.port}';

    final c = MoonrakerClient(host: '127.0.0.1', port: 1, connection: Connection.direct, slicerUrl: addr);
    final (h, release) = await c.bridgeClient();
    final api = SlicerApi(h);
    expect((await api.presets()).single.tools, 4);
    expect(await api.start(utf8.encode('x'), name: 'a.stl', printer: 'u1', process: 'p', filaments: ['f']), 'j1');
    expect(seen.last, startsWith('POST /slicer/jobs?printer=u1'));
    release();

    // Remote access only never uses the address; no pairing -> a clear error.
    final relayOnly = MoonrakerClient(host: '127.0.0.1', port: 1, connection: Connection.relay, slicerUrl: addr);
    await expectLater(relayOnly.bridgeClient(), throwsA(predicate((e) => '$e'.contains('Pair one first'))));

    // A slicer address that doesn't answer, direct only: says which address.
    await server.close(force: true);
    final gone = MoonrakerClient(host: '127.0.0.1', port: 1, connection: Connection.direct, slicerUrl: addr);
    await expectLater(gone.bridgeClient(), throwsA(predicate((e) => '$e'.contains(addr))));
  });
}
