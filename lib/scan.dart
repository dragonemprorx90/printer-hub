import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hub_link/hub_link.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Platforms with a camera mobile_scanner supports. Elsewhere callers fall
/// back to pasting.
bool get canScan => !kIsWeb && (Platform.isIOS || Platform.isAndroid || Platform.isMacOS);

/// The scanned text as a home-bridge pairing code, or null if it isn't one.
String? pairCodeFrom(String? raw) {
  final c = raw?.trim() ?? '';
  try {
    PairInfo.decode(c);
    return c;
  } catch (_) {
    return null;
  }
}

/// Opens the camera and returns the first QR code's text (null if cancelled).
Future<String?> scanQr(BuildContext context, String title) =>
    Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => _ScanPage(title)));

class _ScanPage extends StatefulWidget {
  final String title;
  const _ScanPage(this.title);
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: MobileScanner(
          onDetect: (capture) {
            final v = capture.barcodes.firstOrNull?.rawValue;
            if (_done || v == null || v.isEmpty) return;
            _done = true;
            Navigator.pop(context, v);
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Camera unavailable: ${error.errorCode.name}',
                  textAlign: TextAlign.center),
            ),
          ),
        ),
      );
}
