import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'moonraker.dart';
import 'scan.dart';
import 'settings.dart';
import 'ui.dart';
import 'update.dart';

const _shareTag = 'PH1:';

/// Printers as one shareable code (also shown as a QR code).
String exportPrinters(List<Printer> printers) => _shareTag +
    base64Url.encode(utf8.encode(jsonEncode([for (final p in printers) p.toJson()])));

/// Throws FormatException for anything that isn't an export code.
List<Printer> importPrinters(String code) {
  final c = code.trim();
  if (!c.startsWith(_shareTag)) throw const FormatException('Not a Printer Hub code');
  final list = jsonDecode(utf8.decode(base64Url.decode(c.substring(_shareTag.length))));
  return [for (final p in list as List) Printer.fromJson(Map<String, dynamic>.from(p))];
}

class SettingsPage extends StatefulWidget {
  final List<Printer> printers;
  final void Function(List<Printer>) onImport;
  const SettingsPage({super.key, required this.printers, required this.onImport});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  void _refresh() => setState(() {});

  Widget _numberField(String key, String label, double fallback, {String? suffix}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextFormField(
          initialValue: _trim(settings.number(key, fallback)),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: suffix),
          onChanged: (v) {
            final d = double.tryParse(v.replaceAll(',', '.'));
            if (d != null && d >= 0) settings.setNumber(key, d);
          },
        ),
      );

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  Widget _presetField(String heater, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextFormField(
          initialValue: settings.presets(heater).join(', '),
          decoration: InputDecoration(labelText: label, helperText: '°C, comma separated, 0 = off'),
          onChanged: (v) {
            final list = [
              for (final p in v.split(',')) ?int.tryParse(p.trim()),
            ];
            if (list.isNotEmpty) settings.setPresets(heater, list);
          },
        ),
      );

  Future<void> _export() async {
    final code = exportPrinters(widget.printers);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share printers'),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(data: code, size: 220),
            ),
            const SizedBox(height: 12),
            Text(
              'Scan it with "Scan to import" on the other device, or copy the code '
              'and use "Import printers". API keys are included.',
              style: TextStyle(color: C.muted, fontSize: 12),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              Navigator.pop(ctx);
              toast(context, 'Code copied');
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy code'),
          ),
        ],
      ),
    );
  }

  /// Printers (with their remote codes), presets, favourites and so on.
  Future<void> _backup() async {
    if (!await confirm(context, 'Back up settings?',
            message: 'The file includes your remote access codes. Keep it private.', action: 'Save file') ||
        !mounted) {
      return;
    }
    try {
      final saved = await FilePicker.saveFile(
        fileName: 'printer-hub-backup-${fmtDate(DateTime.now())}.json',
        bytes: utf8.encode(const JsonEncoder.withIndent('  ').convert(settings.exportAll())),
      );
      if (saved != null && mounted) toast(context, 'Backup saved');
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e', error: true);
    }
  }

  Future<void> _restore() async {
    final pick = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    if (pick == null || !mounted) return;
    final bytes = await pick.readAsBytes();
    if (!mounted) return;
    try {
      final m = jsonDecode(utf8.decode(bytes));
      if (m is! Map<String, dynamic> || !m.containsKey('printers')) throw 'Not a Printer Hub backup';
      if (!await confirm(context, 'Restore this backup?',
              message: 'It replaces your printers and settings. Close and reopen the app afterwards.',
              action: 'Restore', danger: true) ||
          !mounted) {
        return;
      }
      await settings.importAll(m);
      if (mounted) toast(context, 'Restored. Close and reopen the app.');
    } catch (e) {
      if (mounted) toast(context, 'Could not restore: $e', error: true);
    }
  }

  Future<void> _import({bool scan = false}) async {
    final code = scan
        ? await scanQr(context, 'Scan printers code')
        : await askText(context, 'Import printers',
            hint: 'Paste a PH1:… code', action: 'Import');
    if (code == null || code.isEmpty || !mounted) return;
    try {
      final list = importPrinters(code);
      widget.onImport(list);
      toast(context, 'Imported ${list.length} printer(s)');
    } catch (_) {
      toast(context, 'That isn\'t a valid Printer Hub code', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Panel(
              title: 'Appearance',
              icon: Icons.palette_outlined,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'dark', icon: Icon(Icons.dark_mode_rounded), label: Text('Dark')),
                    ButtonSegment(value: 'light', icon: Icon(Icons.light_mode_rounded), label: Text('Light')),
                    ButtonSegment(value: 'system', icon: Icon(Icons.brightness_auto_rounded), label: Text('System')),
                  ],
                  selected: {settings.theme},
                  onSelectionChanged: (v) {
                    settings.theme = v.first;
                    _refresh();
                  },
                ),
                const SizedBox(height: 16),
                Text('Accent colour', style: TextStyle(color: C.muted, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final e in accents.entries)
                    Tooltip(
                      message: e.key,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () {
                          settings.accent = e.key;
                          _refresh();
                        },
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: e.value,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: settings.accent == e.key ? C.text : Colors.transparent,
                              width: 3,
                            ),
                          ),
                          child: settings.accent == e.key
                              ? const Icon(Icons.check_rounded, color: Colors.black87, size: 20)
                              : null,
                        ),
                      ),
                    ),
                ]),
              ]),
            ),
            gap,
            Panel(
              title: 'Temperature presets',
              icon: Icons.thermostat_rounded,
              child: Column(children: [
                _presetField('nozzle', 'Nozzle'),
                _presetField('bed', 'Bed'),
                _presetField('chamber', 'Chamber'),
              ]),
            ),
            gap,
            Panel(
              title: 'Notifications',
              icon: Icons.notifications_outlined,
              child: Column(children: [
                for (final (key, label) in const [
                  ('notifyDone', 'Print finished'),
                  ('notifyError', 'Print failed or cancelled'),
                  ('notifyPause', 'Print paused (e.g. filament run-out)'),
                  ('notifyHumidity', 'CFS humidity too high'),
                  ('feedback', 'Vibrate and sound while the app is open'),
                ])
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    value: settings.flag(key),
                    onChanged: (v) {
                      settings.setFlag(key, v);
                      _refresh();
                    },
                  ),
                Row(children: [
                  const Expanded(child: Text('Humidity limit')),
                  Text('${settings.number('humidityLimit', 45).round()}% RH',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                Slider(
                  value: settings.number('humidityLimit', 45),
                  min: 25,
                  max: 70,
                  divisions: 45,
                  onChanged: (v) {
                    settings.setNumber('humidityLimit', v.roundToDouble());
                    _refresh();
                  },
                ),
                Text(
                  'Alerts arrive while Printer Hub is open or in the background. '
                  'The system may ask you to allow notifications the first time.',
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
              ]),
            ),
            gap,
            Panel(
              title: 'Cost estimate',
              icon: Icons.payments_outlined,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextFormField(
                    initialValue: settings.text('currency', '\$'),
                    decoration: const InputDecoration(labelText: 'Currency symbol'),
                    onChanged: (v) => settings.setText('currency', v),
                  ),
                ),
                _numberField('filamentPrice', 'Filament price per kg', 20),
                _numberField('filamentDiameter', 'Filament diameter', 1.75, suffix: 'mm'),
                _numberField('filamentDensity', 'Filament density', 1.24, suffix: 'g/cm³'),
                _numberField('printerWatts', 'Average printer power', 350, suffix: 'W'),
                _numberField('kwhPrice', 'Electricity price per kWh', 0.30),
              ]),
            ),
            gap,
            Panel(
              title: 'Updates',
              icon: Icons.system_update_rounded,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('This is Printer Hub $kAppVersion.',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: updateRepo,
                  decoration: const InputDecoration(
                    labelText: 'Update source (GitHub owner/repo)',
                    hintText: 'yourname/printer-hub',
                    helperText: 'New versions are read from this repo\'s GitHub Releases',
                  ),
                  onChanged: (v) => settings.setText('updateRepo', v.trim()),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Check automatically once a day'),
                  value: settings.flag('updateAuto'),
                  onChanged: (v) {
                    settings.setFlag('updateAuto', v);
                    _refresh();
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () => checkForUpdateNow(context),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check for updates'),
                  ),
                ),
              ]),
            ),
            gap,
            Panel(
              title: 'Printers',
              icon: Icons.print_rounded,
              child: Wrap(spacing: 10, runSpacing: 10, children: [
                OutlinedButton.icon(
                  onPressed: widget.printers.isEmpty ? null : _export,
                  icon: const Icon(Icons.qr_code_rounded),
                  label: const Text('Share printers'),
                ),
                OutlinedButton.icon(
                  onPressed: _import,
                  icon: const Icon(Icons.input_rounded),
                  label: const Text('Import printers'),
                ),
                if (canScan)
                  OutlinedButton.icon(
                    onPressed: () => _import(scan: true),
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Scan to import'),
                  ),
                OutlinedButton.icon(
                  onPressed: _backup,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: const Text('Back up settings'),
                ),
                OutlinedButton.icon(
                  onPressed: _restore,
                  icon: const Icon(Icons.settings_backup_restore_rounded),
                  label: const Text('Restore settings'),
                ),
              ]),
            ),
            gap,
            Panel(
              title: 'About',
              icon: Icons.info_outline_rounded,
              child: Text(
                'Printer Hub $kAppVersion talks to your printers directly over your '
                'local network using Moonraker. Nothing is sent to any cloud.',
                style: TextStyle(color: C.muted),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
