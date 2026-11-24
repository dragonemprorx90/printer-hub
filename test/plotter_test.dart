import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/plotter_page.dart';
import 'package:printer_hub/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A plotter that never connects; nothing here can reach a machine.
class _Fake extends MoonrakerClient {
  final sent = <String>[];
  _Fake() : super(host: 'fake.local');
  @override
  Future<void> gcode(String script) async => sent.add(script);
  @override
  Future<void> startPrint(String filename) async => sent.add('START $filename');
  @override
  Future<(List<String>, List<GcodeFile>)> directory(String path) async =>
      (const <String>[], [GcodeFile('accuracy_test.gcode', 2000, DateTime(2026, 11, 20))]);
}

Offset _apply(Matrix4 m, Offset p) {
  final s = m.storage;
  final w = s[3] * p.dx + s[7] * p.dy + s[15];
  return Offset((s[0] * p.dx + s[4] * p.dy + s[12]) / w, (s[1] * p.dx + s[5] * p.dy + s[13]) / w);
}

const _plotter = Printer(name: 'Neptune Plotter', host: 'fake.local');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });

  test('homography maps the photo corners onto the page', () {
    const from = [Offset(10, 20), Offset(410, 5), Offset(430, 600), Offset(0, 580)];
    const to = [Offset(0, 0), Offset(210, 0), Offset(210, 297), Offset(0, 297)];
    final m = homography(from, to);
    for (var i = 0; i < 4; i++) {
      expect((_apply(m, from[i]) - to[i]).distance, lessThan(1e-6), reason: '$i');
    }
  });

  test('boxes group by pen colour in the order they appear', () {
    final g = groupByColour([PlotBox(colour: 'red'), PlotBox(colour: 'blue'), PlotBox(colour: 'red')]);
    expect(g.map((e) => (e.$1, e.$2.length)).toList(), [('red', 2), ('blue', 1)]);
  });

  testWidgets('Not homed: only Home is offered, and it asks first', (t) async {
    final c = _Fake();
    c.status
      ..online = true
      ..plotter = true
      ..applyDelta({
        'webhooks': {'state': 'ready'},
        'print_stats': {'state': 'standby'},
        'toolhead': {'homed_axes': '', 'position': [0, 0, 0, 0]},
        'save_variables': {'variables': {'plot_zdown': 5.4}},
      });
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: PlotterPage(printer: _plotter, client: c)));
    await t.pumpAndSettle();
    expect(find.textContaining('Not homed'), findsWidgets);
    expect(find.text('Pen up'), findsNothing);
    expect(find.text('Set origin'), findsNothing);
    // Files are listed but can't be plotted yet.
    expect(find.text('accuracy_test.gcode'), findsOneWidget);
    expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Plot')).onPressed, isNull);
    await t.tap(find.text('Home'));
    await t.pumpAndSettle();
    expect(find.text('Home the plotter?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(c.sent, isEmpty);

    // Homed and idle: pen setup appears; the pen height step only saves a variable.
    c.status.applyDelta({'toolhead': {'homed_axes': 'xyz'}});
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(home: PlotterPage(printer: _plotter, client: c)));
    await t.pumpAndSettle();
    expect(find.text('Pen up'), findsOneWidget);
    await t.tap(find.byTooltip('Raise 0.1 mm (lighter)'));
    await t.pump();
    expect(c.sent, ['SAVE_VARIABLE VARIABLE=plot_zdown VALUE=5.50']);
    expect(t.takeException(), isNull);
  });

  testWidgets('Sending uploads one file per pen colour and never starts it', (t) async {
    final calls = <(String, Map)>[];
    final api = PlotApi(MockClient((r) async {
      final body = jsonDecode(r.body) as Map;
      calls.add((r.url.path, body));
      if (r.url.path.endsWith('/preview')) {
        return http.Response(
            jsonEncode({
              'boxes': [
                {
                  'paths': [
                    [[0, 0], [10, 5]]
                  ],
                  'w': 10,
                  'h': 5,
                  'svg': '<svg/>'
                }
              ],
              'seconds': 30,
              'fits': true,
            }),
            200);
      }
      return http.Response(jsonEncode({'file': '${body['name']}.gcode', 'seconds': 30}), 200);
    }));
    List<PlotStep>? steps;
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: PlotEditor(client: _Fake(), worksheet: true, api: api, onSent: (s) => steps = s))));
    await t.enterText(find.byType(TextField), 'Name: Omar');
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.byTooltip('Add a text box'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'Answer 42');
    await t.tap(find.byTooltip('red'));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Send to the plotter (2 pens)'), findsOneWidget);
    await t.tap(find.text('Send to the plotter (2 pens)'));
    await t.pumpAndSettle();
    final sends = calls.where((c) => c.$1 == '/slicer/plot/send').toList();
    expect(sends.length, 2);
    expect(sends.every((c) => c.$2['start'] == false), isTrue);
    expect(steps!.map((s) => s.colour), ['blue', 'red']);
    expect((sends[1].$2['boxes'] as List).single['text'], 'Answer 42');
    expect(t.takeException(), isNull);
  });
}
