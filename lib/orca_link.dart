import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'moonraker.dart';
import 'settings.dart';

/// Port the Mac app listens on for OrcaSlicer (127.0.0.1 only).
const kOrcaPort = 7126;

/// One upload from the slicer.
typedef OrcaUpload = ({String name, Uint8List bytes, bool print, String? printer});

/// Parts of a multipart/form-data body: field name -> (filename, bytes).
Map<String, (String?, Uint8List)> parseMultipart(Uint8List body, String boundary) {
  final out = <String, (String?, Uint8List)>{};
  final delim = ascii.encode('--$boundary');
  int find(List<int> pat, int from) {
    outer:
    for (var i = from; i <= body.length - pat.length; i++) {
      for (var j = 0; j < pat.length; j++) {
        if (body[i + j] != pat[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  var at = find(delim, 0);
  while (at >= 0) {
    final start = at + delim.length;
    if (start + 2 <= body.length && body[start] == 45 && body[start + 1] == 45) break; // "--" = end
    final headEnd = find(const [13, 10, 13, 10], start);
    if (headEnd < 0) break;
    final head = latin1.decode(body.sublist(start, headEnd));
    final next = find(delim, headEnd + 4);
    if (next < 0) break;
    final data = body.sublist(headEnd + 4, next - 2); // drop the CRLF before the delimiter
    final name = RegExp(r'name="([^"]*)"').firstMatch(head)?[1];
    final file = RegExp(r'filename="([^"]*)"').firstMatch(head)?[1];
    if (name != null) out[name] = (file, Uint8List.fromList(data));
    at = next;
  }
  return out;
}

/// A camera picture: through the relay when away, the U1's snapshot URL or a
/// JPEG camera URL at home. Throws when there is no camera to read.
Future<List<int>> cameraSnapshot(Printer p, MoonrakerClient c) async {
  if (c.viaRelay) return c.relayFrame();
  final urls = [
    if (c.isSnapmaker) 'http://${p.host}/webcam/snapshot.jpg',
    if (p.cameraUrl != null && RegExp(r'\.jpe?g|snapshot', caseSensitive: false).hasMatch(p.cameraUrl!)) p.cameraUrl!,
  ];
  for (final u in urls) {
    try {
      final r = await HttpClient().getUrl(Uri.parse(u)).then((q) => q.close()).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        return await r.fold<List<int>>([], (a, b) => a..addAll(b));
      }
    } catch (_) {}
  }
  throw 'No camera picture for ${p.name}';
}

/// Keeps every printer's existing port; gives new ones the lowest free port
/// from [base]. Ports of removed printers stay reserved so they are never
/// handed to a different printer that Orca might still have saved.
Map<String, int> assignProxyPorts(Map<String, int> saved, List<String> keys, int base) {
  final out = {...saved};
  for (final k in keys) {
    if (out.containsKey(k)) continue;
    var p = base;
    while (out.containsValue(p)) {
      p++;
    }
    out[k] = p;
  }
  return out;
}

/// What Orca calls this printer: preset model words and its printer agent.
Map<String, String> orcaModel(MoonrakerClient c) {
  final s = c.status;
  if (c.isSnapmaker) return {'model': 'Snapmaker U1', 'agent': 'snapmaker', 'host_type': 'moonraker'};
  if (s.raw.containsKey('box') || s.raw.containsKey(PrinterStatus.chamberHeaters.first)) {
    final x = s.axisMax.first;
    final model = x >= 340 ? 'K2 Plus' : x >= 290 ? 'K2 Pro' : 'K2';
    // Through the Printer Hub proxy only Moonraker is reachable (not Creality's
    // port 9999), and Orca's Moonraker agent reads the CFS from Moonraker itself.
    return {'model': 'Creality $model', 'agent': 'moonraker', 'host_type': 'moonraker'};
  }
  return {'model': '', 'agent': 'moonraker', 'host_type': 'moonraker'};
}

/// Loaded filaments in Orca's slot order: U1 lanes by tool (T0 -> 1), CFS
/// slots in box order. `tool` is the 0-based Orca filament index.
List<Map<String, Object?>> hubFilaments(PrinterStatus s) {
  final out = <Map<String, Object?>>[];
  var i = 0;
  for (final b in s.cfs) {
    for (final slot in b.slots) {
      final tool = slot.lane != null ? int.tryParse(slot.label.replaceAll(RegExp(r'\D'), '')) ?? i : i;
      out.add({
        'tool': tool,
        'label': slot.label,
        // Creality reports material as a numeric code ("000001"); hide it rather than show a code.
        'material': slot.empty || RegExp(r'^\d+$').hasMatch(slot.material) ? '' : slot.material,
        'color': slot.color == null
            ? null
            : '#${(slot.color! & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
      });
      i++;
    }
  }
  out.sort((a, b) => (a['tool'] as int).compareTo(b['tool'] as int));
  return out;
}

/// "K2 Plus" -> "k2-plus", so Orca can target one printer with
/// http://127.0.0.1:7126/k2-plus
String printerSlug(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

/// A tiny OctoPrint-compatible server, so OrcaSlicer's "physical printer"
/// (host type Octo/Klipper) can send to Printer Hub, which then picks the
/// printer, uploads (at home or through the relay) and opens print setup.
/// Also serves /hub/printers for the Printer Hub Orca plugin's panel.
class OrcaLink {
  final void Function(OrcaUpload) onUpload;
  final List<Printer> Function() printers;
  final int port;
  HttpServer? _server;
  final _proxies = <String, HttpServer>{}; // printer key -> its local Moonraker

  /// Saved printer -> port map. Orca stores the port in its printer preset, so
  /// a printer must keep its port for good (never by list position: a port
  /// that moved to another printer would send prints to the wrong machine).
  final Map<String, int> Function() loadPorts;
  final void Function(Map<String, int>) savePorts;

  OrcaLink({
    required this.onUpload,
    required this.printers,
    this.port = kOrcaPort,
    Map<String, int> Function()? loadPorts,
    void Function(Map<String, int>)? savePorts,
  })  : loadPorts = loadPorts ??
            (() => Map<String, int>.from(jsonDecode(settings.text('orcaProxyPorts', '{}')) as Map)),
        savePorts = savePorts ?? ((m) => settings.setText('orcaProxyPorts', jsonEncode(m)));

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle, onError: (_) {});
    await _ensureProxies();
  }

  /// One local Moonraker per printer, so OrcaSlicer's own printer agents
  /// (device page, filament sync, printing) reach it through Printer Hub, at
  /// home or through the relay from anywhere. New printers get one on demand.
  Future<void> _ensureProxies() async {
    final ports = assignProxyPorts(loadPorts(), [for (final p in printers()) p.key], port + 4);
    savePorts(ports);
    for (final p in printers()) {
      if (_proxies.containsKey(p.key)) continue;
      try {
        final key = p.key;
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, ports[key]!);
        // Look the printer up per request, so an edited printer is followed.
        s.listen((r) {
          final now = printers().where((x) => x.key == key).firstOrNull;
          now == null ? (r.response..statusCode = 404).close() : _proxy(now, r);
        }, onError: (_) {});
        _proxies[key] = s;
      } catch (_) {} // port taken: that printer just has no Orca proxy
    }
  }

  int? proxyPort(Printer p) => _proxies[p.key]?.port;

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    for (final s in _proxies.values) {
      await s.close(force: true);
    }
    _proxies.clear();
  }

  Future<void> _proxy(Printer p, HttpRequest req) async {
    final res = req.response;
    try {
      if (req.headers.value('origin') != null) {
        res.statusCode = 403;
        return await res.close();
      }
      final c = clientFor(p);
      if (req.uri.path == '/websocket' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        final (stream, send, close) = await c.openSocket();
        final sub = stream.listen(ws.add, onDone: () => ws.close());
        ws.listen((m) => send('$m'), onDone: () {
          sub.cancel();
          close();
        });
        return;
      }
      final body = await req
          .fold<BytesBuilder>(BytesBuilder(copy: false), (a, c) => a..add(c))
          .then((x) => x.takeBytes());
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(','));
      final r = await c.forward(req.method, req.uri.toString(), headers, body);
      res.statusCode = r.statusCode;
      final ct = r.headers['content-type'];
      if (ct != null) res.headers.set('content-type', ct);
      await res.addStream(r.stream);
      await res.close();
    } catch (e) {
      try {
        res.statusCode = 502;
        res.write('$e');
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    void json(int code, Object body) {
      res
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
    }

    try {
      // Browsers send Origin on cross-site requests; Orca and the plugin don't.
      // Refusing those stops a web page from poking 127.0.0.1.
      if (req.headers.value('origin') != null) return json(403, {'error': 'browser requests not allowed'});
      // Optional printer slug before /api: /k2-plus/api/files/local
      final seg = req.uri.pathSegments;
      final api = seg.indexOf('api');
      final slug = api > 0 ? seg[api - 1] : null;
      final path = api >= 0 ? '/${seg.sublist(api).join('/')}' : req.uri.path;

      if (path == '/api/version' || path == '/api/server') {
        json(200, {'api': '0.1', 'server': '1.9.0', 'text': 'OctoPrint 1.9.0 (Printer Hub)'});
      } else if (path == '/api/files/local' && req.method == 'POST') {
        final b = RegExp(r'boundary=("?)([^";]+)\1').firstMatch(req.headers.value('content-type') ?? '')?[2];
        if (b == null) return json(400, {'error': 'expected multipart/form-data'});
        final body = await req
            .fold<BytesBuilder>(BytesBuilder(copy: false), (a, c) => a..add(c))
            .then((x) => x.takeBytes());
        final parts = parseMultipart(body, b);
        final file = parts['file'];
        if (file == null || file.$1 == null) return json(400, {'error': 'no file'});
        final print = utf8.decode(parts['print']?.$2 ?? const []).trim() == 'true';
        final name = file.$1!.split(RegExp(r'[\\/]')).last;
        onUpload((name: name, bytes: file.$2, print: print, printer: slug));
        json(201, {
          'done': true,
          'files': {
            'local': {'name': name, 'origin': 'local'},
          },
        });
      } else if (path == '/hub/action' && req.method == 'POST') {
        if (req.headers.value('x-printer-hub') != '1') return json(403, {'error': 'missing X-Printer-Hub header'});
        final p = printers().where((p) => printerSlug(p.name) == req.uri.queryParameters['printer']).firstOrNull;
        if (p == null) return json(404, {'error': 'no such printer'});
        final c = clientFor(p);
        final q = req.uri.queryParameters;
        double n(String k) => double.tryParse(q[k] ?? '') ?? 0;
        switch (q['do']) {
          case 'pause':
            await c.pause();
          case 'resume':
            await c.resume();
          case 'cancel':
            await c.cancel();
          case 'estop':
            await c.emergencyStop();
          case 'light':
            await c.setLed(!(c.status.led ?? false));
          case 'nozzle':
            await c.setHotend(n('value').round());
          case 'bed':
            await c.setBed(n('value').round());
          case 'chamber':
            await c.setChamber(n('value').round());
          case 'preheat': // nozzle,bed[,chamber]
            await c.setHotend(n('nozzle').round());
            await c.setBed(n('bed').round());
            if (q['chamber'] != null && c.status.chamberHeatable) await c.setChamber(n('chamber').round());
          case 'cooldown':
            await c.gcode('TURN_OFF_HEATERS');
          case 'home':
            await c.home();
          case 'motors_off':
            await c.gcode('M84');
          case 'fan':
            final f = c.status.fans.where((f) => f.object == q['object']).firstOrNull;
            if (f == null) return json(404, {'error': 'no such fan'});
            await c.setFan(f, n('value').clamp(0, 1).toDouble());
          case 'speed':
            await c.setSpeed(n('value').round());
          case 'flow':
            await c.setFlow(n('value').round());
          case 'zoffset':
            await c.adjustZOffset(n('value').clamp(-0.1, 0.1).toDouble());
          case 'pause_at_layer':
            await c.pauseAtLayer(n('value') <= 0 ? null : n('value').round());
          case 'macro':
            final m = q['name'] ?? '';
            if (!c.macros.contains(m)) return json(404, {'error': 'no such macro'});
            await c.gcode(m);
          case 'exclude':
            final o = q['name'] ?? '';
            if (!c.status.objects.any((x) => x.name == o)) return json(404, {'error': 'no such object'});
            await c.excludeObject(o);
          case 'dry':
            await c.heaterCommand('drying_start',
                {'target_c': n('temp').round().clamp(30, 70), 'hours': n('hours').round().clamp(1, 12)});
          case 'dry_stop':
            await c.heaterCommand('drying_stop');
          case 'heater_filter':
            await c.gcode('SET_PIN PIN=dragonbreath_filter VALUE=${n('value') > 0 ? 1 : 0}');
          case 'heater_reset':
            await c.resetHeaterFault();
          case 'reprint':
            if (const {'printing', 'paused'}.contains(c.status.state)) return json(409, {'error': 'printer is busy'});
            await c.startPrint(q['file'] ?? '');
          case 'link_spool':
            await c.setLaneSpool(q['lane'] ?? '', n('spool').round());
          case 'add_spool':
            final lane = c.status.cfs.expand((b) => b.slots).where((s) => s.lane == q['lane']).firstOrNull;
            if (lane == null || lane.color == null) return json(404, {'error': 'no such loaded lane'});
            final id = await c.addSpool(
                vendor: 'Generic', material: lane.material, color: lane.color!, grams: n('grams') <= 0 ? 1000 : n('grams'));
            await c.setLaneSpool(lane.lane!, id);
          case 'rule_toggle':
            final rules = await c.rules();
            final i = n('index').round();
            if (i < 0 || i >= rules.length) return json(404, {'error': 'no such rule'});
            rules[i] = {...rules[i], 'off': rules[i]['off'] != true};
            await c.setRules(rules);
          default:
            return json(400, {'error': 'unknown action'});
        }
        json(200, {'ok': true});
      } else if (path.startsWith('/hub/') && req.method == 'GET' && path != '/hub/printers') {
        final p = printers().where((p) => printerSlug(p.name) == req.uri.queryParameters['printer']).firstOrNull;
        if (p == null) return json(404, {'error': 'no such printer'});
        final c = clientFor(p);
        void jpeg(List<int> bytes) {
          res.headers
            ..contentType = ContentType('image', 'jpeg')
            ..set('cache-control', 'no-store');
          res.add(bytes);
        }

        switch (path) {
          case '/hub/snapshot':
            jpeg(await cameraSnapshot(p, c));
          case '/hub/picture':
            jpeg(await c.snapshotBytes(req.uri.queryParameters['name'] ?? ''));
          case '/hub/history':
            final jobs = await c.history(limit: 10);
            final files = await c.snapshotFiles().catchError((_) => <String>[]);
            json(200, [
              for (final j in jobs)
                {
                  'file': j.filename,
                  'status': j.status,
                  'start': j.start.millisecondsSinceEpoch,
                  'duration': j.duration,
                  'filament': j.filament,
                  'exists': j.exists,
                  'pictures': snapshotsFor(j, files),
                },
            ]);
          case '/hub/spools':
            final on = await c.hasSpoolman();
            json(200, {
              'enabled': on,
              if (on) 'active': await c.activeSpool(),
              if (on)
                'spools': [
                  for (final sp in await c.spools())
                    {
                      'id': sp.id,
                      'name': sp.name,
                      'material': sp.material,
                      'color': sp.color == null ? null : '#${(sp.color! & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                      'remaining': sp.remaining,
                    },
                ],
            });
          case '/hub/rules':
            json(200, await c.rules());
          default:
            json(404, {'error': 'not found'});
        }
      } else if (path == '/hub/printers') {
        await _ensureProxies();
        json(200, [
          for (final p in printers())
            {
              'name': p.name,
              'slug': printerSlug(p.name),
              if (proxyPort(p) != null) 'proxy': '127.0.0.1:${proxyPort(p)}',
              'host': p.host,
              'port': p.port,
              ...orcaModel(clientFor(p)),
              ..._status(clientFor(p)),
            },
        ]);
      } else {
        json(404, {'error': 'not found'});
      }
    } catch (e) {
      json(500, {'error': '$e'});
    } finally {
      await res.close();
    }
  }

  static Map<String, Object?> _status(MoonrakerClient c) {
    final s = c.status;
    final mesh = [for (final r in s.mesh) ...r];
    final dragon = s.dragon;
    return {
      'online': s.online,
      'state': s.state,
      'message': s.message,
      'file': s.filename,
      'progress': s.progress,
      'eta': s.eta,
      'layer': s.currentLayer,
      'layers': s.totalLayers,
      'hotend': s.hotend,
      'hotendTarget': s.hotendTarget,
      'bed': s.bed,
      'bedTarget': s.bedTarget,
      if (s.hasChamber) 'chamber': s.chamber,
      if (s.chamberHeatable) 'chamberTarget': s.chamberTarget,
      'speed': (s.speedFactor * 100).round(),
      'flow': (s.flowFactor * 100).round(),
      'zOffset': s.zOffset,
      'light': s.led,
      'fans': [
        for (final f in s.fans) {'object': f.object, 'label': f.label, 'value': f.value},
      ],
      'objects': [for (final o in s.objects) o.name],
      'macros': c.macros,
      'canPauseAtLayer': c.canPauseAtLayer,
      if (mesh.isNotEmpty)
        'meshRange': mesh.reduce((a, b) => a > b ? a : b) - mesh.reduce((a, b) => a < b ? a : b),
      if (dragon != null)
        'heater': {
          'connected': dragon['connected'],
          'mode': dragon['mode'],
          'fault': dragon['fault'],
          'faultReason': dragon['fault_reason'],
          'temperature': dragon['temperature'],
          'target': dragon['target'],
        },
      'away': c.viaRelay,
      if (c.relayDelay != null) 'delayMs': c.relayDelay!.inMilliseconds,
      'filaments': hubFilaments(s),
    };
  }
}
