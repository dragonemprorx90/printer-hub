import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../bin/bridge.dart';

void main() {
  test('rule windows: days and hours, wrapping midnight', () {
    final mon2330 = DateTime(2026, 11, 23, 23, 30); // Monday
    expect(ruleAllowed({}, mon2330), isTrue);
    expect(ruleAllowed({'days': [1]}, mon2330), isTrue);
    expect(ruleAllowed({'days': [2, 3]}, mon2330), isFalse);
    expect(ruleAllowed({'from': '22:00', 'to': '07:00'}, mon2330), isTrue);
    expect(ruleAllowed({'from': '08:00', 'to': '18:00'}, mon2330), isFalse);
    expect(ruleAllowed({'from': 'bad', 'to': '18:00'}, mon2330), isTrue);
  });

  test('webhooks only go to http(s) URLs', () {
    expect(webhookUri('@webhook https://ha.local/api/webhook/x')?.host, 'ha.local');
    expect(webhookUri('@webhook file:///etc/passwd'), isNull);
    expect(webhookUri('@webhook'), isNull);
  });

  test('bridge info and log are answered by the bridge itself', () {
    log('hello');
    expect(bridgeOwn('/bridge/log')!.$3, contains('hello'));
    expect(bridgeOwn('/bridge/info')!.$3, contains('version'));
    expect(bridgeOwn('/server/info'), isNull);
  });

  test('MQTT packets', () {
    expect(mqttLength(0), [0]);
    expect(mqttLength(127), [127]);
    expect(mqttLength(128), [0x80, 1]);
    expect(mqttLength(16383), [0xFF, 0x7F]);
    final p = mqttPublish('a/b', 'hi', retain: true);
    expect(p, [0x31, 7, 0, 3, 0x61, 0x2F, 0x62, 0x68, 0x69]);
    final c = mqttConnect('id', user: 'u', password: 'p');
    expect(c.first, 0x10);
    expect(c[2 + 7], 0xC2); // user + password + clean session
  });

  test('MQTT status reaches a broker with Home Assistant discovery', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = <int>[];
    final done = Completer<void>();
    server.listen((c) => c.listen((b) {
          got.addAll(b);
          if (latin1.decode(got, allowInvalid: true).contains('printerhub/k2_plus/state')) {
            if (!done.isCompleted) done.complete();
          }
        }));
    final m = MqttStatus(Uri.parse('mqtt://u:p@127.0.0.1:${server.port}'), 'K2 Plus');
    await m.publish({'state': 'printing', 'progress': 42});
    await done.future.timeout(const Duration(seconds: 5));
    final text = latin1.decode(got, allowInvalid: true);
    expect(got.first, 0x10); // CONNECT first
    expect(text, contains('homeassistant/sensor/printerhub_k2_plus_progress/config'));
    expect(text, contains('"progress":42'));
    await server.close();
  });

  test('history CSV', () {
    final csv = historyCsv([
      {'filename': 'a,b.gcode', 'status': 'completed', 'start_time': 0, 'print_duration': 61.4, 'filament_used': 1000.2},
    ]);
    expect(csv.split('\n').first, 'file,status,started,duration_s,filament_mm');
    expect(csv.split('\n')[1], startsWith('"a,b.gcode",completed,'));
    expect(csv, endsWith(',61,1000'));
  });

  test('alert text and links', () {
    expect(openLink('K2 Plus'), 'printerhub://printer/K2%20Plus');
    expect(finishedText('a.gcode', {'print_duration': 4320, 'filament_used': 14200}), 'a.gcode · 1h 12m · 14.2 m of filament');
    expect(finishedText('a.gcode', {}), 'a.gcode');
  });

  test('overrun', () {
    expect(overran(4000, 3000, 30), isTrue);
    expect(overran(3500, 3000, 30), isFalse);
    expect(overran(400, 300, 30), isFalse); // short prints don't count
    expect(overran(9999, null, 30), isFalse);
  });

  test('still heating', () {
    expect(stillHeating(150, 220), isTrue);
    expect(stillHeating(218, 220), isFalse);
    expect(stillHeating(20, 0), isFalse);
    expect(stillHeating(null, 60), isFalse);
  });

  test('weekly summary time', () {
    expect(weeklyDue('Sun 20:00', DateTime(2026, 11, 29, 20, 0)), isTrue);
    expect(weeklyDue('sun 20:00', DateTime(2026, 11, 29, 20, 1)), isFalse);
    expect(weeklyDue('Mon 20:00', DateTime(2026, 11, 29, 20, 0)), isFalse);
    expect(weeklyDue('', DateTime(2026, 11, 29, 20, 0)), isFalse);
  });

  test('chamber ready, summary and metrics', () {
    expect(chamberReady(59.2, 60), isTrue);
    expect(chamberReady(50, 60), isFalse);
    expect(chamberReady(30, 0), isFalse);
    expect(summaryText([]), 'No prints today.');
    expect(
        summaryText([
          {'status': 'completed', 'print_duration': 3600},
          {'status': 'error', 'print_duration': 1800},
        ]),
        '2 prints (1 finished, 1 failed), 1h 30m printing.');
    expect(metricsText({'up': 1}), '# TYPE printer_hub_up gauge\nprinter_hub_up 1\n');
  });
}
