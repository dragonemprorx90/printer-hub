import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'moonraker.dart';

/// Largest thumbnail embedded in a G-code header ("; thumbnail begin WxH N").
/// Orca, PrusaSlicer and Creality Print all write this block.
Uint8List? parseThumbnail(String head) {
  final re = RegExp(
    r'^; thumbnail(?:_(?:PNG|JPG))? begin (\d+)x(\d+) \d+\r?\n([\s\S]*?)^; thumbnail(?:_(?:PNG|JPG))? end',
    multiLine: true,
  );
  Uint8List? best;
  var bestWidth = 0;
  for (final m in re.allMatches(head)) {
    final w = int.parse(m[1]!);
    if (w <= bestWidth) continue;
    final b64 = m[3]!
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^;\s?'), '').trim())
        .join();
    try {
      best = base64.decode(b64);
      bestWidth = w;
    } catch (_) {}
  }
  return best;
}

/// File thumbnails, fetched from the first bytes of each file and cached.
class Thumbs {
  static final _cache = <String, Future<Uint8List?>>{};
  static int _active = 0;
  static final _waiting = <Completer<void>>[];

  static Future<Uint8List?> of(MoonrakerClient c, String path) =>
      _cache.putIfAbsent('${c.host}|$path', () => _load(c, path));

  static Future<Uint8List?> _load(MoonrakerClient c, String path) async {
    // ponytail: at most 4 downloads in flight so a long list doesn't flood
    // the printer's little web server.
    while (_active >= 4) {
      final w = Completer<void>();
      _waiting.add(w);
      await w.future;
    }
    _active++;
    try {
      final bytes = await c.downloadRange(path, 0, 196607);
      return parseThumbnail(latin1.decode(bytes, allowInvalid: true));
    } catch (_) {
      return null;
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

/// Extruding moves of a G-code file, split into layers.
class GcodeModel {
  /// Per layer: x1, y1, x2, y2 for every extruding segment.
  final List<Float32List> layers;
  final List<double> z;
  final double minX, minY, maxX, maxY;
  GcodeModel(this.layers, this.z, this.minX, this.minY, this.maxX, this.maxY);
  int get segments => layers.fold(0, (n, l) => n + l.length ~/ 4);
}

/// Parses extrusion moves. Top-level so it can run in an isolate (compute).
GcodeModel parseGcode(String text) {
  double x = 0, y = 0, z = 0, e = 0;
  var absXYZ = true, absE = true;
  final layers = <List<double>>[];
  final zs = <double>[];
  double minX = double.infinity, minY = double.infinity;
  double maxX = -double.infinity, maxY = -double.infinity;

  for (final raw in const LineSplitter().convert(text)) {
    final semi = raw.indexOf(';');
    final line = (semi >= 0 ? raw.substring(0, semi) : raw).trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    final cmd = parts[0].toUpperCase();
    switch (cmd) {
      case 'G90':
        absXYZ = true;
        absE = true;
      case 'G91':
        absXYZ = false;
        absE = false;
      case 'M82':
        absE = true;
      case 'M83':
        absE = false;
      case 'G92':
        for (final p in parts.skip(1)) {
          final v = double.tryParse(p.substring(1));
          if (v == null) continue;
          switch (p[0].toUpperCase()) {
            case 'X':
              x = v;
            case 'Y':
              y = v;
            case 'Z':
              z = v;
            case 'E':
              e = v;
          }
        }
      case 'G0' || 'G1' || 'G2' || 'G3':
        double? nx, ny, nz, ne;
        for (final p in parts.skip(1)) {
          if (p.isEmpty) continue;
          final v = double.tryParse(p.substring(1));
          if (v == null) continue;
          switch (p[0].toUpperCase()) {
            case 'X':
              nx = absXYZ ? v : x + v;
            case 'Y':
              ny = absXYZ ? v : y + v;
            case 'Z':
              nz = absXYZ ? v : z + v;
            case 'E':
              ne = v;
          }
        }
        if (nz != null) z = nz;
        final tx = nx ?? x, ty = ny ?? y;
        final extruding = ne != null && (absE ? ne - e : ne) > 1e-5;
        if (extruding && (tx != x || ty != y)) {
          if (zs.isEmpty || (z - zs.last).abs() > 1e-4) {
            layers.add(<double>[]);
            zs.add(z);
          }
          layers.last.addAll([x, y, tx, ty]);
          minX = math.min(minX, math.min(x, tx));
          maxX = math.max(maxX, math.max(x, tx));
          minY = math.min(minY, math.min(y, ty));
          maxY = math.max(maxY, math.max(y, ty));
        }
        x = tx;
        y = ty;
        if (ne != null) e = absE ? ne : e + ne;
    }
  }
  if (layers.isEmpty) return GcodeModel(const [], const [], 0, 0, 1, 1);
  return GcodeModel(
    [for (final l in layers) Float32List.fromList(l)],
    zs,
    minX,
    minY,
    maxX,
    maxY,
  );
}

/// Draws one layer (and the one below it, faded) on the bed.
class LayerPainter extends CustomPainter {
  final GcodeModel model;
  final int layer;
  final double bedW, bedH;
  final Color color, below, border;

  LayerPainter(this.model, this.layer, this.bedW, this.bedH,
      {required this.color, required this.below, required this.border});

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / bedW, size.height / bedH);
    final w = bedW * s, h = bedH * s;
    final ox = (size.width - w) / 2, oy = (size.height - h) / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(ox, oy, w, h), const Radius.circular(8)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = border,
    );
    if (model.layers.isEmpty) return;
    canvas.save();
    // G-code Y grows towards the back of the bed, screen Y grows downwards.
    canvas.translate(ox, oy + h);
    canvas.scale(s, -s);
    final p = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.45;
    if (layer > 0) {
      canvas.drawRawPoints(
          ui.PointMode.lines, model.layers[layer - 1], p..color = below);
    }
    canvas.drawRawPoints(ui.PointMode.lines, model.layers[layer], p..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(LayerPainter o) =>
      o.layer != layer || o.model != model || o.color != color;
}
