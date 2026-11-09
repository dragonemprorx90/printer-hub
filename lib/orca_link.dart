import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'moonraker.dart';

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
  final _proxies = <HttpServer>[];

  OrcaLink({required this.onUpload, required this.printers, this.port = kOrcaPort});

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle, onError: (_) {});
    // One local Moonraker per printer (port + 4 + index), so OrcaSlicer's own
    // printer agents (device page, filament sync, printing) reach the printer
    // through Printer Hub, at home or through the relay from anywhere.
    // ponytail: ports follow the printer list order; "Use this printer" re-reads them.
    for (final (i, p) in printers().indexed) {
      try {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, proxyPort(i));
        s.listen((r) => _proxy(p, r), onError: (_) {});
        _proxies.add(s);
      } catch (_) {} // port taken: that printer just has no Orca proxy
    }
  }

  int proxyPort(int index) => port + 4 + index;

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    for (final s in _proxies) {
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
        switch (req.uri.queryParameters['do']) {
          case 'pause':
            await c.pause();
          case 'resume':
            await c.resume();
          case 'cancel':
            await c.cancel();
          case 'light':
            await c.setLed(!(c.status.led ?? false));
          default:
            return json(400, {'error': 'unknown action'});
        }
        json(200, {'ok': true});
      } else if (path == '/hub/printers') {
        json(200, [
          for (final p in printers())
            {
              'name': p.name,
              'slug': printerSlug(p.name),
              'proxy': '127.0.0.1:${proxyPort(printers().indexOf(p))}',
              'host': p.host,
              'port': p.port,
              ...orcaModel(clientFor(p)),
              ..._status(clientFor(p).status),
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

  static Map<String, Object?> _status(PrinterStatus s) => {
        'online': s.online,
        'state': s.state,
        'file': s.filename,
        'progress': s.progress,
        'eta': s.eta,
        'hotend': s.hotend,
        'bed': s.bed,
        'light': s.led,
        'filaments': hubFilaments(s),
      };
}
