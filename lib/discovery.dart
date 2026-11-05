import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

class FoundPrinter {
  final String host, name;
  FoundPrinter(this.host, this.name);
}

/// Private IPv4 /24 prefixes ("192.168.68") this device is on.
List<String> lanPrefixes(Iterable<String> addresses) {
  final out = <String>{};
  for (final ip in addresses) {
    final p = ip.split('.');
    if (p.length != 4) continue;
    final a = int.tryParse(p[0]) ?? 0, b = int.tryParse(p[1]) ?? 0;
    final private =
        a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
    if (private) out.add('${p[0]}.${p[1]}.${p[2]}');
  }
  return out.toList();
}

/// Scans the local networks for Moonraker on port 7125.
/// ponytail: plain /24 sweep, 48 probes at a time. mDNS would be quicker
/// but most Klipper images don't advertise Moonraker over it.
Stream<FoundPrinter> discoverPrinters({void Function(double)? onProgress}) async* {
  final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  final own = {for (final i in ifaces) for (final a in i.addresses) a.address};
  final hosts = [
    for (final pre in lanPrefixes(own))
      for (var n = 1; n < 255; n++)
        if (!own.contains('$pre.$n')) '$pre.$n',
  ];
  final client = http.Client();
  try {
    var done = 0;
    for (var i = 0; i < hosts.length; i += 48) {
      final batch = hosts.sublist(i, math.min(i + 48, hosts.length));
      final found = await Future.wait(batch.map((h) => _probe(client, h)));
      done += batch.length;
      onProgress?.call(done / hosts.length);
      for (final f in found) {
        if (f != null) yield f;
      }
    }
  } finally {
    client.close();
  }
}

Future<FoundPrinter?> _probe(http.Client c, String host) async {
  try {
    final r = await c
        .get(Uri.parse('http://$host:7125/server/info'))
        .timeout(const Duration(milliseconds: 900));
    if (r.statusCode != 200 || !r.body.contains('klippy')) return null;
    var name = host;
    try {
      final info = await c
          .get(Uri.parse('http://$host:7125/printer/info'))
          .timeout(const Duration(seconds: 2));
      name = '${jsonDecode(info.body)['result']?['hostname'] ?? host}';
    } catch (_) {}
    return FoundPrinter(host, name);
  } catch (_) {
    return null;
  }
}
