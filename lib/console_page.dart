import 'package:flutter/material.dart';

import 'moonraker.dart';
import 'ui.dart';

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
    }
    try {
      await widget.client.gcode(text);
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
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: C.border),
                  ),
                  child: lines.isEmpty
                      ? Center(
                          child: Text('No console output yet',
                              style: TextStyle(color: C.muted)))
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
              Expanded(
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
