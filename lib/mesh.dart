import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The model in the slice editor as a triangle soup: 9 floats per triangle
/// (three x, y, z corners), in mm.
///
/// ponytail: drawn with Canvas.drawVertices, sorted back to front, flat
/// shaded. No WebGL view, no 3D package: nothing to bridge multi-MB meshes
/// into, it works offline, and it runs in widget tests. Big meshes are
/// thinned for display ([decimate]); slicing always uses the full mesh.
class Mesh {
  final Float32List v;
  const Mesh(this.v);
  int get triangles => v.length ~/ 9;
}

/// Reads a binary or ASCII STL.
Mesh parseStl(Uint8List b) {
  final d = ByteData.sublistView(b);
  final n = b.length >= 84 ? d.getUint32(80, Endian.little) : -1;
  final ascii = latin1.decode(b.sublist(0, math.min(5, b.length))).toLowerCase() == 'solid';
  if (n > 0 && (84 + n * 50 == b.length || (!ascii && 84 + n * 50 <= b.length))) {
    final v = Float32List(n * 9);
    for (var i = 0; i < n; i++) {
      for (var k = 0; k < 9; k++) {
        v[i * 9 + k] = d.getFloat32(84 + i * 50 + 12 + k * 4, Endian.little);
      }
    }
    return Mesh(v);
  }
  final out = <double>[];
  for (final m in RegExp(r'vertex\s+(\S+)\s+(\S+)\s+(\S+)').allMatches(latin1.decode(b, allowInvalid: true))) {
    for (var k = 1; k <= 3; k++) {
      out.add(double.tryParse(m.group(k)!) ?? 0);
    }
  }
  if (out.length < 9) throw const FormatException('No triangles in this STL');
  return Mesh(Float32List.fromList(out.sublist(0, out.length - out.length % 9)));
}

/// Binary STL of [v] (9 floats per triangle). Orca works out the normals.
Uint8List toStl(Float32List v) {
  final n = v.length ~/ 9;
  final b = Uint8List(84 + n * 50);
  final d = ByteData.sublistView(b);
  b.setAll(0, ascii.encode('Printer Hub'));
  d.setUint32(80, n, Endian.little);
  for (var i = 0; i < n; i++) {
    for (var k = 0; k < 9; k++) {
      d.setFloat32(84 + i * 50 + 12 + k * 4, v[i * 9 + k], Endian.little);
    }
  }
  return b;
}

/// At most [max] triangles for drawing, by vertex clustering: corners in the
/// same grid cell merge, and triangles that collapse are dropped.
Mesh decimate(Mesh m, [int max = 60000]) {
  if (m.triangles <= max) return m;
  final v = m.v;
  final lo = [double.infinity, double.infinity, double.infinity];
  final hi = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < v.length; i++) {
    lo[i % 3] = math.min(lo[i % 3], v[i]);
    hi[i % 3] = math.max(hi[i % 3], v[i]);
  }
  final size = math.max(hi[0] - lo[0], math.max(hi[1] - lo[1], hi[2] - lo[2]));
  for (var cells = 400;; cells = (cells * 0.75).floor()) {
    final cell = size / cells;
    final first = <int, int>{};
    final out = <double>[];
    int key(int i) =>
        ((v[i] - lo[0]) / cell).floor() |
        ((v[i + 1] - lo[1]) / cell).floor() << 10 |
        ((v[i + 2] - lo[2]) / cell).floor() << 20;
    for (var t = 0; t < v.length; t += 9) {
      final a = key(t), b = key(t + 3), c = key(t + 6);
      if (a == b || b == c || a == c) continue;
      for (final (k, i) in [(a, t), (b, t + 3), (c, t + 6)]) {
        final j = first.putIfAbsent(k, () => i);
        out.addAll([v[j], v[j + 1], v[j + 2]]);
      }
    }
    if (out.length ~/ 9 <= max || cells < 16) return Mesh(Float32List.fromList(out));
  }
}

// --- Placement --------------------------------------------------------------

/// 3×3 rotation, row major.
typedef Rot = List<double>;
const Rot identity = [1, 0, 0, 0, 1, 0, 0, 0, 1];

Rot mulRot(Rot a, Rot b) => [
      for (var r = 0; r < 3; r++)
        for (var c = 0; c < 3; c++) a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c],
    ];

/// Rotation by [deg] about plate axis 0 (X), 1 (Y) or 2 (Z).
Rot axisRot(int axis, double deg) {
  final a = deg * math.pi / 180, c = math.cos(a), s = math.sin(a);
  return switch (axis) {
    0 => [1, 0, 0, 0, c, -s, 0, s, c],
    1 => [c, 0, s, 0, 1, 0, -s, 0, c],
    _ => [c, -s, 0, s, c, 0, 0, 0, 1],
  };
}

/// The rotation that turns direction [n] straight down (lay flat on a face).
Rot downRot(double nx, double ny, double nz) {
  final l = math.sqrt(nx * nx + ny * ny + nz * nz);
  if (l == 0) return identity;
  nx /= l;
  ny /= l;
  nz /= l;
  // Axis n × (0,0,-1), angle acos(-nz); Rodrigues.
  final ax = -ny, ay = nx, s = math.sqrt(ax * ax + ay * ay), c = -nz;
  if (s < 1e-9) return c > 0 ? identity : axisRot(0, 180);
  final x = ax / s, y = ay / s, t = 1 - c;
  return [
    t * x * x + c, t * x * y, s * y,
    t * x * y, t * y * y + c, -s * x,
    -s * y, s * x, c,
  ];
}

/// Where the model sits: rotated and scaled about its own origin, then moved
/// so its footprint is centred on ([x], [y]) and it rests on the plate.
class Placement {
  final Rot rot;
  final double scale, x, y;
  const Placement({this.rot = identity, this.scale = 1, required this.x, required this.y});
  Placement copyWith({Rot? rot, double? scale, double? x, double? y}) =>
      Placement(rot: rot ?? this.rot, scale: scale ?? this.scale, x: x ?? this.x, y: y ?? this.y);
}

/// Min and max corner of [v] after [rot] and [scale].
(List<double>, List<double>) turnedBounds(Float32List v, Rot rot, double scale) {
  final lo = [double.infinity, double.infinity, double.infinity];
  final hi = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < v.length; i += 3) {
    for (var r = 0; r < 3; r++) {
      final p = scale * (rot[r * 3] * v[i] + rot[r * 3 + 1] * v[i + 1] + rot[r * 3 + 2] * v[i + 2]);
      if (p < lo[r]) lo[r] = p;
      if (p > hi[r]) hi[r] = p;
    }
  }
  return (lo, hi);
}

/// [v] placed on the plate. [bounds] comes from [turnedBounds] of the full
/// mesh, so a thinned display mesh lands exactly where the sliced one does.
Float32List place(Float32List v, Placement p, (List<double>, List<double>) bounds) {
  final (lo, hi) = bounds;
  final off = [p.x - (lo[0] + hi[0]) / 2, p.y - (lo[1] + hi[1]) / 2, -lo[2]];
  final r = p.rot, s = p.scale;
  final out = Float32List(v.length);
  for (var i = 0; i < v.length; i += 3) {
    for (var k = 0; k < 3; k++) {
      out[i + k] = s * (r[k * 3] * v[i] + r[k * 3 + 1] * v[i + 1] + r[k * 3 + 2] * v[i + 2]) + off[k];
    }
  }
  return out;
}

// --- Camera -----------------------------------------------------------------

/// Orbit camera around [tx], [ty], [tz] (plate coordinates, Z up).
class Camera {
  double yaw, pitch, dist, tx, ty, tz;
  Camera(this.yaw, this.pitch, this.dist, this.tx, this.ty, this.tz);
  factory Camera.forBed(List<double> bed) =>
      Camera(-math.pi / 2 - 0.55, 0.6, bed.reduce(math.max) * 1.9, bed[0] / 2, bed[1] / 2, 0);
}

/// One frame's projection: plate point -> screen point and depth.
class Projection {
  late final double ex, ey, ez, fx, fy, fz, rx, ry, ux, uy, uz, focal, cx, cy;
  static const near = 1.0;

  Projection(Camera c, Size s) {
    final cp = math.cos(c.pitch);
    ex = c.tx + c.dist * cp * math.cos(c.yaw);
    ey = c.ty + c.dist * cp * math.sin(c.yaw);
    ez = c.tz + c.dist * math.sin(c.pitch);
    final fl = c.dist;
    fx = (c.tx - ex) / fl;
    fy = (c.ty - ey) / fl;
    fz = (c.tz - ez) / fl;
    // right = f × up(0,0,1); up = right × f
    final rl = math.sqrt(fy * fy + fx * fx);
    rx = fy / rl;
    ry = -fx / rl;
    ux = ry * fz;
    uy = -rx * fz;
    uz = rx * fy - ry * fx;
    focal = s.height / (2 * math.tan(0.4)); // ~46° vertical field of view
    cx = s.width / 2;
    cy = s.height / 2;
  }

  /// Depth of (x, y, z); writes its screen position to out[o], out[o + 1].
  double project(double x, double y, double z, Float32List out, int o) {
    final dx = x - ex, dy = y - ey, dz = z - ez;
    final d = dx * fx + dy * fy + dz * fz;
    final k = focal / math.max(d, near);
    out[o] = cx + (dx * rx + dy * ry) * k;
    out[o + 1] = cy - (dx * ux + dy * uy + dz * uz) * k;
    return d;
  }

  /// The plate point (z = 0) under screen point [p], if it faces the plate.
  Offset? onPlate(Offset p) {
    final sx = (p.dx - cx) / focal, sy = -(p.dy - cy) / focal;
    final dx = fx + rx * sx + ux * sy, dy = fy + ry * sx + uy * sy, dz = fz + uz * sy;
    if (dz > -1e-6) return null;
    final t = -ez / dz;
    return Offset(ex + dx * t, ey + dy * t);
  }

  /// How far the orbit target moves for a two-finger drag of [delta].
  (double, double, double) pan(Offset delta, double dist) {
    final k = dist / focal;
    return (-(rx * delta.dx - ux * delta.dy) * k, -(ry * delta.dx - uy * delta.dy) * k, uz * delta.dy * k);
  }
}

/// Index of the front-most triangle of [v] under [p], or null.
int? pick(Float32List v, Projection view, Offset p) {
  final s = Float32List(6);
  int? best;
  var bestD = double.infinity;
  for (var t = 0; t < v.length; t += 9) {
    var d = 0.0, behind = false;
    for (var k = 0; k < 3; k++) {
      final z = view.project(v[t + k * 3], v[t + k * 3 + 1], v[t + k * 3 + 2], s, k * 2);
      behind |= z < Projection.near;
      d += z;
    }
    if (behind || d >= bestD) continue;
    double side(int a, int b) => (s[b] - s[a]) * (p.dy - s[a + 1]) - (s[b + 1] - s[a + 1]) * (p.dx - s[a]);
    final e0 = side(0, 2), e1 = side(2, 4), e2 = side(4, 0);
    if ((e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0)) {
      best = t ~/ 9;
      bestD = d;
    }
  }
  return best;
}

/// Normal of triangle [t] from its winding (not normalised).
(double, double, double) normalOf(Float32List v, int t) {
  final o = t * 9;
  final ax = v[o + 3] - v[o], ay = v[o + 4] - v[o + 1], az = v[o + 5] - v[o + 2];
  final bx = v[o + 6] - v[o], by = v[o + 7] - v[o + 1], bz = v[o + 8] - v[o + 2];
  return (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx);
}

// --- Drawing ----------------------------------------------------------------

class MeshPainter extends CustomPainter {
  final Float32List v;
  final Camera cam;
  final List<double> bed;
  final Color color, plate, grid;
  final int? highlight;

  MeshPainter(this.v, this.cam, this.bed,
      {required this.color, required this.plate, required this.grid, this.highlight});

  @override
  void paint(Canvas canvas, Size size) {
    final view = Projection(cam, size);
    final s = Float32List(2);
    Offset at(double x, double y, double z) {
      view.project(x, y, z, s, 0);
      return Offset(s[0], s[1]);
    }

    final (w, d, h) = (bed[0], bed[1], bed[2]);
    final bottom = [at(0, 0, 0), at(w, 0, 0), at(w, d, 0), at(0, d, 0)];
    canvas.drawPath(Path()..addPolygon(bottom, true), Paint()..color = plate);
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var x = 0.0; x <= w + 0.1; x += 50) {
      canvas.drawLine(at(x, 0, 0), at(x, d, 0), line);
    }
    for (var y = 0.0; y <= d + 0.1; y += 50) {
      canvas.drawLine(at(0, y, 0), at(w, y, 0), line);
    }

    // Model: project, shade, sort back to front.
    final n = v.length ~/ 9;
    final pos = Float32List(n * 6), depth = Float32List(n), shade = Float32List(n);
    final order = <int>[];
    // Light from over the viewer's shoulder.
    final lx = -view.fx + view.ux * 0.6, ly = -view.fy + view.uy * 0.6, lz = -view.fz + view.uz * 0.6;
    final ll = math.sqrt(lx * lx + ly * ly + lz * lz);
    for (var t = 0; t < n; t++) {
      var dd = 0.0, behind = false;
      for (var k = 0; k < 3; k++) {
        final z = view.project(v[t * 9 + k * 3], v[t * 9 + k * 3 + 1], v[t * 9 + k * 3 + 2], pos, t * 6 + k * 2);
        behind |= z < Projection.near;
        dd += z;
      }
      if (behind) continue;
      final (nx, ny, nz) = normalOf(v, t);
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      shade[t] = nl == 0 ? 0.5 : ((nx * lx + ny * ly + nz * lz) / (nl * ll)).abs();
      depth[t] = dd;
      order.add(t);
    }
    order.sort((a, b) => depth[b].compareTo(depth[a]));
    final out = Float32List(order.length * 6);
    final cols = Int32List(order.length * 3);
    for (var i = 0; i < order.length; i++) {
      final t = order[i];
      out.setRange(i * 6, i * 6 + 6, pos, t * 6);
      final base = t == highlight ? Colors.white : color;
      final k = 0.35 + 0.65 * shade[t];
      final c = Color.from(alpha: 1, red: base.r * k, green: base.g * k, blue: base.b * k);
      cols.fillRange(i * 3, i * 3 + 3, c.toARGB32());
    }
    if (order.isNotEmpty) {
      canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, out, colors: cols), BlendMode.dst, Paint());
    }

    // Build volume outline.
    final box = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke;
    final top = [at(0, 0, h), at(w, 0, h), at(w, d, h), at(0, d, h)];
    canvas.drawPath(Path()..addPolygon(top, true), box);
    for (var i = 0; i < 4; i++) {
      canvas.drawLine(bottom[i], top[i], box);
    }
  }

  @override
  bool shouldRepaint(MeshPainter o) => true; // the camera is mutable
}

/// The plate and model: drag to orbit, pinch or scroll to zoom, two fingers
/// to pan. Dragging on the model moves it on the plate instead ([onMove]);
/// in [layFlat] mode a tap picks the face to lay it on ([onFace]).
class MeshView extends StatefulWidget {
  final Float32List mesh;
  final List<double> bed;
  final Color color;
  final bool layFlat;
  final void Function(double dx, double dy)? onMove;
  final void Function(int triangle)? onFace;
  const MeshView(
      {super.key,
      required this.mesh,
      required this.bed,
      required this.color,
      this.layFlat = false,
      this.onMove,
      this.onFace});
  @override
  State<MeshView> createState() => MeshViewState();
}

class MeshViewState extends State<MeshView> {
  late Camera cam = Camera.forBed(widget.bed);
  Size _size = Size.zero;
  Offset? _grab; // plate point under the finger while moving the model
  double _scale = 1;
  int? _hover;

  void reset() => setState(() => cam = Camera.forBed(widget.bed));

  @override
  void didUpdateWidget(MeshView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bed[0] != widget.bed[0]) cam = Camera.forBed(widget.bed);
    if (!widget.layFlat) _hover = null;
  }

  Projection get _view => Projection(cam, _size);

  void _start(ScaleStartDetails d) {
    _scale = 1;
    _grab = null;
    if (d.pointerCount == 1 &&
        !widget.layFlat &&
        widget.onMove != null &&
        pick(widget.mesh, _view, d.localFocalPoint) != null) {
      _grab = _view.onPlate(d.localFocalPoint);
    }
  }

  void _update(ScaleUpdateDetails d) {
    setState(() {
      if (d.pointerCount >= 2) {
        cam.dist = (cam.dist * _scale / d.scale).clamp(30.0, 3000.0);
        _scale = d.scale;
        final (x, y, z) = _view.pan(d.focalPointDelta, cam.dist);
        cam
          ..tx += x
          ..ty += y
          ..tz = (cam.tz + z).clamp(0.0, widget.bed[2]);
      } else if (_grab != null) {
        final p = _view.onPlate(d.localFocalPoint);
        if (p == null) return;
        widget.onMove!(p.dx - _grab!.dx, p.dy - _grab!.dy);
        _grab = p;
      } else {
        cam.yaw -= d.focalPointDelta.dx * 0.01;
        cam.pitch = (cam.pitch + d.focalPointDelta.dy * 0.01).clamp(-0.2, 1.55);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            setState(() => cam.dist = (cam.dist * math.exp(e.scrollDelta.dy * 0.002)).clamp(30.0, 3000.0));
          }
        },
        child: MouseRegion(
          cursor: widget.layFlat ? SystemMouseCursors.precise : SystemMouseCursors.grab,
          onHover: widget.layFlat ? (e) => setState(() => _hover = pick(widget.mesh, _view, e.localPosition)) : null,
          child: GestureDetector(
            onScaleStart: _start,
            onScaleUpdate: _update,
            onScaleEnd: (_) => _grab = null,
            onTapUp: widget.layFlat
                ? (d) {
                    final t = pick(widget.mesh, _view, d.localPosition);
                    if (t != null) widget.onFace?.call(t);
                  }
                : null,
            child: CustomPaint(
              size: Size.infinite,
              painter: MeshPainter(widget.mesh, cam, widget.bed,
                  color: widget.color,
                  plate: scheme.surfaceContainerHighest,
                  grid: scheme.outlineVariant,
                  highlight: _hover),
            ),
          ),
        ),
      );
    });
  }
}
