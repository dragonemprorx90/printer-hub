import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/orca_link.dart' show parseMultipart;
import 'package:printer_hub/slice_where.dart';

void main() {
  test('choices: the app editor by default, the last choice first', () {
    expect(sliceChoices(isMac: false, orcaHere: false), [SliceWhere.app, SliceWhere.mac]);
    expect(sliceChoices(isMac: false, orcaHere: false, last: 'mac'), [SliceWhere.mac, SliceWhere.app]);
    expect(sliceChoices(isMac: true, orcaHere: true, last: 'orca'), [SliceWhere.orca, SliceWhere.app]);
    // No Orca on this Mac: just the editor, and a stale choice falls back to it.
    expect(sliceChoices(isMac: true, orcaHere: false, last: 'orca'), [SliceWhere.app]);
    expect(sliceChoices(isMac: true, orcaHere: true, last: 'mac'), [SliceWhere.app, SliceWhere.orca]);
  });

  test('names from the web cannot leave the folder', () {
    expect(safeModelName('Benchy v2.stl'), 'Benchy v2.stl');
    expect(safeModelName('../../.zshrc'), 'zshrc');
    expect(safeModelName(r'a\b/c;rm -rf.3mf'), 'c_rm -rf.3mf');
    expect(safeModelName('...'), 'model.stl');
  });

  test('phone drops a model in the inbox; the Mac opens it and clears it', () async {
    final files = <String, Uint8List>{}; // path under gcodes -> bytes
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = Uint8List.fromList(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
      final p = req.uri.path;
      if (p == '/server/files/upload') {
        final parts = parseMultipart(body, req.headers.contentType!.parameters['boundary']!);
        final folder = utf8.decode(parts['path']!.$2);
        files['$folder/${parts['file']!.$1}'] = parts['file']!.$2;
        req.response.write('{}');
      } else if (p == '/server/files/directory') {
        final dir = req.uri.queryParameters['path']!.replaceFirst('gcodes/', '');
        final mine = [for (final k in files.keys) if (k.startsWith('$dir/')) k.substring(dir.length + 1)];
        if (mine.isEmpty) {
          req.response.statusCode = 404;
        } else {
          req.response.write(jsonEncode({
            'result': {'dirs': [], 'files': [for (final f in mine) {'filename': f, 'size': 1, 'modified': 1}]}
          }));
        }
      } else if (p.startsWith('/server/files/gcodes/')) {
        final path = Uri.decodeComponent(p.substring('/server/files/gcodes/'.length));
        if (req.method == 'DELETE') {
          files.remove(path);
          req.response.write('{}');
        } else {
          req.response.add(files[path]!);
        }
      }
      await req.response.close();
    });
    final c = MoonrakerClient(host: '127.0.0.1', port: server.port);

    expect(await takeInbox(c, open: (_, _) async => fail('nothing to open')), isEmpty);

    await c.upload('cube.stl', Uint8List.fromList([1, 2, 3]), folder: kInbox);
    expect(files.keys, ['$kInbox/cube.stl']);

    // Orca failing to open keeps the file for the next try.
    expect(await takeInbox(c, open: (_, _) async => throw 'no Orca'), isEmpty);
    expect(files, isNotEmpty);

    final opened = <String, List<int>>{};
    expect(await takeInbox(c, open: (n, b) async => opened[n] = b), ['cube.stl']);
    expect(opened, {'cube.stl': [1, 2, 3]});
    expect(files, isEmpty);
    await server.close(force: true);
  });
}
