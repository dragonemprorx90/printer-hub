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
  static const _quick = ['M114', 'M105', 'G28', 'QUERY_ENDSTOPS', 'M84'];
  late final _history = CommandHistory(settings.strings('console.history'));

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
          Expanded(
            child: StreamBuilder<List<ConsoleLine>>(
              stream: widget.client.consoleStream,
              initialData: widget.client.console,
              builder: (context, snap) {
                final lines = snap.data!;
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
        Text(fmtClock(line.time),
            style: mono.copyWith(color: C.muted, fontSize: 11)),
        const SizedBox(width: 10),
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
