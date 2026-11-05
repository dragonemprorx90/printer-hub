// Printer Hub home bridge.
//
// Runs next to the printer (NAS, Raspberry Pi, Mac) and keeps one outgoing
// connection to your relay, so the app can reach the printer from anywhere
// without opening router ports. Every frame is end-to-end encrypted; the
// relay only passes sealed data along.
//
//   bridge --relay https://printer-hub-relay.<you>.workers.dev --printer 192.168.68.53
//   bridge --show-code   print the pairing code / QR again
//   bridge --reset       new code; phones paired with the old one stop working
//
// Options can also come from the environment (handy in Docker):
//   RELAY_URL, PRINTER_HOST, MOONRAKER_PORT, BRIDGE_DATA

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';
import 'package:qr/qr.dart';
import 'package:web_socket_channel/io.dart';

void log(String m) =>
    stdout.writeln('${DateTime.now().toIso8601String().substring(0, 19)}  $m');

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final hasValue = i + 1 < argv.length && !argv[i + 1].startsWith('--');
    args[a.substring(2)] = hasValue ? argv[++i] : 'true';
  }
  if (args.containsKey('help')) {
    stdout.writeln('Usage: bridge --relay <url> --printer <ip> [--port 7125] '
        '[--data <dir>] [--show-code] [--reset]');
    return;
  }
  final env = Platform.environment;
  final dataDir = Directory(args['data'] ??
      env['BRIDGE_DATA'] ??
      '${env['HOME'] ?? '.'}/.printer-hub-bridge');
  final stateFile = File('${dataDir.path}/pairing.json');

  if (args['reset'] == 'true' && stateFile.existsSync()) {
    stateFile.deleteSync();
    log('Old pairing removed. Phones must be paired again.');
  }

  Map<String, dynamic> saved = {};
  if (stateFile.existsSync()) {
    saved = Map<String, dynamic>.from(jsonDecode(stateFile.readAsStringSync()));
  }
  final printer = args['printer'] ?? env['PRINTER_HOST'] ?? saved['printer'] as String?;
  final port = int.tryParse(args['port'] ?? env['MOONRAKER_PORT'] ?? '') ??
      (saved['port'] as int?) ??
      7125;
  final relayUrl = args['relay'] ?? env['RELAY_URL'];

  PairInfo pair;
  if (saved['code'] is String) {
    pair = PairInfo.decode(saved['code']);
    if (relayUrl != null && PairInfo.normalizeRelay(relayUrl) != pair.relay) {
      stderr.writeln('This bridge is paired with ${pair.relay}. '
          'Use --reset to switch to another relay.');
      exit(2);
    }
  } else {
    if (relayUrl == null || printer == null) {
      stderr.writeln('First run needs --relay <url> and --printer <ip>.');
      exit(2);
    }
    pair = PairInfo.create(relayUrl);
  }
  if (printer == null) {
    stderr.writeln('Missing --printer <ip>.');
    exit(2);
  }

  dataDir.createSync(recursive: true);
  stateFile.writeAsStringSync(jsonEncode({'code': pair.encode(), 'printer': printer, 'port': port}));
  if (!Platform.isWindows) await Process.run('chmod', ['600', stateFile.path]);

  _printPairing(pair);
  if (args['show-code'] == 'true') return;

  log('Bridging printer $printer:$port through ${pair.relay}');
  await Bridge(pair, await LinkCrypto.forPair(pair), printer, port).run();
}

void _printPairing(PairInfo pair) {
  final code = pair.encode();
  final qr = QrImage(QrCode.fromData(data: code, errorCorrectLevel: QrErrorCorrectLevel.L));
  final n = qr.moduleCount;
  bool dark(int r, int c) => r >= 0 && c >= 0 && r < n && c < n && qr.isDark(r, c);
  final out = StringBuffer('\nScan in Printer Hub (Add/Edit printer → Remote access code),\n'
      'or copy the code below. Keep it private: it controls your printer.\n\n');
  // Two QR rows per text line, dark modules on a light background.
  for (var r = -2; r < n + 2; r += 2) {
    out.write('\x1B[30;47m  ');
    for (var c = -2; c < n + 2; c++) {
      final top = dark(r, c), bottom = dark(r + 1, c);
      out.write(top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' ');
    }
    out.writeln('  \x1B[0m');
  }
  out.writeln('\n$code\n');
  stdout.write(out);
}

/// One phone connected through the relay, with its own Moonraker socket.
class _Session {
  WebSocket? moonraker;
  final pending = <String>[];
  final uploads = <int, BytesBuilder>{};
  bool closed = false;

  void close() {
    closed = true;
    moonraker?.close();
  }
}

class Bridge {
  final PairInfo pair;
  final LinkCrypto crypto;
  final String host;
  final int port;

  IOWebSocketChannel? _relay;
  final _sessions = <String, _Session>{};
  final _client = http.Client();
  Future<void> _recvChain = Future.value();
  Future<void> _sendChain = Future.value();

  Bridge(this.pair, this.crypto, this.host, this.port);

  Future<void> run() async {
    var backoff = 1;
    while (true) {
      final started = DateTime.now();
      try {
        await _connectOnce();
      } catch (e) {
        log('Relay: $e');
      }
      if (DateTime.now().difference(started).inMinutes >= 1) backoff = 1;
      log('Reconnecting in ${backoff}s');
      await Future.delayed(Duration(seconds: backoff));
      backoff = math.min(backoff * 2, 60);
    }
  }

  Future<void> _connectOnce() async {
    final ch = IOWebSocketChannel.connect(pair.socketUri('bridge', crypto.relayToken),
        connectTimeout: const Duration(seconds: 15));
    await ch.ready;
    _relay = ch;
    log('Connected to relay. Waiting for phones.');
    final ping = Timer.periodic(const Duration(seconds: 30), (_) => ch.sink.add('ping'));
    try {
      await for (final raw in ch.stream) {
        if (raw is! String || raw == 'pong') continue;
        final Map env;
        try {
          env = jsonDecode(raw) as Map;
        } catch (_) {
          continue;
        }
        final c = '${env['c']}';
        if (env['open'] == true) {
          _open(c);
        } else if (env['close'] == true) {
          _sessions.remove(c)?.close();
          log('Phone $c disconnected');
        } else if (env['p'] is String) {
          final frame = env['p'] as String;
          // Decrypt in arrival order; long HTTP transfers run alongside.
          _recvChain = _recvChain.then((_) => _onFrame(c, frame));
        }
      }
    } finally {
      ping.cancel();
      _relay = null;
      for (final s in _sessions.values) {
        s.close();
      }
      _sessions.clear();
    }
    throw 'connection closed (${ch.closeCode ?? '-'} ${ch.closeReason ?? ''})';
  }

  Future<void> _send(String c, Map<String, dynamic> msg) =>
      _sendChain = _sendChain.then((_) async {
        final relay = _relay;
        if (relay == null) return;
        relay.sink.add(jsonEncode({'c': c, 'p': await crypto.seal(msg)}));
      });

  void _open(String c) {
    _sessions.remove(c)?.close();
    final s = _Session();
    _sessions[c] = s;
    log('Phone $c connected');
    _connectMoonraker(c, s);
  }

  Future<void> _connectMoonraker(String c, _Session s) async {
    try {
      final ws = await WebSocket.connect('ws://$host:$port/websocket')
          .timeout(const Duration(seconds: 10));
      if (s.closed) {
        ws.close();
        return;
      }
      s.moonraker = ws;
      for (final p in s.pending) {
        ws.add(p);
      }
      s.pending.clear();
      ws.listen(
        (m) => _send(c, {'t': 'ws', 'd': '$m'}),
        onDone: () {
          if (!s.closed) _send(c, {'t': 'ws_closed', 'e': 'Printer closed the connection'});
        },
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (e) {
      log('Printer unreachable: $e');
      _send(c, {'t': 'ws_closed', 'e': 'The bridge cannot reach the printer at $host:$port'});
    }
  }

  Future<void> _onFrame(String c, String frame) async {
    final Map<String, dynamic> m;
    try {
      m = await crypto.open(frame);
    } catch (e) {
      log('Rejected a frame from phone $c ($e)');
      return;
    }
    final s = _sessions[c];
    if (s == null) return;
    switch (m['t']) {
      case 'ws':
        final d = '${m['d']}';
        final ws = s.moonraker;
        ws == null ? s.pending.add(d) : ws.add(d);
      case 'http':
        final id = m['id'] as int;
        final body = s.uploads.putIfAbsent(id, BytesBuilder.new);
        if (m['b'] is String) body.add(unb64(m['b'] as String));
        if (m['more'] == true) return;
        s.uploads.remove(id);
        unawaited(_http(c, m, body.takeBytes()));
    }
  }

  static const _forwardHeaders = {'range', 'content-type', 'x-api-key', 'accept'};

  /// Performs a request against Moonraker only (never any other host) and
  /// streams the reply back in chunks.
  Future<void> _http(String c, Map<String, dynamic> m, List<int> body) async {
    final id = m['id'];
    final path = '${m['p']}';
    final uri = Uri.parse('http://$host:$port$path');
    if (!path.startsWith('/') || uri.host != host || uri.port != port) {
      await _send(c, {'t': 'res', 'id': id, 's': 400, 'h': {}, 'b': '', 'more': false});
      return;
    }
    try {
      final req = http.Request('${m['m']}', uri)..bodyBytes = body;
      final headers = Map<String, dynamic>.from((m['h'] as Map?) ?? const {});
      headers.forEach((k, v) {
        if (_forwardHeaders.contains(k.toLowerCase())) req.headers[k] = '$v';
      });
      final res = await _client.send(req).timeout(const Duration(seconds: 60));
      final head = {
        if (res.headers['content-type'] != null) 'content-type': res.headers['content-type'],
      };
      var first = true;
      final buf = BytesBuilder(copy: false);
      Future<void> flush(bool more) async {
        await _send(c, {
          't': 'res',
          'id': id,
          if (first) 's': res.statusCode,
          if (first) 'h': head,
          'b': b64(buf.takeBytes()),
          'more': more,
        });
        first = false;
      }

      await for (final chunk in res.stream) {
        buf.add(chunk);
        while (buf.length >= kChunkBytes) {
          final all = buf.takeBytes();
          buf.add(all.sublist(0, kChunkBytes));
          final rest = all.sublist(kChunkBytes);
          await flush(true);
          buf.add(rest);
        }
      }
      await flush(false);
    } catch (e) {
      await _send(c, {'t': 'res', 'id': id, 's': 502, 'h': {}, 'b': b64(utf8.encode('$e')), 'more': false});
    }
  }
}
