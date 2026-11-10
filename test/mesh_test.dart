import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printer_hub/mesh.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/settings.dart';
import 'package:printer_hub/slicer.dart';

/// A w × d × h box from (0,0,0), outward winding.
Float32List box(double w, double d, double h) {
  final c = [
    [0.0, 0.0, 0.0], [w, 0.0, 0.0], [w, d, 0.0], [0.0, d, 0.0],
    [0.0, 0.0, h], [w, 0.0, h], [w, d, h], [0.0, d, h],
  ];
  const f = [
    [0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
    [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7],
  ];
  return Float32List.fromList([for (final t in f) for (final i in t) ...c[i]]);
}

List<double> size(Float32List v) {
  final (lo, hi) = turnedBounds(v, identity, 1);
  return [for (var i = 0; i < 3; i++) hi[i] - lo[i]];
}

void main() {
  test('STL: binary round trip and ASCII', () {
    final v = box(20, 30, 40);
    expect(parseStl(toStl(v)).v, v);
    final ascii = 'solid x\nfacet normal 0 0 1\nouter loop\nvertex 1 2 3\nvertex 4 5 6\n'
        'vertex 7 8 9.5\nendloop\nendfacet\nendsolid x\n';
    expect(parseStl(Uint8List.fromList(utf8.encode(ascii))).v, [1, 2, 3, 4, 5, 6, 7, 8, 9.5]);
    expect(() => parseStl(Uint8List(10)), throwsFormatException);
  });

  test('placement: centred on the point, resting on the plate, turned', () {
    final v = box(20, 20, 60);
    var p = const Placement(x: 175, y: 100);
    var out = place(v, p, turnedBounds(v, p.rot, 1));
    var (lo, hi) = turnedBounds(out, identity, 1);
    expect([lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]], [165, 185, 90, 110, 0, 60]);

    // Lying on its side: 90° about X, then twice the size.
    p = p.copyWith(rot: axisRot(0, 90), scale: 2);
    out = place(v, p, (
      [for (final x in turnedBounds(v, p.rot, 1).$1) x * 2],
      [for (final x in turnedBounds(v, p.rot, 1).$2) x * 2],
    ));
    (lo, hi) = turnedBounds(out, identity, 1);
    for (final (a, b) in [(hi[0] - lo[0], 40.0), (hi[1] - lo[1], 120.0), (hi[2] - lo[2], 40.0), (lo[2], 0.0)]) {
      expect(a, closeTo(b, 1e-3));
    }
  });

  test('lay flat turns any face normal straight down', () {
    for (final n in [(1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, 0.0, -1.0), (0.3, -0.5, 0.2), (0.0, 1.0, 0.0)]) {
      final r = downRot(n.$1, n.$2, n.$3);
      final l = [n.$1, n.$2, n.$3];
      final len = l.fold(0.0, (s, x) => s + x * x);
      final down = [for (var i = 0; i < 3; i++) r[i * 3] * l[0] + r[i * 3 + 1] * l[1] + r[i * 3 + 2] * l[2]];
      expect(down[0], closeTo(0, 1e-9));
      expect(down[1], closeTo(0, 1e-9));
      expect(down[2] * down[2], closeTo(len, 1e-9));
      expect(down[2], lessThan(0));
    }
    // The top face of a box laid down: it turns upside down, same size.
    final v = box(20, 30, 40);
    final (nx, ny, nz) = normalOf(v, 2); // a top triangle
    expect(nz, greaterThan(0));
    final s = size(place(v, Placement(x: 0, y: 0, rot: downRot(nx, ny, nz)), turnedBounds(v, downRot(nx, ny, nz), 1)));
    expect(s[2], closeTo(40, 1e-3));
  });

  test('decimate keeps big meshes drawable', () {
    // A 300 × 300 grid (180k triangles) on a wavy surface.
    final out = <double>[];
    for (var i = 0; i < 300; i++) {
      for (var j = 0; j < 300; j++) {
        double z(int a, int b) => (a % 7) * 0.1 + (b % 5) * 0.1;
        final p = [i, j, i + 1, j, i + 1, j + 1, i, j + 1];
        for (final t in [[0, 1, 2], [0, 2, 3]]) {
          for (final k in t) {
            out.addAll([p[k * 2] * 0.5, p[k * 2 + 1] * 0.5, z(p[k * 2], p[k * 2 + 1])]);
          }
        }
      }
    }
    final m = Mesh(Float32List.fromList(out));
    final d = decimate(m, 40000);
    expect(d.triangles, lessThanOrEqualTo(40000));
    expect(d.triangles, greaterThan(5000));
    final a = size(m.v), b = size(d.v);
    for (var i = 0; i < 2; i++) {
      expect(b[i], closeTo(a[i], 1.0));
    }
    expect(decimate(Mesh(box(1, 1, 1))).triangles, 12);
  });

  test('camera: the plate point under the finger, and picking', () {
    final cam = Camera.forBed([350, 350, 350]);
    final view = Projection(cam, const Size(800, 600));
    final s = Float32List(2);
    view.project(120, 80, 0, s, 0);
    final back = view.onPlate(Offset(s[0], s[1]))!;
    expect(back.dx, closeTo(120, 1e-3));
    expect(back.dy, closeTo(80, 1e-3));
    // The orbit target is the middle of the screen.
    view.project(cam.tx, cam.ty, cam.tz, s, 0);
    expect([s[0], s[1]], [closeTo(400, 1e-6), closeTo(300, 1e-6)]);

    final v = place(box(40, 40, 40), const Placement(x: 175, y: 175), turnedBounds(box(40, 40, 40), identity, 1));
    view.project(175, 175, 20, s, 0);
    expect(pick(v, view, Offset(s[0], s[1])), isNotNull);
    expect(pick(v, view, const Offset(20, 20)), isNull);
  });

  test('settings JSON: preset unless changed, shorthands, toolheads', () {
    expect(settingsJson({}, tool: 0, tools: 1), isNull);
    final j = jsonDecode(settingsJson({
      'layer_height': '0.28',
      'support': 'tree(auto)',
      'sparse_infill_density': '35',
      'inner_speed': '200',
      'nozzle_temperature': '225',
    }, tool: 1, tools: 4)!);
    expect(j['process'], {
      'layer_height': '0.28',
      'enable_support': '1',
      'support_type': 'tree(auto)',
      'sparse_infill_density': '35%',
      'inner_wall_speed': '200',
      'sparse_infill_speed': '200',
      'internal_solid_infill_speed': '200',
    });
    expect(j['filaments'], [null, {'nozzle_temperature': '225'}, null, null]);
    final off = jsonDecode(settingsJson({'support': 'off', 'bed_temperature': '60'}, tool: 0, tools: 2, allTools: true)!);
    expect(off['process'], {'enable_support': '0'});
    expect(off['filaments'], [{'bed_temperature': '60'}, {'bed_temperature': '60'}]);
  });

  test('slicer API: mesh, settings and placement on the job', () async {
    final seen = <http.Request>[];
    final api = SlicerApi(MockClient((req) async {
      seen.add(req);
      return req.url.path == '/slicer/mesh'
          ? http.Response.bytes(toStl(box(1, 1, 1)), 200)
          : http.Response('{"id":"abc"}', 200);
    }));
    final stl = await api.mesh(Uint8List(3), name: 'a.step', printer: 'k2plus', orient: true);
    expect(parseStl(stl).triangles, 12);
    expect(seen.last.url.queryParameters, {'printer': 'k2plus', 'name': 'a.step', 'orient': '1'});
    await api.start(Uint8List(3),
        name: 'a.stl', printer: 'k2plus', process: 'p', filaments: ['f'], settings: '{}', placed: true);
    expect(seen.last.url.queryParameters['settings'], '{}');
    expect(seen.last.url.queryParameters['arrange'], '0');
    await api.start(Uint8List(3), name: 'a.stl', printer: 'k2plus', process: 'p', filaments: ['f']);
    expect(seen.last.url.queryParameters.keys, isNot(contains('arrange')));

    final old = SlicerApi(MockClient((req) async => http.Response('{"error": "Not found"}', 404)));
    expect(old.mesh(Uint8List(3), name: 'a.3mf', printer: 'u1'), throwsA(predicate((e) => '$e'.contains('Update'))));
  });

  testWidgets('the view draws a shaded model and drags it', (tester) async {
    final v = place(box(80, 80, 80), const Placement(x: 175, y: 175), turnedBounds(box(80, 80, 80), identity, 1));
    final moves = <Offset>[];
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: MeshView(mesh: v, bed: const [350, 350, 350], color: const Color(0xFF3DDC97),
            onMove: (dx, dy) => moves.add(Offset(dx, dy))),
      ),
    ));
    final box0 = tester.getRect(find.byType(MeshView));
    final s = Float32List(2);
    Projection(Camera.forBed([350, 350, 350]), box0.size).project(175, 175, 60, s, 0);
    final centre = box0.topLeft + Offset(s[0], s[1] + 20); // a point on the model's front

    // The middle of the screen is the model, in the model's green (shaded, not black).
    final px = await tester.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final o = ((centre.dy.round() - 20) * img.width + centre.dx.round()) * 4;
      return [data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2)];
    });
    expect(px![1], greaterThan(60));
    expect(px[1], greaterThan(px[0]));

    // Dragging the model moves it on the plate; dragging beside it doesn't.
    await tester.dragFrom(centre + const Offset(0, -20), const Offset(60, 0));
    expect(moves, isNotEmpty);
    final dx = moves.fold(0.0, (s, m) => s + m.dx), dy = moves.fold(0.0, (s, m) => s + m.dy);
    expect(dx.abs() + dy.abs(), greaterThan(5));
    moves.clear();
    await tester.dragFrom(const Offset(30, 30), const Offset(60, 0));
    expect(moves, isEmpty);
  });

  testWidgets('the editor turns the model, changes a setting and slices it as placed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final jobs = <http.Request>[];
    final api = SlicerApi(MockClient((req) async => switch (req.url.path) {
          '/slicer/presets' => http.Response(
              jsonEncode({
                'printers': [
                  {'id': 'k2plus', 'name': 'Creality K2 Plus', 'tools': 1, 'process': '0.20mm Standard',
                   'bed': [350, 350, 350], 'processes': ['0.20mm Standard'], 'filaments': ['Generic PLA']},
                ]
              }),
              200),
          '/slicer/jobs' => (jobs..add(req), http.Response('{"id":"j1"}', 200)).$2,
          _ => http.Response('{"state":"done","files":["tall.gcode"],"time":600,"weight":12.3}', 200),
        }));
    await tester.pumpWidget(MaterialApp(
      home: SliceEditor(client: MoonrakerClient(host: '127.0.0.1', port: 1), name: 'tall.stl',
          model: toStl(box(20, 20, 60)), api: api),
    ));
    for (var i = 0; i < 20 && find.byType(MeshView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.textContaining('20.0 × 20.0 × 60.0 mm'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '90°').first); // lay it on its side about X
    await tester.pump();
    expect(find.textContaining('20.0 × 60.0 × 20.0 mm'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Layer height'), '0.28');
    await tester.tap(find.widgetWithText(FilledButton, 'Slice'));
    for (var i = 0; i < 20 && find.text('Continue to print').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('10m 0s'), findsOneWidget);
    expect(find.text('12.3 g'), findsOneWidget);

    final q = jobs.single.url.queryParameters;
    expect(q['arrange'], '0');
    expect(q['name'], 'tall.stl');
    expect(jsonDecode(q['settings']!)['process'], {'layer_height': '0.28'});
    final sent = parseStl(jobs.single.bodyBytes).v;
    final (lo, hi) = turnedBounds(sent, identity, 1);
    expect([hi[1] - lo[1], hi[2] - lo[2], lo[2]], [closeTo(60, 1e-3), closeTo(20, 1e-3), closeTo(0, 1e-3)]);
    expect((lo[0] + hi[0]) / 2, closeTo(175, 1e-3));
    expect(settings.text('slice.k2plus.overrides'), '{"layer_height":"0.28"}');
  });
}
