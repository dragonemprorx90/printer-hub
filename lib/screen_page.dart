import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'moonraker.dart';
import 'ui.dart';

/// Width and height from a PNG header, or null.
(int, int)? pngSize(Uint8List b) {
  if (b.length < 24 || b[1] != 0x50 || b[2] != 0x4E || b[3] != 0x47) return null;
  final d = ByteData.sublistView(b);
  return (d.getUint32(16), d.getUint32(20));
}

/// The printer's own touchscreen, mirrored and touchable (U1 extended firmware).
class ScreenPage extends StatefulWidget {
  final MoonrakerClient client;
  const ScreenPage({super.key, required this.client});
  @override
  State<ScreenPage> createState() => _ScreenPageState();
}

class _ScreenPageState extends State<ScreenPage> {
  Uint8List? _frame;
  (int, int) _size = (480, 320);
  String? _error;
  bool _alive = true, _paused = false, _viewOnly = false;
  DateTime _lastMove = DateTime(0);
  Offset _last = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loop();
  }

  @override
  void dispose() {
    _alive = false;
    super.dispose();
  }

  Future<void> _loop() async {
    final gap = Duration(milliseconds: widget.client.viaRelay ? 400 : 150);
    while (_alive) {
      if (_paused) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      try {
        final f = await widget.client.screenFrame();
        if (!_alive) return;
        setState(() {
          _frame = f;
          _size = pngSize(f) ?? _size;
          _error = null;
        });
      } catch (e) {
        if (!_alive) return;
        setState(() => _error = '$e');
        await Future.delayed(const Duration(seconds: 2));
      }
      await Future.delayed(gap);
    }
  }

  void _touch(String a, Offset p, Size box) {
    if (_viewOnly) return; // look without tapping anything by mistake
    _last = p;
    final x = (p.dx / box.width * _size.$1).round().clamp(0, _size.$1 - 1);
    final y = (p.dy / box.height * _size.$2).round().clamp(0, _size.$2 - 1);
    widget.client.screenTouch(a, x, y).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final f = _frame;
    return Scaffold(
      appBar: AppBar(title: const Text('Printer screen'), actions: [
        IconButton(
          tooltip: _viewOnly ? 'Allow touches' : 'View only (no touches)',
          icon: Icon(_viewOnly ? Icons.touch_app_outlined : Icons.do_not_touch_outlined),
          onPressed: () => setState(() => _viewOnly = !_viewOnly),
        ),
        IconButton(
          tooltip: _paused ? 'Resume' : 'Freeze the picture',
          icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
          onPressed: () => setState(() => _paused = !_paused),
        ),
        IconButton(
          tooltip: 'Save a screenshot',
          icon: const Icon(Icons.photo_camera_outlined),
          onPressed: _frame == null
              ? null
              : () async {
                  try {
                    final saved = await FilePicker.saveFile(
                        fileName: 'printer-screen-${fmtDate(DateTime.now())}.png', bytes: _frame!);
                    if (saved != null && context.mounted) toast(context, 'Screenshot saved');
                  } catch (e) {
                    if (context.mounted) toast(context, 'Could not save: $e', error: true);
                  }
                },
        ),
      ]),
      body: Center(
        child: f == null
            ? (_error == null
                ? const CircularProgressIndicator()
                : StateView.error(_error!))
            : AspectRatio(
                aspectRatio: _size.$1 / _size.$2,
                child: LayoutBuilder(builder: (_, c) {
                  final box = c.biggest;
                  return GestureDetector(
                    onTapDown: (d) => _touch('down', d.localPosition, box),
                    onTapUp: (d) => _touch('up', d.localPosition, box),
                    onPanStart: (d) => _touch('down', d.localPosition, box),
                    onPanUpdate: (d) {
                      // ponytail: ~20 moves/s is plenty for scrolling lists.
                      final now = DateTime.now();
                      if (now.difference(_lastMove).inMilliseconds < 50) return;
                      _lastMove = now;
                      _touch('move', d.localPosition, box);
                    },
                    onPanEnd: (_) => _touch('up', _last, box),
                    child: Image.memory(f, gaplessPlayback: true, fit: BoxFit.fill),
                  );
                }),
              ),
      ),
    );
  }
}
