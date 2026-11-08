import 'package:flutter/material.dart';

import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

class ControlTab extends StatefulWidget {
  final MoonrakerClient client;
  final Printer printer;
  const ControlTab({super.key, required this.client, required this.printer});
  @override
  State<ControlTab> createState() => _ControlTabState();
}

class _ControlTabState extends State<ControlTab> {
  double _step = 10;
  int _extrude = 10;
  final _macroCtl = TextEditingController();
  String _macroFilter = '';

  MoonrakerClient get c => widget.client;
  String get _favScope => 'macros.${widget.printer.key}';

  @override
  void dispose() {
    _macroCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PrinterStatus>(
      stream: c.stream,
      initialData: c.status,
      builder: (context, snap) {
        final s = snap.data!;
        final busy = s.state == 'printing' || s.state == 'paused';
        final move = _movePanel(s, busy);
        final extruder = _extruderPanel(s, busy);
        final tune = _tunePanel(s);
        final offsets = _offsetPanel(s);
        final macros = _macroPanel(busy);
        final system = _systemPanel();
        const gap = SizedBox(height: 16, width: 16);
        return LayoutBuilder(builder: (context, cons) {
          if (cons.maxWidth >= 860) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Column(
                        children: [move, gap, extruder, gap, offsets, gap, system])),
                gap,
                Expanded(child: Column(children: [tune, gap, macros])),
              ]),
            );
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            move, gap, extruder, gap, offsets, gap, tune, gap, macros, gap, system,
          ]);
        });
      },
    );
  }

  Widget _movePanel(PrinterStatus s, bool busy) {
    final pos = s.position;
    String p(int i) => i < pos.length ? pos[i].toStringAsFixed(1) : '—';
    Widget jog(String axis, double dir, IconData icon) => _PadButton(
          icon: icon,
          tooltip: '$axis${dir > 0 ? '+' : '−'}',
          onPressed:
              busy ? null : () => run(context, () => c.jog(axis, dir * _step)),
        );
    return Panel(
      title: 'Move',
      icon: Icons.open_with_rounded,
      trailing: Text('X ${p(0)}  Y ${p(1)}  Z ${p(2)}',
          style: mono.copyWith(color: C.muted, fontSize: 12)),
      child: Column(children: [
        if (busy)
          const Hint('Movement is locked while a print is running.')
        else if (s.online && s.homedAxes.length < 3)
          Hint('Axes not homed (${s.homedAxes.isEmpty ? 'none' : s.homedAxes.toUpperCase()} homed). Home before moving.'),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Column(children: [
            jog('Y', 1, Icons.keyboard_arrow_up_rounded),
            Row(mainAxisSize: MainAxisSize.min, children: [
              jog('X', -1, Icons.keyboard_arrow_left_rounded),
              _PadButton(
                icon: Icons.home_rounded,
                accent: true,
                tooltip: 'Home X Y',
                onPressed: busy ? null : () => run(context, () => c.home('X Y')),
              ),
              jog('X', 1, Icons.keyboard_arrow_right_rounded),
            ]),
            jog('Y', -1, Icons.keyboard_arrow_down_rounded),
          ]),
          const SizedBox(width: 28),
          Column(children: [
            jog('Z', 1, Icons.keyboard_double_arrow_up_rounded),
            _PadButton(
              icon: Icons.vertical_align_bottom_rounded,
              accent: true,
              tooltip: 'Home Z',
              onPressed: busy ? null : () => run(context, () => c.home('Z')),
            ),
            jog('Z', -1, Icons.keyboard_double_arrow_down_rounded),
          ]),
        ]),
        const SizedBox(height: 16),
        SegmentedButton<double>(
          showSelectedIcon: false,
          segments: [
            for (final v in const [0.1, 1.0, 10.0, 50.0])
              ButtonSegment(
                  value: v, label: Text(v < 1 ? '$v' : v.toStringAsFixed(0))),
          ],
          selected: {_step},
          onSelectionChanged: (v) => setState(() => _step = v.first),
        ),
        const SizedBox(height: 6),
        Text('Step (mm)', style: TextStyle(color: C.muted, fontSize: 12)),
      ]),
    );
  }

  Widget _extruderPanel(PrinterStatus s, bool busy) {
    final cold = s.hotend < 170;
    final disabled = busy || cold;
    return Panel(
      title: 'Extruder',
      icon: Icons.water_drop_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (cold && !busy)
          Hint('Nozzle is ${s.hotend.toStringAsFixed(0)}°C. Heat it to at least 170°C to extrude.'),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (final v in const [1, 5, 10, 25, 50])
              ButtonSegment(value: v, label: Text('$v')),
          ],
          selected: {_extrude},
          onSelectionChanged: (v) => setState(() => _extrude = v.first),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: disabled
                  ? null
                  : () => run(context, () => c.extrude(-_extrude.toDouble())),
              icon: const Icon(Icons.arrow_upward_rounded),
              label: Text('Retract $_extrude mm'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: disabled
                  ? null
                  : () => run(context, () => c.extrude(_extrude.toDouble())),
              icon: const Icon(Icons.arrow_downward_rounded),
              label: Text('Extrude $_extrude mm'),
            ),
          ),
        ]),
      ]),
    );
  }

  /// Live Z baby-stepping and pressure advance.
  Widget _offsetPanel(PrinterStatus s) {
    final z = s.zOffset;
    final pa = s.pressureAdvance;
    Widget step(String label, double mm, IconData icon) => OutlinedButton.icon(
          onPressed: s.online ? () => run(context, () => c.adjustZOffset(mm)) : null,
          icon: Icon(icon, size: 16),
          label: Text(label),
        );
    return Panel(
      title: 'Fine tuning',
      icon: Icons.straighten_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(
            child: Text('Z offset',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text('${z >= 0 ? '+' : ''}${z.toStringAsFixed(3)} mm',
              style: mono.copyWith(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text('Nudge the nozzle while the first layer goes down. Resets on restart.',
            style: TextStyle(color: C.muted, fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          step('Closer 0.05', -0.05, Icons.keyboard_double_arrow_down_rounded),
          step('Closer 0.01', -0.01, Icons.keyboard_arrow_down_rounded),
          step('Higher 0.01', 0.01, Icons.keyboard_arrow_up_rounded),
          step('Higher 0.05', 0.05, Icons.keyboard_double_arrow_up_rounded),
          TextButton(
            onPressed: z == 0 || !s.online
                ? null
                : () => run(context, () => c.gcode('SET_GCODE_OFFSET Z=0 MOVE=1')),
            child: const Text('Reset'),
          ),
        ]),
        Divider(height: 28, color: C.border),
        Row(children: [
          const Expanded(
            child: Text('Pressure advance',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text(pa.toStringAsFixed(4), style: mono.copyWith(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
            onPressed: s.online
                ? () => run(context,
                    () => c.setPressureAdvance((pa - 0.005).clamp(0, 2)))
                : null,
            child: const Text('− 0.005'),
          ),
          OutlinedButton(
            onPressed: s.online
                ? () => run(context, () => c.setPressureAdvance(pa + 0.005))
                : null,
            child: const Text('+ 0.005'),
          ),
          TextButton(
            onPressed: !s.online
                ? null
                : () async {
                    final v = await askText(context, 'Pressure advance',
                        initial: pa.toStringAsFixed(4), action: 'Set');
                    final d = double.tryParse(v ?? '');
                    if (d != null && d >= 0 && mounted) {
                      run(context, () => c.setPressureAdvance(d));
                    }
                  },
            child: const Text('Set exact…'),
          ),
        ]),
      ]),
    );
  }

  Widget _tunePanel(PrinterStatus s) {
    String pct(double v) => '${(v * 100).round()}%';
    return Panel(
      title: 'Tune',
      icon: Icons.tune_rounded,
      child: Column(children: [
        for (final f in s.fans)
          _SliderRow(
            key: ValueKey(f.object),
            label: f.label,
            icon: Icons.air_rounded,
            value: f.value,
            min: 0,
            max: 1,
            display: pct,
            onCommit: (v) => run(context, () => c.setFan(f, v)),
          ),
        _SliderRow(
          key: const ValueKey('speed'),
          label: 'Speed',
          icon: Icons.speed_rounded,
          value: s.speedFactor,
          min: 0.5,
          max: 2,
          divisions: 30,
          display: pct,
          onCommit: (v) => run(context, () => c.setSpeed((v * 100).round())),
        ),
        _SliderRow(
          key: const ValueKey('flow'),
          label: 'Flow',
          icon: Icons.opacity_rounded,
          value: s.flowFactor,
          min: 0.75,
          max: 1.25,
          divisions: 50,
          display: pct,
          onCommit: (v) => run(context, () => c.setFlow((v * 100).round())),
        ),
        if (s.led != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.lightbulb_outline_rounded, color: C.muted),
            title: const Text('Light'),
            value: s.led!,
            onChanged: (v) => run(context, () => c.setLed(v)),
          ),
      ]),
    );
  }

  Future<void> _runMacro(String m, bool busy, {bool withParams = false}) async {
    var script = m;
    if (withParams) {
      final params = await askText(context, 'Run $m with parameters',
          hint: 'e.g. TEMP=220 SPEED=50', action: 'Run');
      if (params == null || !mounted) return;
      script = '$m $params'.trim();
    } else {
      final ok = await confirm(
        context,
        'Run $m?',
        message: busy
            ? 'A print is running. Macros can move the printer or change temperatures.'
            : 'Macros can move the printer or change temperatures.',
        action: 'Run',
      );
      if (!ok || !mounted) return;
    }
    run(context, () => c.gcode(script), done: '$m finished');
  }

  Future<void> _macroMenu(String m, bool busy) async {
    final fav = settings.isFavourite(_favScope, m);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(m, style: const TextStyle(fontWeight: FontWeight.w800))),
          ListTile(
            leading: const Icon(Icons.play_arrow_rounded),
            title: const Text('Run'),
            onTap: () => Navigator.pop(ctx, 'run'),
          ),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Run with parameters…'),
            onTap: () => Navigator.pop(ctx, 'params'),
          ),
          ListTile(
            leading: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded),
            title: Text(fav ? 'Remove from favourites' : 'Add to favourites'),
            subtitle: const Text('Favourites appear on the Overview'),
            onTap: () => Navigator.pop(ctx, 'fav'),
          ),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'fav') {
      setState(() => settings.toggleFavourite(_favScope, m));
    } else {
      _runMacro(m, busy, withParams: choice == 'params');
    }
  }

  Widget _macroPanel(bool busy) {
    final q = _macroFilter.toLowerCase();
    final favs = settings.favourites(_favScope);
    final list = c.macros.where((m) => m.toLowerCase().contains(q)).toList()
      ..sort((a, b) {
        final fa = favs.contains(a), fb = favs.contains(b);
        return fa == fb ? a.compareTo(b) : (fa ? -1 : 1);
      });
    return Panel(
      title: 'Macros (${c.macros.length})',
      icon: Icons.code_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _macroCtl,
          decoration: const InputDecoration(
            hintText: 'Search macros',
            prefixIcon: Icon(Icons.search_rounded),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _macroFilter = v),
        ),
        const SizedBox(height: 6),
        Text('Tap to run · long-press or right-click for parameters and favourites',
            style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 10),
        if (list.isEmpty)
          Text('No macros found', style: TextStyle(color: C.muted))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: SingleChildScrollView(
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in list)
                  GestureDetector(
                    onLongPress: () => _macroMenu(m, busy),
                    onSecondaryTap: () => _macroMenu(m, busy),
                    child: ActionChip(
                      avatar: Icon(
                        favs.contains(m)
                            ? Icons.star_rounded
                            : Icons.play_arrow_rounded,
                        size: 16,
                        color: favs.contains(m) ? C.warn : C.accent,
                      ),
                      label: Text(m),
                      onPressed: () => _runMacro(m, busy),
                    ),
                  ),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _systemPanel() => Panel(
        title: 'System',
        icon: Icons.settings_rounded,
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          OutlinedButton.icon(
            onPressed: () async {
              if (await confirm(context, 'Restart Klipper?',
                      message: 'Reloads the config. Any print will stop.',
                      action: 'Restart',
                      danger: true) &&
                  mounted &&
                  await confirmAway(context, c.viaRelay, 'restart Klipper') &&
                  mounted) {
                run(context, c.restartKlipper);
              }
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Restart Klipper'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              if (await confirm(context, 'Firmware restart?',
                      message:
                          'Restarts Klipper and its MCUs. Any print will stop.',
                      action: 'Restart',
                      danger: true) &&
                  mounted &&
                  await confirmAway(context, c.viaRelay, 'restart the firmware') &&
                  mounted) {
                run(context, c.firmwareRestart);
              }
            },
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Firmware restart'),
          ),
        ]),
      );
}

class _PadButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool accent;
  final String? tooltip;
  const _PadButton(
      {required this.icon, this.onPressed, this.accent = false, this.tooltip});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 58,
          height: 58,
          child: IconButton.filledTonal(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: Icon(icon, size: 28),
            style: IconButton.styleFrom(
              backgroundColor:
                  accent ? C.accent.withValues(alpha: 0.18) : C.surfaceHi,
              foregroundColor: accent ? C.accent : C.text,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
      );
}

/// Slider that follows the printer's value, except while you drag it.
class _SliderRow extends StatefulWidget {
  final String label;
  final IconData icon;
  final double value, min, max;
  final int? divisions;
  final String Function(double) display;
  final ValueChanged<double> onCommit;

  const _SliderRow({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.display,
    required this.onCommit,
  });

  @override
  State<_SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<_SliderRow> {
  double? _local;

  @override
  void didUpdateWidget(_SliderRow old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _local = null;
  }

  @override
  Widget build(BuildContext context) {
    final v = (_local ?? widget.value).clamp(widget.min, widget.max).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(widget.icon, size: 18, color: C.muted),
        const SizedBox(width: 10),
        SizedBox(
          width: 120,
          child: Text(widget.label, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: (x) => setState(() => _local = x),
            onChangeEnd: widget.onCommit,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(widget.display(v),
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}
