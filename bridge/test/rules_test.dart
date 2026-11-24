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
