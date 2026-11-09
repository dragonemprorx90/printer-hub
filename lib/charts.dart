import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'moonraker.dart';
import 'ui.dart';

class Series {
  final String label;
  final Color color;
  final List<double> values;
  final List<double>? targets;
  Series(this.label, this.color, this.values, [this.targets]);
}

/// Line chart of recent temperatures, newest on the right.
class TempChart extends StatelessWidget {
  final List<Series> series;
  final double height;
  const TempChart({super.key, required this.series, this.height = 170});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(
                painter: _TempPainter(series, C.border, C.muted)),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 6, children: [
            for (final s in series)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: s.color, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 6),
                Text(
                  '${s.label} ${s.values.isEmpty ? '' : '${s.values.last.toStringAsFixed(0)}°'}',
                  style: TextStyle(fontSize: 12, color: C.muted),
                ),
              ]),
          ]),
        ],
      );
}

class _TempPainter extends CustomPainter {
  final List<Series> series;
  final Color grid, label;
  _TempPainter(this.series, this.grid, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    var top = 50.0;
    for (final s in series) {
      for (final v in [...s.values, ...?s.targets]) {
        top = math.max(top, v);
      }
    }
    top = (top / 50).ceil() * 50.0;
    const left = 34.0;
    final w = size.width - left, h = size.height - 4;
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = h - h * i / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gp);
      final tp = TextPainter(
        text: TextSpan(
            text: (top * i / 4).toStringAsFixed(0),
            style: TextStyle(color: label, fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }
    for (final s in series) {
      void line(List<double> v, Paint p) {
        if (v.length < 2) return;
        final path = Path();
        for (var i = 0; i < v.length; i++) {
          final pt = Offset(left + w * i / (v.length - 1), h - h * (v[i] / top));
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(path, p);
      }

      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = s.color;
      line(s.values, p);
      final t = s.targets;
      if (t != null && t.any((v) => v > 0)) {
        line(t, p
          ..strokeWidth = 1
          ..color = s.color.withValues(alpha: 0.45));
      }
    }
  }

  @override
  bool shouldRepaint(_TempPainter o) => true;
}

/// Simple labelled bar chart.
class BarChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color? color;
  final String Function(double)? format;
  const BarChart(
      {super.key,
      required this.values,
      required this.labels,
      this.color,
      this.format});

  @override
  Widget build(BuildContext context) {
    final top = values.fold<double>(0, math.max);
    return SizedBox(
      height: 160,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (values[i] > 0)
                  Text(format?.call(values[i]) ?? values[i].toStringAsFixed(0),
                      style: TextStyle(fontSize: 11, color: C.muted)),
                const SizedBox(height: 4),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: top == 0 ? 0 : values[i] / top),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (_, f, _) => Container(
                    height: math.max(2, 110 * f),
                    decoration: BoxDecoration(
                      color: (color ?? C.accent)
                          .withValues(alpha: values[i] > 0 ? 0.85 : 0.2),
                      borderRadius: BorderRadius.circular(R.sm),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(labels[i],
                    style: TextStyle(fontSize: 11, color: C.muted),
                    overflow: TextOverflow.clip,
                    maxLines: 1),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Bed mesh as a colour grid: blue = low, accent = flat, red = high.
/// Rows are drawn back-to-front so it reads like looking down at the bed.
class MeshView extends StatelessWidget {
  final List<List<double>> mesh;
  const MeshView({super.key, required this.mesh});

  @override
  Widget build(BuildContext context) {
    final flat = [for (final r in mesh) ...r];
    final span = flat.map((v) => v.abs()).fold<double>(0.0001, math.max);
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(builder: (context, c) {
        final cols = mesh.first.length;
        final cell = c.maxWidth / cols;
        return Column(children: [
          for (final row in mesh.reversed)
            Row(children: [
              for (final v in row)
                Container(
                  width: cell,
                  height: c.maxHeight / mesh.length,
                  margin: EdgeInsets.zero,
                  decoration: BoxDecoration(
                    color: meshColor(v / span),
                    border: Border.all(color: C.surface, width: 1),
                  ),
                  alignment: Alignment.center,
                  child: cell > 34
                      ? Text(v.toStringAsFixed(2),
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                              fontWeight: FontWeight.w600))
                      : null,
                ),
            ]),
        ]);
      }),
    );
  }
}

/// -1 → blue, 0 → accent, 1 → red.
Color meshColor(double t) => t < 0
    ? Color.lerp(C.accent, C.bed, -t.clamp(-1.0, 0.0))!
    : Color.lerp(C.accent, C.danger, t.clamp(0.0, 1.0))!;

/// Plate map of the objects in the current print; tap one to exclude it.
class ObjectMap extends StatelessWidget {
  final List<PrintObject> objects;
  final Set<String> excluded;
  final String? current;
  final double bedW, bedH;
  final ValueChanged<PrintObject> onTap;

  const ObjectMap({
    super.key,
    required this.objects,
    required this.excluded,
    required this.current,
    required this.bedW,
    required this.bedH,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: bedW / bedH,
        child: LayoutBuilder(builder: (context, c) {
          final s = c.maxWidth / bedW;
          Offset toScreen((double, double) p) =>
              Offset(p.$1 * s, c.maxHeight - p.$2 * s);
          return GestureDetector(
            onTapUp: (d) {
              for (final o in objects) {
                if (excluded.contains(o.name)) continue;
                final path = _path(o, toScreen);
                if (path != null && path.contains(d.localPosition)) {
                  return onTap(o);
                }
              }
            },
            child: CustomPaint(
              painter: _ObjectPainter(objects, excluded, current, toScreen),
            ),
          );
        }),
      );
}

Path? _path(PrintObject o, Offset Function((double, double)) toScreen) {
  if (o.polygon.length >= 3) {
    return Path()..addPolygon([for (final p in o.polygon) toScreen(p)], true);
  }
  if (o.center != null) {
    return Path()..addOval(Rect.fromCircle(center: toScreen(o.center!), radius: 14));
  }
  return null;
}

class _ObjectPainter extends CustomPainter {
  final List<PrintObject> objects;
  final Set<String> excluded;
  final String? current;
  final Offset Function((double, double)) toScreen;
  _ObjectPainter(this.objects, this.excluded, this.current, this.toScreen);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(R.md)),
      Paint()..color = C.surfaceHi,
    );
    for (final o in objects) {
      final path = _path(o, toScreen);
      if (path == null) continue;
      final out = excluded.contains(o.name);
      final color = out
          ? C.muted
          : o.name == current
              ? C.accent
              : C.bed;
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: out ? 0.15 : 0.35));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color);
    }
  }

  @override
  bool shouldRepaint(_ObjectPainter o) => true;
}
