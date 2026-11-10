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

  test('U1 lanes become Moonraker lane_data for OrcaSlicer', () {
    final d = laneData({
      'AFC_lane E1': {'map': 'T1', 'load': true, 'color': '#F8F81C', 'material': 'PLA', 'spool_id': 4},
      'AFC_lane E0': {'map': 'T0', 'load': false, 'color': '#000000', 'material': 'PLA', 'spool_id': 0},
    });
    expect(d['T1'], {'lane': '1', 'name': 'E1', 'color': '#F8F81C', 'material': 'PLA', 'spool_id': 4});
    expect(d['T0'], {'lane': '0', 'name': 'E0', 'color': '', 'material': ''});
  });

  test('old snapshots are pruned by age and count, undated names kept', () {
    final now = DateTime.utc(2026, 11, 9);
    int t(int daysAgo) => now.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch ~/ 1000;
    final names = ['a__${t(1)}__end.jpg', 'b__${t(200)}__first.jpg', 'c__${t(2)}__t1.jpg', 'notes.txt'];
    expect(snapshotsToPrune(names, now), ['b__${t(200)}__first.jpg']);
    expect(snapshotsToPrune(names, now, keep: 1), ['c__${t(2)}__t1.jpg', 'b__${t(200)}__first.jpg']);
  });

  test('one odd frame does not alert; sustained spaghetti does', () {
    final w = FailureWatch();
    expect(w.add(3.2), isFalse); // a single frame
    for (var i = 0; i < 10; i++) {
      expect(w.add(0), isFalse);
    }
    expect(w.add(0.3), isFalse); // a stray low-confidence box, over and over
    for (var i = 0; i < 30; i++) {
      expect(w.add(0.3), isFalse);
    }
    w.reset();
    expect([w.add(3.2), w.add(3.2)], [false, true]); // about a minute of it
  });
}
