import 'dart:convert';
import 'dart:io';

import 'package:hub_link/hub_link.dart';
import 'package:test/test.dart';

import '../bin/bridge.dart';

void main() {
  test('relayed paths only reach Moonraker, the screen or the printer\'s heater', () async {
    // Fake Moonraker whose config names a DragonBreath heater.
    final mr = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mr.listen((req) => req.response
      ..write(jsonEncode({
        'result': {
          'status': {
            'configfile': {
              'settings': {
                'dragonbreath': {'host': '10.0.0.9'}
              }
            }
          }
        }
      }))
      ..close());
    final pair = PairInfo.create('https://relay.example');
    final b = Bridge(pair, await LinkCrypto.forPair(pair), '127.0.0.1', mr.port);

    final (moon, _) = await b.target('/printer/info');
    expect(moon.toString(), 'http://127.0.0.1:${mr.port}/printer/info');
    final (screen, _) = await b.target('/screen/snapshot');
    expect(screen.port, 80);
    final (heat, h) = await b.target('/dragonbreath/api/v2/state');
    expect(heat.toString(), 'http://10.0.0.9/api/v2/state');
    expect(h['X-DragonBreath-Auth'], 'web');
    final (odd, _) = await b.target('/dragonbreath/@evil.com/');
    expect(odd.host, '10.0.0.9');
    for (final bad in ['//evil.com/x', 'x']) {
      await expectLater(b.target(bad), throwsFormatException, reason: bad);
    }
    await mr.close(force: true);
  });
}
