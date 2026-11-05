import 'dart:math' as math;

import 'package:flutter/material.dart';

class Palette {
  final Color bg, surface, surfaceHi, border, text, muted;
  const Palette({
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.border,
    required this.text,
    required this.muted,
  });

  static const dark = Palette(
    bg: Color(0xFF0B0E13),
    surface: Color(0xFF141922),
    surfaceHi: Color(0xFF1C2330),
    border: Color(0xFF252D3A),
    text: Color(0xFFE9EDF3),
    muted: Color(0xFF8B95A7),
  );
  static const light = Palette(
    bg: Color(0xFFF2F4F8),
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFEAEEF4),
    border: Color(0xFFDCE1E9),
    text: Color(0xFF111722),
    muted: Color(0xFF5D677A),
  );
}

const accents = <String, Color>{
  'Mint': Color(0xFF2EE6A6),
  'Blue': Color(0xFF4C8DFF),
  'Violet': Color(0xFF9B7BFF),
  'Orange': Color(0xFFFF8A3D),
  'Pink': Color(0xFFFF5FA2),
  'Lime': Color(0xFFB4E62E),
};

/// Current palette. Set by [buildTheme]; the app root is re-keyed whenever the
/// theme changes, so every widget rebuilds and these plain reads stay in sync.
class C {
  static Palette _p = Palette.dark;
  static Color _accent = accents['Mint']!;

  static bool get dark => identical(_p, Palette.dark);
  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surfaceHi => _p.surfaceHi;
  static Color get border => _p.border;
  static Color get text => _p.text;
  static Color get muted => _p.muted;
  static Color get accent => _accent;

  static const hot = Color(0xFFFF8A3D);
  static const bed = Color(0xFF5B9DFF);
  static const chamber = Color(0xFFB98CFF);
  static const danger = Color(0xFFFF5470);
  static const warn = Color(0xFFF5A524);

  /// One colour per extruder on multi-tool printers (Snapmaker U1).
  static const tools = [hot, Color(0xFFFFC145), Color(0xFF3DDC97), Color(0xFFFF6FB5)];
}

const mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier New', 'monospace'],
  fontSize: 13,
);

ThemeData buildTheme(Palette p, Color accent) {
  C._p = p;
  C._accent = accent;
  final brightness = C.dark ? Brightness.dark : Brightness.light;
  // Light backgrounds need a deeper accent for readable text and icons.
  final primary = C.dark ? accent : Color.lerp(accent, Colors.black, 0.32)!;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
    primary: primary,
    onPrimary: C.dark ? const Color(0xFF06120D) : Colors.white,
    secondaryContainer: accent.withValues(alpha: 0.18),
    onSecondaryContainer: p.text,
    surface: p.bg,
    onSurface: p.text,
    error: C.danger,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: accent.withValues(alpha: 0.18),
      height: 68,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.surface,
      indicatorColor: accent.withValues(alpha: 0.18),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceHi,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    popupMenuTheme: PopupMenuThemeData(color: p.surface),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: p.border, space: 1),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: p.surfaceHi,
      thumbColor: accent,
      trackHeight: 6,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceHi,
      side: BorderSide(color: p.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : null),
    ),
  );
}

List<BoxShadow>? get _softShadow => C.dark
    ? null
    : const [
        BoxShadow(color: Color(0x0F000000), blurRadius: 14, offset: Offset(0, 4)),
      ];

/// The rounded card every section sits in.
class Panel extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const Panel({
    super.key,
    this.title,
    this.icon,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.border),
        boxShadow: _softShadow,
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: C.muted),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  title!.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: C.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const Spacer(),
              ?trailing,
            ]),
            const SizedBox(height: 14),
          ],
          child,
        ],
      ),
    );
  }
}

/// Tappable card surface used by list rows and tiles.
class Tile extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  const Tile({super.key, required this.child, this.onTap, this.radius = 16});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: _softShadow,
        ),
        child: Material(
          color: C.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: C.border),
          ),
          child: InkWell(onTap: onTap, child: child),
        ),
      );
}

/// Circular temperature gauge with a target tick. Animates between readings.
class TempGauge extends StatelessWidget {
  final String label;
  final IconData icon;
  final double temp, target, max;
  final Color color;
  final VoidCallback? onTap;

  const TempGauge({
    super.key,
    required this.label,
    required this.icon,
    required this.temp,
    required this.target,
    required this.max,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final heating = target > 0;
    return Tile(
      radius: 20,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 14),
        child: LayoutBuilder(builder: (context, c) {
          final d = math.min(104.0, c.maxWidth);
          return Column(children: [
            SizedBox(
              width: d,
              height: d,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: temp),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => CustomPaint(
                  painter: _ArcPainter(
                    (t / max).clamp(0.0, 1.0),
                    heating ? (target / max).clamp(0.0, 1.0) : null,
                    color,
                    C.surfaceHi,
                    C.text,
                  ),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        '${t.toStringAsFixed(0)}°',
                        style: TextStyle(
                            fontSize: d > 90 ? 26 : 20,
                            fontWeight: FontWeight.w800),
                      ),
                      Text(
                        heating ? '→ ${target.toStringAsFixed(0)}°' : 'off',
                        style: TextStyle(
                            fontSize: 12, color: heating ? color : C.muted),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ]),
          ]);
        }),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double value;
  final double? target;
  final Color color, track, tick;
  _ArcPainter(this.value, this.target, this.color, this.track, this.tick);

  static const _start = math.pi * 0.75, _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(7);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(r, _start, _sweep, false, p);
    if (value > 0) {
      canvas.drawArc(r, _start, _sweep * value, false, p..color = color);
    }
    if (target != null) {
      final a = _start + _sweep * target!;
      final dir = Offset(math.cos(a), math.sin(a));
      final rad = r.width / 2;
      canvas.drawLine(
        r.center + dir * (rad - 7),
        r.center + dir * (rad + 7),
        Paint()
          ..color = tick
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter o) =>
      o.value != value || o.target != target || o.color != color;
}

/// Animated circular progress with a centred label.
class ProgressRing extends StatelessWidget {
  final double value;
  final double size, stroke;
  final Color? color;
  final Widget? center;
  const ProgressRing({
    super.key,
    required this.value,
    this.size = 112,
    this.stroke = 10,
    this.color,
    this.center,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Stack(fit: StackFit.expand, children: [
            CircularProgressIndicator(
              value: v,
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              backgroundColor: C.surfaceHi,
              color: color ?? C.accent,
            ),
            Center(
              child: center ??
                  Text('${(v * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: size / 4.3, fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      );
}

(Color, String) statusStyle(String state, bool online) {
  if (!online) return (C.muted, 'Connecting');
  return switch (state) {
    'printing' => (C.accent, 'Printing'),
    'paused' => (C.warn, 'Paused'),
    'error' => (C.danger, 'Error'),
    'complete' => (C.bed, 'Complete'),
    'cancelled' => (C.muted, 'Cancelled'),
    _ => (C.text, 'Ready'),
  };
}

class StatusPill extends StatelessWidget {
  final String state;
  final bool online;
  const StatusPill({super.key, required this.state, required this.online});

  @override
  Widget build(BuildContext context) {
    final (color, label) = statusStyle(state, online);
    final live = online && state == 'printing';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: live
                ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6)]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class StatTile extends StatelessWidget {
  final String label, value;
  const StatTile({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ],
      );
}

/// Amber info strip for "you can't do this right now" hints.
class Hint extends StatelessWidget {
  final String text;
  final Color? color;
  const Hint(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? C.warn;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, size: 18, color: c),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }
}

/// Section heading inside a page.
class Heading extends StatelessWidget {
  final String text;
  const Heading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        child: Text(text,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      );
}

String fmtDuration(num? secs) {
  if (secs == null || secs <= 0) return '—';
  final d = Duration(seconds: secs.round());
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

String fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _two(int n) => n.toString().padLeft(2, '0');
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String fmtAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return fmtDate(t);
}

String fmtDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

String fmtClock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// "18:42" today, "Tue 18:42" on another day.
String fmtTime(DateTime t) {
  final now = DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  return sameDay ? hm : '${_days[t.weekday - 1]} $hm';
}

String fmtFilament(num mm) {
  if (mm <= 0) return '—';
  if (mm >= 1000) return '${(mm / 1000).toStringAsFixed(1)} m';
  return '${mm.toStringAsFixed(0)} mm';
}

void toast(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    backgroundColor: error ? C.danger : null,
    content: Text(text, style: error ? const TextStyle(color: Colors.white) : null),
  ));
}

/// Runs a printer action and reports failure (or success) in a snackbar.
Future<void> run(BuildContext context, Future<void> Function() action,
    {String? done}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      backgroundColor: C.danger,
      content: Text('$e', style: const TextStyle(color: Colors.white)),
    ));
  }
}

Future<bool> confirm(BuildContext context, String title,
    {String? message, String action = 'Confirm', bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: C.danger, foregroundColor: Colors.white)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Number prompt with one-tap presets (0 shows as "Off").
Future<int?> askNumber(BuildContext context, String title,
    {List<int> presets = const [], String unit = '°C'}) {
  final c = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (presets.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in presets)
                ActionChip(
                  label: Text(p == 0 ? 'Off' : '$p$unit'),
                  onPressed: () => Navigator.pop(ctx, p),
                ),
            ]),
          const SizedBox(height: 16),
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'Custom', suffixText: unit),
            onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)),
            child: const Text('Set')),
      ],
    ),
  );
}

/// Free-text prompt.
Future<String?> askText(BuildContext context, String title,
    {String initial = '', String? hint, String action = 'OK'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(action)),
      ],
    ),
  );
}
