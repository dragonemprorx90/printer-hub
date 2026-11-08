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

  OrcaLink({required this.onUpload, required this.printers, this.port = kOrcaPort});

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
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
      } else if (path == '/hub/printers') {
        json(200, [
          for (final p in printers())
            {'name': p.name, 'slug': printerSlug(p.name), ..._status(clientFor(p).status)},
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
      };
}
