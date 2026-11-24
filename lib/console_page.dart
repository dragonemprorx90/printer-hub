import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

/// Commands sent from the console, newest last, kept between launches.
/// [back]/[forward] walk through them like a shell's ↑/↓.
class CommandHistory {
  final List<String> items;
  int _at;
  CommandHistory(List<String> items) : items = [...items], _at = items.length;

  /// Remembers [cmd] (moving a repeat to the end), at most [cap] kept.
  void add(String cmd, {int cap = 30}) {
    items
      ..remove(cmd)
      ..add(cmd);
    if (items.length > cap) items.removeRange(0, items.length - cap);
    _at = items.length;
  }

  String? back() => items.isEmpty ? null : items[_at = (_at - 1).clamp(0, items.length - 1)];

  /// The next newer command, or '' past the newest (an empty field).
  String forward() {
    _at = (_at + 1).clamp(0, items.length);
    return _at < items.length ? items[_at] : '';
  }
}

/// Console on its own screen (opened from the app bar or Tools).
class ConsolePage extends StatelessWidget {
  final MoonrakerClient client;
  const ConsolePage({super.key, required this.client});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Console')),
        body: ConsoleTab(client: client),
      );
}

class ConsoleTab extends StatefulWidget {
  final MoonrakerClient client;
  const ConsoleTab({super.key, required this.client});
  @override
  State<ConsoleTab> createState() => _ConsoleTabState();
}

class _ConsoleTabState extends State<ConsoleTab> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  static const _defaultQuick = ['M114', 'M105', 'G28', 'QUERY_ENDSTOPS', 'M84'];
  List<String> get _quick => settings.strings('console.quick').isEmpty ? _defaultQuick : settings.strings('console.quick');

  Future<void> _editQuick() async {
    final t = await askText(context, 'Quick commands', initial: _quick.join(', '),
        hint: 'Comma-separated, e.g. M114, QUERY_ENDSTOPS', action: 'Save');
    if (t == null) return;
    final list = [for (final x in t.split(',')) if (x.trim().isNotEmpty) x.trim()];
    settings.setStrings('console.quick', list);
    setState(() {});
  }
  late final _history = CommandHistory(settings.strings('console.history'));
  String _find = '';
  bool _errorsOnly = false, _hideTemps = true;
  DateTime? _clearedAt; // "Clear" hides what came before, it doesn't delete it

  /// Lines shown with the search box, "errors only" and the "hide
  /// temperature reports" switches applied.
  List<ConsoleLine> _filter(List<ConsoleLine> all) => [
        for (final l in all)
          if ((_clearedAt == null || l.time.isAfter(_clearedAt!)) &&
              (!_errorsOnly || l.kind == ConsoleKind.error) &&
              (!_hideTemps || !isTempReport(l.text)) &&
              (_find.isEmpty || l.text.toLowerCase().contains(_find.toLowerCase())))
            l,
      ];

  /// Macros and common commands that start with what's typed (first word only).
  List<String> _suggestions() {
    final t = _ctl.text.trim().toUpperCase();
    if (t.isEmpty || t.contains(' ')) return const [];
    const common = ['G28', 'M84', 'M105', 'M114', 'M115', 'QUERY_ENDSTOPS', 'TURN_OFF_HEATERS', 'BED_MESH_CALIBRATE',
      'SAVE_CONFIG', 'STATUS', 'HELP', 'GET_POSITION', 'SET_PRESSURE_ADVANCE', 'SET_VELOCITY_LIMIT', 'FIRMWARE_RESTART'];
    return [
      for (final m in {...widget.client.macros, ...common})
        if (m.toUpperCase().startsWith(t) && m.toUpperCase() != t) m,
    ].take(8).toList();
  }

  Future<void> _save() async {
    final text = widget.client.console.map((l) => '${fmtClock(l.time)}  ${l.kind == ConsoleKind.sent ? '> ' : ''}${l.text}').join('\n');
    try {
      final saved = await FilePicker.saveFile(
          fileName: 'console-${fmtDate(DateTime.now())}.txt', bytes: Uint8List.fromList(utf8.encode(text)));
      if (saved != null && mounted) toast(context, 'Console saved');
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e', error: true);
    }
  }

  /// ↑/↓ in the command field recall earlier commands (keyboards, Mac).
  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final String? text = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowUp => _history.back(),
      LogicalKeyboardKey.arrowDown => _history.forward(),
      _ => null,
    };
    if (text == null) return KeyEventResult.ignored;
    _ctl.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    return KeyEventResult.handled;
  }

  void _copy() {
    final text = widget.client.console.map((l) => l.text).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    toast(context, 'Console copied');
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _ctl.text).trim();
    if (text.isEmpty) return;
    if (preset == null) {
      _ctl.clear();
      _focus.requestFocus();
      _history.add(text);
      settings.setStrings('console.history', _history.items);
    }
    try {
      // The G28 chip goes through home(): it lifts the nozzle clear first.
      await (preset == 'G28' ? widget.client.home() : widget.client.gcode(text));
    } catch (_) {
      // The error is already printed in the console.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(isDense: true, hintText: 'Find in output', prefixIcon: Icon(Icons.search_rounded)),
                  onChanged: (v) => setState(() => _find = v),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(label: const Text('Errors'), selected: _errorsOnly, onSelected: (v) => setState(() => _errorsOnly = v)),
              const SizedBox(width: 6),
              FilterChip(
                  label: const Text('Hide temps'), selected: _hideTemps, onSelected: (v) => setState(() => _hideTemps = v)),
              IconButton(tooltip: 'Save to a file', icon: const Icon(Icons.save_alt_rounded), onPressed: _save),
              IconButton(
                tooltip: 'Clear the view',
                icon: const Icon(Icons.clear_all_rounded),
                onPressed: () => setState(() => _clearedAt = DateTime.now()),
              ),
              IconButton(
                tooltip: settings.flag('console.times', true) ? 'Hide times' : 'Show times',
                icon: Icon(settings.flag('console.times', true) ? Icons.schedule_rounded : Icons.schedule_outlined),
                onPressed: () => setState(() => settings.setFlag('console.times', !settings.flag('console.times', true))),
              ),
            ]),
          ),
          Expanded(
            child: StreamBuilder<List<ConsoleLine>>(
              stream: widget.client.consoleStream,
              initialData: widget.client.console,
              builder: (context, snap) {
                final lines = _filter(snap.data!);
                return Container(
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(R.lg),
                    border: Border.all(color: C.border),
                  ),
                  child: lines.isEmpty
                      ? const StateView.empty(Icons.terminal_rounded, 'No console output yet')
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.all(12),
                          itemCount: lines.length,
                          itemBuilder: (_, i) =>
                              _Line(line: lines[lines.length - 1 - i]),
                        ),
                );
              },
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                if (_history.items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: PopupMenuButton<String>(
                      tooltip: 'Recent commands',
                      onSelected: (c) => _ctl.value =
                          TextEditingValue(text: c, selection: TextSelection.collapsed(offset: c.length)),
                      itemBuilder: (_) => [
                        for (final c in _history.items.reversed) PopupMenuItem(value: c, child: Text(c, style: mono)),
                      ],
                      child: const Chip(avatar: Icon(Icons.history_rounded, size: 18), label: Text('Recent')),
                    ),
                  ),
                for (final q in _quick)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(q, style: mono),
                      onPressed: () => _send(q),
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                  onPressed: _editQuick,
                ),
              ],
            ),
          ),
          if (_suggestions().isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                children: [
                  for (final m in _suggestions())
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        label: Text(m, style: mono.copyWith(fontSize: 12)),
                        onPressed: () {
                          _ctl.value = TextEditingValue(text: '$m ', selection: TextSelection.collapsed(offset: m.length + 1));
                          _focus.requestFocus();
                          setState(() {});
                        },
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              IconButton(
                tooltip: 'Copy console',
                onPressed: _copy,
                icon: const Icon(Icons.copy_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Focus(
                  onKeyEvent: _key,
                  skipTraversal: true,
                  child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  style: mono,
                  decoration: const InputDecoration(
                    hintText: 'Send G-code…',
                    prefixIcon: Icon(Icons.chevron_right_rounded),
                  ),
                  onSubmitted: (_) => _send(),
                  onChanged: (_) => setState(() {}), // refresh the suggestions
                ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: _send,
                icon: const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final ConsoleLine line;
  const _Line({required this.line});

  @override
  Widget build(BuildContext context) {
    final color = switch (line.kind) {
      ConsoleKind.sent => C.accent,
      ConsoleKind.error => C.danger,
      ConsoleKind.response => C.text,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (settings.flag('console.times', true)) ...[
          Text(fmtClock(line.time), style: mono.copyWith(color: C.muted, fontSize: 11)),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: SelectableText(
            line.kind == ConsoleKind.sent ? '> ${line.text}' : line.text,
            style: mono.copyWith(color: color),
          ),
        ),
      ]),
    );
  }
}

/// Klipper's periodic "ok T:210.0 /210.0 B:60.0 /60.0" style reports.
bool isTempReport(String line) =>
    RegExp(r'^(ok\s+)?T\d?:\s*[\d.]+\s*/\s*[\d.]+').hasMatch(line.trim()) ||
    RegExp(r'^B:\s*[\d.]+\s*/').hasMatch(line.trim());
