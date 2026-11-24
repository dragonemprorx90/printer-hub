import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart' show orcaLink;
import 'models_page.dart' show CrealitySource;
import 'moonraker.dart';
import 'notify.dart';
import 'orca_link.dart';
import 'scan.dart';
import 'settings.dart';
import 'ui.dart';
import 'update.dart';
import 'whats_new.dart';

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

  final _scroll = ScrollController();
  final _keys = <String, GlobalKey>{};
  GlobalKey _sectionKey(String title) => _keys.putIfAbsent(title, GlobalKey.new);

  /// (what you'd look for, the section it's in)
  static const _index = [
    ('Dark or light theme', 'Appearance'), ('Accent colour', 'Appearance'), ('Text size', 'Appearance'),
    ('High contrast', 'Appearance'), ('°F / Fahrenheit', 'Appearance'), ('12-hour time', 'Appearance'),
    ('Reduce motion', 'Appearance'), ('Larger buttons', 'Appearance'), ('Bold text', 'Appearance'),
    ('Side by side on wide screens', 'Appearance'), ('Which tab printers open on', 'Appearance'), ('Reset look', 'Appearance'),
    ('Temperature presets', 'Temperature presets'),
    ('Alerts / notifications', 'Notifications'), ('Quiet hours', 'Notifications'), ('Humidity limit', 'Notifications'),
    ('Maintenance reminders', 'Notifications'), ('Test notification', 'Notifications'),
    ('Creality Cloud / Thingiverse sign-in', 'Model sites'),
    ('Currency', 'Cost estimate'), ('Filament price', 'Cost estimate'), ('Price per material', 'Cost estimate'),
    ('Electricity price / printer power', 'Cost estimate'), ('Filament density / diameter', 'Cost estimate'),
    ('Check for updates', 'Updates'), ('Back up / restore settings', 'Printers'), ('Share / import printers', 'Printers'),
    ('Orca Slicer plugin', 'Orca Slicer'), ('Watch a folder', 'Orca Slicer'),
    ('Setup guide / changelog / report a problem', 'About'), ("What's new", 'About'),
  ];

  Future<void> _find() async {
    final section = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(
          builder: (ctx, set) => Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Find a setting', prefixIcon: Icon(Icons.search_rounded)),
                onChanged: (v) => set(() => q = v.toLowerCase()),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(shrinkWrap: true, children: [
                  for (final (label, sec) in _index)
                    if (q.isEmpty || label.toLowerCase().contains(q) || sec.toLowerCase().contains(q))
                      ListTile(title: Text(label), subtitle: Text(sec), onTap: () => Navigator.pop(ctx, sec)),
                ]),
              ),
            ]),
          ),
        );
      },
    );
    if (section == null || !mounted) return;
    // Sections out of view aren't built: start at the top and scroll down
    // until it exists, then bring it into view.
    if (_sectionKey(section).currentContext == null && _scroll.hasClients) {
      _scroll.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
    }
    for (var i = 0; i < 30 && _sectionKey(section).currentContext == null && _scroll.hasClients; i++) {
      _scroll.jumpTo((_scroll.offset + 500).clamp(0, _scroll.position.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
    final c = _sectionKey(section).currentContext;
    if (c != null && c.mounted) await Scrollable.ensureVisible(c, duration: M.base, curve: M.curve);
  }

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
  Future<void> _savePlugin() async {
    try {
      final bytes = (await rootBundle.load('orca-plugin/printer_hub.py')).buffer.asUint8List();
      final saved = await FilePicker.saveFile(fileName: 'printer_hub.py', bytes: bytes);
      if (saved != null && mounted) toast(context, 'Saved. In Orca: Plugins ▸ Install ▸ choose printer_hub.py');
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e', error: true);
    }
  }

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
      if (saved != null) settings.setNumber('lastBackup', DateTime.now().millisecondsSinceEpoch.toDouble());
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
      appBar: AppBar(title: const Text('Settings'), actions: [
        IconButton(tooltip: 'Find a setting', icon: const Icon(Icons.search_rounded), onPressed: _find),
      ]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(controller: _scroll, padding: const EdgeInsets.all(16), children: [
            Panel(
              key: _sectionKey('Appearance'),
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
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      if (!await confirm(context, 'Reset the look and layout?',
                          message: 'Theme, text size, units and layout go back to the defaults. Printers, rules and notes stay.',
                          action: 'Reset')) {
                        return;
                      }
                      await settings.resetLook();
                      _refresh();
                    },
                    child: const Text('Reset to defaults'),
                  ),
                ),
                for (final (key, label, sub) in const [
                  ('highContrast', 'High contrast', 'Brighter secondary text and borders'),
                  ('fahrenheit', 'Temperatures in °F', 'Display only; the printer still uses °C'),
                  ('twelveHour', '12-hour time', 'Shows 6:42 PM instead of 18:42'),
                  ('filamentGramsUnit', 'Filament in grams', 'Shows 12.4 g instead of 4.2 m'),
                  ('reduceMotion', 'Reduce motion', 'No sliding and fading, whatever the system setting'),
                  ('bigButtons', 'Larger buttons', 'More room around everything you tap'),
                  ('awakePrinting', 'Keep the screen on during a print', 'While a printing printer is open'),
                  ('boldText', 'Bold text', 'Heavier text everywhere'),
                  ('splitView', 'Side by side on wide screens', 'iPad landscape or a wide Mac window: printers on the left, the printer on the right'),
                ])
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    subtitle: Text(sub, style: T.caption.copyWith(color: C.muted)),
                    value: settings.flag(key, false),
                    onChanged: (v) {
                      settings.setFlag(key, v);
                      settings.theme = settings.theme; // rebuild the app with the new look
                      _refresh();
                    },
                  ),
                Row(children: [
                  const Expanded(child: Text('Open printers on')),
                  Flexible(
                    child: DropdownButton<String>(
                    isExpanded: true,
                    value: settings.text('openTab', 'last'),
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 'last', child: Text('The last tab used')),
                      DropdownMenuItem(value: '0', child: Text('Overview')),
                      DropdownMenuItem(value: '1', child: Text('Control')),
                      DropdownMenuItem(value: '2', child: Text('Files')),
                      DropdownMenuItem(value: '3', child: Text('Tools')),
                      DropdownMenuItem(value: '4', child: Text('History')),
                    ],
                    onChanged: (v) {
                      settings.setText('openTab', v ?? 'last');
                      _refresh();
                    },
                  )),
                ]),
                Row(children: [
                  const Text('Text size'),
                  Expanded(
                    child: Slider(
                      min: 0.85,
                      max: 1.4,
                      divisions: 11,
                      label: '${(settings.number('textScale', 1) * 100).round()}%',
                      value: settings.number('textScale', 1).clamp(0.85, 1.4),
                      onChanged: (v) {
                        settings.setNumber('textScale', v);
                        _refresh();
                      },
                    ),
                  ),
                ]),
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
              key: _sectionKey('Temperature presets'),
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
              key: _sectionKey('Notifications'),
              title: 'Notifications',
              icon: Icons.notifications_outlined,
              child: Column(children: [
                for (final (key, label) in const [
                  ('notifyDone', 'Print finished'),
                  ('notifyError', 'Print failed or cancelled'),
                  ('notifyPause', 'Print paused (e.g. filament run-out)'),
                  ('notifyFailure', 'Possible print failure (spaghetti)'),
                  ('notifyFirstLayer', 'First layer done'),
                  ('notifyAlmost', 'Almost done (about 10 minutes left)'),
                  ('notifyHumidity', 'CFS humidity too high'),
                  ('notifyMaintenance', 'Maintenance due and spare parts low (once a day)'),
                  ('notifyDrift', 'Nozzle temperature far off its target'),
                  ('notifyStart', 'Print started'),
                  ('notifyBedCool', 'Bed has cooled after a print'),
                  ('notifyQuarters', 'At 25%, 50% and 75%'),
                  ('feedback', 'Vibrate and sound while the app is open'),
                ])
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    value: settings.flag(key, !const {'notifyStart', 'notifyQuarters', 'notifyBedCool'}.contains(key)), // these start off
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => notify('Printer Hub test', 'Alerts on this device look like this.'),
                    icon: const Icon(Icons.notifications_active_outlined, size: 18),
                    label: const Text('Send a test notification'),
                  ),
                ),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  const Text('Quiet hours (failures still come)'),
                  for (final k in const ['quietFrom', 'quietTo'])
                    TextButton(
                      onPressed: () async {
                        final t = await showTimePicker(
                            context: context, initialTime: TimeOfDay(hour: k == 'quietFrom' ? 22 : 7, minute: 0));
                        if (t == null) return;
                        settings.setText(k, '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
                        _refresh();
                      },
                      child: Text(settings.text(k).isEmpty ? (k == 'quietFrom' ? 'From…' : 'To…') : settings.text(k)),
                    ),
                  if (settings.text('quietFrom').isNotEmpty)
                    IconButton(
                      tooltip: 'No quiet hours',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        settings.setText('quietFrom', '');
                        settings.setText('quietTo', '');
                        _refresh();
                      },
                    ),
                ]),
                Text(
                  'Alerts arrive while Printer Hub is open or in the background. '
                  'The system may ask you to allow notifications the first time. '
                  'Failure alerts need the detector on your home bridge (see the setup guide); '
                  'pausing on a failure is set per printer, on its screen.',
                  style: TextStyle(color: C.muted, fontSize: 12),
                ),
              ]),
            ),
            gap,
            Panel(
              key: _sectionKey('Model sites'),
              title: 'Model sites',
              icon: Icons.travel_explore_rounded,
              child: Column(children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Creality Cloud'),
                  subtitle: Text(CrealitySource.signedIn ? 'Signed in on this device' : 'Not signed in'),
                  trailing: CrealitySource.signedIn
                      ? TextButton(
                          onPressed: () async {
                            await CrealitySource.signOut();
                            _refresh();
                          },
                          child: const Text('Sign out'))
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Thingiverse'),
                  subtitle: Text(settings.text('models.thingiverse').isEmpty ? 'No app token' : 'App token saved'),
                  trailing: settings.text('models.thingiverse').isEmpty
                      ? null
                      : TextButton(
                          onPressed: () {
                            settings.setText('models.thingiverse', '');
                            _refresh();
                          },
                          child: const Text('Remove')),
                ),
                Text('Sign-ins stay on this device and are left out of settings backups.',
                    style: TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
            gap,
            Panel(
              key: _sectionKey('Cost estimate'),
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
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Price per material'),
                  subtitle: Text('Empty = the price above', style: T.caption.copyWith(color: C.muted)),
                  children: [
                    for (final m in const ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'PA', 'PC'])
                      _numberField('price.$m', '$m per kg', settings.number('filamentPrice', 20)),
                  ],
                ),
              ]),
            ),
            gap,
            Panel(
              key: _sectionKey('Updates'),
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
              key: _sectionKey('Printers'),
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
                if (settings.number('lastBackup', 0) > 0)
                  Text('Last backup ${fmtAgo(DateTime.fromMillisecondsSinceEpoch(settings.number('lastBackup', 0).toInt()))}',
                      style: T.caption.copyWith(color: C.muted)),
                OutlinedButton.icon(
                  onPressed: _restore,
                  icon: const Icon(Icons.settings_backup_restore_rounded),
                  label: const Text('Restore settings'),
                ),
              ]),
            ),
            gap,
            if (Platform.isMacOS) ...[
              Panel(
                key: _sectionKey('Orca Slicer'),
                title: 'Orca Slicer',
                icon: Icons.layers_rounded,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_special_outlined),
                    title: const Text('Watch a folder'),
                    subtitle: Text(
                        settings.text('watch.dir').isEmpty
                            ? 'G-code saved into a folder goes to a printer (it asks before printing)'
                            : '${settings.text('watch.dir')} → ${widget.printers.where((p) => p.key == settings.text('watch.printer')).firstOrNull?.name ?? '?'}',
                        style: T.caption.copyWith(color: C.muted)),
                    trailing: settings.text('watch.dir').isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Stop watching',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              settings.setText('watch.dir', '');
                              _refresh();
                            },
                          ),
                    onTap: () async {
                      final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Folder to watch');
                      if (dir == null || !context.mounted || widget.printers.isEmpty) return;
                      final p = widget.printers.length == 1
                          ? widget.printers.first
                          : await showDialog<Printer>(
                              context: context,
                              builder: (ctx) => SimpleDialog(title: const Text('Send to which printer?'), children: [
                                for (final p in widget.printers)
                                  SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p), child: Text(p.name)),
                              ]),
                            );
                      if (p == null) return;
                      settings.setText('watch.dir', dir);
                      settings.setText('watch.printer', p.key);
                      settings.setNumber('watch.since', DateTime.now().millisecondsSinceEpoch.toDouble());
                      _refresh();
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Receive prints from Orca Slicer'),
                    subtitle: Text(orcaLink?.running == true
                        ? 'Listening on 127.0.0.1:$kOrcaPort'
                        : 'Turn on, then reopen the app'),
                    value: settings.flag('orcaLink'),
                    onChanged: (v) async {
                      settings.setFlag('orcaLink', v);
                      if (!v) await orcaLink?.stop();
                      setState(() {});
                    },
                  ),
                  Text(
                    '1. In Orca: printer ▸ Connection (the Wi-Fi icon next to the printer) ▸ '
                    'host type "Octo/Klipper", hostname 127.0.0.1:$kOrcaPort. To skip the printer question, '
                    'add its name: 127.0.0.1:$kOrcaPort/${widget.printers.isEmpty ? 'printer-name' : printerSlug(widget.printers.first.name)}\n'
                    '2. Slice and press Print or Send. Printer Hub uploads it (at home or from away) and opens print setup.\n'
                    '3. Orca 2.5+: save the plugin below and install it in Orca\'s Plugins dialog for a live printer panel. '
                    'For filament colours, set the Orca printer\'s host to 127.0.0.1 with the port shown on its card, then use Orca\'s Filament sync.',
                    style: TextStyle(color: C.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _savePlugin,
                      icon: const Icon(Icons.extension_outlined),
                      label: const Text('Save the Orca plugin'),
                    ),
                  ),
                ]),
              ),
              gap,
            ],
            Panel(
              key: _sectionKey('About'),
              title: 'About',
              icon: Icons.info_outline_rounded,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'Printer Hub $kAppVersion talks to your printers directly over your '
                  'local network using Moonraker. Nothing is sent to any cloud.',
                  style: TextStyle(color: C.muted),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ActionChip(
                    avatar: const Icon(Icons.new_releases_outlined, size: 16),
                    label: const Text("What's new"),
                    onPressed: () => showAllNotes(context),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.tour_outlined, size: 16),
                    label: const Text('Welcome tour'),
                    onPressed: () => showWelcome(context),
                  ),
                  for (final (label, icon, url) in [
                    ('Setup guide', Icons.menu_book_outlined, 'https://github.com/$kUpdateRepo/blob/main/docs/SETUP.md'),
                    ('Changelog', Icons.history_rounded, 'https://github.com/$kUpdateRepo/blob/main/CHANGELOG.md'),
                    // Only the app version goes in the link; describe the problem yourself.
                    ('Report a problem', Icons.bug_report_outlined,
                        'https://github.com/$kUpdateRepo/issues/new?title=${Uri.encodeQueryComponent('Printer Hub $kAppVersion: ')}'),
                  ])
                    ActionChip(
                      avatar: Icon(icon, size: 16),
                      label: Text(label),
                      onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                    ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
