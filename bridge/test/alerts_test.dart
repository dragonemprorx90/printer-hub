import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../bin/bridge.dart';

void main() {
  test('fume-heavy materials turn the heater filter on', () {
    expect(fumeMaterial('ABS'), isTrue);
    expect(fumeMaterial('PLA;ASA'), isTrue);
    expect(fumeMaterial('PA12-CF'), isTrue);
    expect(fumeMaterial('PLA'), isFalse);
    expect(fumeMaterial('PETG'), isFalse);
    expect(fumeMaterial('PCTG'), isFalse);
  });

  test('alerts carry a camera picture when there is one', () async {
    final jpeg = [0xFF, 0xD8, 9, 9, 0xFF, 0xD9];
    HttpRequest? got;
    List<int>? body;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((req) async {
      if (req.uri.path == '/snap.jpg') {
        req.response.headers.contentType = ContentType('image', 'jpeg');
        req.response.add(jpeg);
      } else {
        got = req;
        body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      }
      await req.response.close();
    });
    final a = Alerts(Uri.parse('http://127.0.0.1:${s.port}/topic'), '127.0.0.1', 9,
        name: 'U1', camera: CameraFeed(Uri.parse('http://127.0.0.1:${s.port}/snap.jpg')));
    await a.send('U1: print finished ✅', 'cube.gcode', picture: true);
    expect(got!.method, 'PUT');
    expect(got!.uri.path, '/topic');
    expect(body, jpeg);
    final title = got!.headers.value('Title')!;
    expect(utf8.decode(base64.decode(title.substring(10, title.length - 2))), 'U1: print finished ✅');
    await s.close(force: true);
  });

  test('quiet hours wrap past midnight', () {
    final q = parseQuietHours('23-7');
    expect(q, (23, 7));
    expect([22, 23, 0, 6, 7].map((h) => inQuietHours(q, h)), [false, true, true, true, false]);
    expect(inQuietHours(parseQuietHours('1-5'), 3), isTrue);
    expect(parseQuietHours('nope'), isNull);
    expect(inQuietHours(null, 3), isFalse);
  });

  test('snapshot names carry the file and start time', () {
    expect(snapshotName('My Part (v2).gcode', DateTime.fromMillisecondsSinceEpoch(1794164593000), 'first'),
        'My_Part_v2___1794164593__first.jpg');
  });
}

