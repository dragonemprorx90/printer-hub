import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hub_link/hub_link.dart';

import 'discovery.dart';
import 'gcode.dart';
import 'moonraker.dart';
import 'notify.dart';
import 'orca_link.dart';
import 'printer_page.dart';
import 'settings.dart';
import 'scan.dart';
import 'settings_page.dart';
import 'u1_panels.dart';
import 'ui.dart';
import 'update.dart';
import 'wall_page.dart';
import 'whats_new.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  runApp(const PrinterHubApp());
  // Not awaited: the system permission prompt must never hold up the UI.
  initNotifications();
}

class PrinterHubApp extends StatefulWidget {
  const PrinterHubApp({super.key});
  @override
  State<PrinterHubApp> createState() => _PrinterHubAppState();
}

class _PrinterHubAppState extends State<PrinterHubApp> with WidgetsBindingObserver {
  String? _lastLook;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    settings.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    settings.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (settings.theme == 'system') _changed();
  }

  void _changed() => setState(() {});

  Palette get _palette {
    final t = settings.theme;
    if (t == 'system') {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark
          ? Palette.dark
          : Palette.light;
    }
    return t == 'light' ? Palette.light : Palette.dark;
  }

  /// Screens read colours from [C] directly, so after a theme switch every
  /// element is rebuilt once. Navigation and state are kept.
  void _rebuildAll() {
    void walk(Element e) {
      e.markNeedsBuild();
      e.visitChildren(walk);
    }

    (context as Element).visitChildren(walk);
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette;
    final accent = accents[settings.accent] ?? accents['Mint']!;
    final look = '${identical(palette, Palette.dark)}-${settings.accent}';
    final theme = buildTheme(palette, accent);
    if (_lastLook != null && _lastLook != look) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
    }
    _lastLook = look;
    return MaterialApp(
      title: 'Printer Hub',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const PrinterListPage(),
    );
  }
}

class PrinterListPage extends StatefulWidget {
  const PrinterListPage({super.key});
  @override
  State<PrinterListPage> createState() => _PrinterListPageState();
}

/// Running OrcaSlicer link (macOS), if on.
OrcaLink? orcaLink;

class _PrinterListPageState extends State<PrinterListPage> {
  late List<Printer> _printers = [
    for (final s in settings.strings('printers')) Printer.fromJson(jsonDecode(s)),
  ];

  @override
  void initState() {
    super.initState();
    for (final p in _printers) {
      watchPrinter(p, clientFor(p));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await showWhatsNewIfUpdated(context, freshInstall: _printers.isEmpty);
      if (mounted) autoCheckForUpdate(context);
    });
    if (Platform.isMacOS && settings.flag('orcaLink')) {
      orcaLink = OrcaLink(onUpload: _fromOrca, printers: () => _printers);
      orcaLink!.start().catchError((Object e) => debugPrint('Orca link: $e'));
    }
  }

  /// A file OrcaSlicer sent: pick the printer, upload, then print setup.
  Future<void> _fromOrca(OrcaUpload u) async {
    const MethodChannel('printerhub/statusbar').invokeMethod('activate').catchError((_) {});
    if (_printers.isEmpty || !mounted) return;
    var name = u.name;
    var bytes = u.bytes;
    if (name.toLowerCase().endsWith('.3mf')) {
      final plates = platesIn3mf(bytes);
      if (plates.isEmpty) return toast(context, 'No sliced plate in $name', error: true);
      final n = (plates.keys.toList()..sort()).first;
      name = '${name.replaceAll(RegExp(r'(\.gcode)?\.3mf$', caseSensitive: false), '')}_plate$n.gcode';
      bytes = plates[n]!;
    }
    var target = _printers.where((p) => printerSlug(p.name) == u.printer).firstOrNull;
    target ??= _printers.length == 1
        ? _printers.first
        : await showDialog<Printer>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: Text('From Orca Slicer: $name'),
              children: [
                for (final p in _printers)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, p),
                    child: ListTile(
                      leading: Icon(Icons.print_rounded,
                          color: Color(settings.printerColor(p.key) ?? C.accent.toARGB32())),
                      title: Text(p.name),
                      subtitle: Text(clientFor(p).status.online ? clientFor(p).status.state : 'offline'),
                    ),
                  ),
              ],
            ),
          );
    if (target == null || !mounted) return;
    final c = clientFor(target);
    final to = target;
    var sent = false;
    await run(context, () async {
      await c.upload(name, bytes);
      sent = true;
    }, done: u.print ? null : '$name sent to ${to.name}');
    if (!sent || !u.print || !mounted) return;
    if (c.isSnapmaker) {
      final meta = await c.metadataWhenReady(name);
      if (mounted) await snapmakerPrintSetup(context, c, name, meta);
    } else if (await confirm(context, 'Print $name on ${to.name}?', action: 'Print') && mounted) {
      await run(context, () => c.startPrint(name), done: 'Printing on ${to.name}');
    }
  }

  void _save() => settings.setStrings(
      'printers', [for (final p in _printers) jsonEncode(p.toJson())]);

  Future<void> _edit({Printer? existing, Printer? prefill}) async {
    final p = await showDialog<Printer>(
      context: context,
      builder: (_) => PrinterDialog(initial: existing ?? prefill, editing: existing != null),
    );
    if (p == null) return;
    setState(() {
      if (existing == null) {
        _printers.add(p);
      } else {
        dropClient(existing);
        _printers[_printers.indexOf(existing)] = p;
      }
    });
    watchPrinter(p, clientFor(p));
    _save();
  }

  Future<void> _delete(Printer p) async {
    if (!await confirm(context, 'Remove ${p.name}?', action: 'Remove', danger: true)) {
      return;
    }
    dropClient(p);
    setState(() => _printers.remove(p));
    _save();
  }

  void _import(List<Printer> list) {
    final known = {for (final p in _printers) p.key};
    setState(() => _printers = [..._printers, ...list.where((p) => !known.contains(p.key))]);
    for (final p in _printers) {
      watchPrinter(p, clientFor(p));
    }
    _save();
  }

  void _scan() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => _DiscoverySheet(
          known: {for (final p in _printers) p.host},
          onAdd: (f) {
            Navigator.pop(context);
            _edit(prefill: Printer(name: f.name, host: f.host));
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: const Text('Printer Hub',
            style: T.hero),
        actions: [
          IconButton(
              tooltip: 'Find printers on this network',
              icon: const Icon(Icons.radar_rounded),
              onPressed: _scan),
          if (_printers.isNotEmpty)
            IconButton(
              tooltip: 'Wall view',
              icon: const Icon(Icons.grid_view_rounded),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => WallPage(printers: _printers))),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsPage(printers: _printers, onImport: _import),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _printers.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add printer'),
            ),
      body: _printers.isEmpty
          ? _EmptyState(onAdd: () => _edit(), onScan: _scan)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  itemCount: _printers.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final p = _printers[i];
                    return _PrinterCard(
                      printer: p,
                      onOpen: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => PrinterPage(printer: p))),
                      onEdit: () => _edit(existing: p),
                      onDelete: () => _delete(p),
                    );
                  },
                ),
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd, onScan;
  const _EmptyState({required this.onAdd, required this.onScan});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: C.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.print_rounded, size: 44, color: C.accent),
            ),
            const SizedBox(height: 20),
            const Text('No printers yet',
                style: T.heading),
            const SizedBox(height: 8),
            Text(
              'Add any Klipper / Moonraker printer by its IP address,\n'
              'or let Printer Hub look for them on your Wi-Fi.',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.muted),
            ),
            const SizedBox(height: 24),
            Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
              FilledButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.radar_rounded),
                label: const Text('Find printers'),
              ),
              OutlinedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add by IP'),
              ),
            ]),
          ]),
        ),
      );
}

const _printerColors = [
  0xFF339CFF, 0xFF5DC977, 0xFFF3883B, 0xFFE5484D, 0xFF8E4EC6, 0xFFE93D82, 0xFF12A594, 0xFFAD7F58,
];

Future<int?> pickPrinterColor(BuildContext context) => showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Printer colour'),
        content: Wrap(spacing: 10, runSpacing: 10, children: [
          for (final c in _printerColors)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.pop(ctx, c),
              child: CircleAvatar(radius: 20, backgroundColor: Color(c)),
            ),
        ]),
      ),
    );

class _PrinterCard extends StatelessWidget {
  final Printer printer;
  final VoidCallback onOpen, onEdit, onDelete;
  const _PrinterCard({
    required this.printer,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final client = clientFor(printer);
    return StreamBuilder<PrinterStatus>(
      stream: client.stream,
      initialData: client.status,
      builder: (context, snap) {
        final s = snap.data!;
        final active = s.online && (s.state == 'printing' || s.state == 'paused');
        final eta = s.eta;
        return Tile(
          radius: 20,
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              if (active)
                ProgressRing(
                  value: s.progress,
                  size: 64,
                  stroke: 6,
                  color: s.state == 'paused' ? C.warn : null,
                  center: s.filename == null
                      ? null
                      : ClipOval(
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: FutureBuilder<Uint8List?>(
                              future: Thumbs.of(client, s.filename!),
                              builder: (_, t) => t.data == null
                                  ? Center(
                                      child: Text(
                                          '${(s.progress * 100).toStringAsFixed(0)}%',
                                          style: const TextStyle(
                                              fontSize: 13, fontWeight: FontWeight.w800)))
                                  : Image.memory(t.data!, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                )
              else
                StatefulBuilder(builder: (context, set) {
                  final tint = Color(settings.printerColor(printer.key) ?? C.accent.toARGB32());
                  return Tooltip(
                    message: 'Printer colour',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(R.xl),
                      onTap: () async {
                        final c = await pickPrinterColor(context);
                        if (c != null) set(() => settings.setPrinterColor(printer.key, c));
                      },
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(R.xl),
                        ),
                        child: Icon(Icons.print_rounded, color: tint, size: 30),
                      ),
                    ),
                  );
                }),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(printer.name,
                          overflow: TextOverflow.ellipsis,
                          style: T.title),
                    ),
                    StatusPill(state: s.state, online: s.online),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    active
                        ? '${(s.progress * 100).toStringAsFixed(0)}% · ${s.filename ?? ''}'
                        : '${printer.host}:${printer.port}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: C.muted, fontSize: 13),
                  ),
                  if (s.online) ...[
                    const SizedBox(height: 10),
                    Wrap(spacing: 16, runSpacing: 6, children: [
                      _mini(Icons.local_fire_department_rounded, C.hot, s.hotend,
                          s.hotendTarget),
                      _mini(Icons.grid_view_rounded, C.bed, s.bed, s.bedTarget),
                      if (s.hasChamber)
                        _mini(Icons.thermostat_rounded, C.chamber, s.chamber,
                            s.chamberTarget),
                      if (active && eta != null)
                        Text(
                          'done ${fmtTime(DateTime.now().add(Duration(seconds: eta.round())))}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                    ]),
                  ],
                ]),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: C.muted),
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _mini(IconData icon, Color color, double t, double target) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          '${t.toStringAsFixed(0)}°'
          '${target > 0 ? ' / ${target.toStringAsFixed(0)}°' : ''}',
          style: const TextStyle(fontSize: 13),
        ),
      ]);
}

class _DiscoverySheet extends StatefulWidget {
  final Set<String> known;
  final ValueChanged<FoundPrinter> onAdd;
  const _DiscoverySheet({required this.known, required this.onAdd});
  @override
  State<_DiscoverySheet> createState() => _DiscoverySheetState();
}

class _DiscoverySheetState extends State<_DiscoverySheet> {
  final _found = <FoundPrinter>[];
  double _progress = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    discoverPrinters(onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    }).listen(
      (f) => mounted ? setState(() => _found.add(f)) : null,
      onDone: () => mounted ? setState(() => _done = true) : null,
      onError: (_) => mounted ? setState(() => _done = true) : null,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Find printers',
                style: T.title),
            const SizedBox(height: 4),
            Text(
              _done
                  ? 'Finished. ${_found.isEmpty ? 'No printers answered.' : 'Tap Add to set one up.'}'
                  : 'Looking for Klipper printers (Moonraker, port 7125) on your network…',
              style: TextStyle(color: C.muted),
            ),
            const SizedBox(height: 12),
            if (!_done)
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(value: _progress, minHeight: 6),
              ),
            const SizedBox(height: 8),
            for (final f in _found)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.print_rounded, color: C.accent),
                title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(f.host),
                trailing: widget.known.contains(f.host)
                    ? Text('Added', style: TextStyle(color: C.muted))
                    : FilledButton(onPressed: () => widget.onAdd(f), child: const Text('Add')),
              ),
          ]),
        ),
      );
}

class PrinterDialog extends StatefulWidget {
  final Printer? initial;
  final bool editing;
  const PrinterDialog({super.key, this.initial, this.editing = false});
  @override
  State<PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<PrinterDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _host = TextEditingController(text: widget.initial?.host ?? '');
  late final _port = TextEditingController(text: '${widget.initial?.port ?? 7125}');
  late final _key = TextEditingController(text: widget.initial?.apiKey ?? '');
  late final _cam = TextEditingController(text: widget.initial?.cameraUrl ?? '');
  late final _relay = TextEditingController(text: widget.initial?.relayCode ?? '');
  String? _error;

  void _save() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Enter the printer\'s IP address');
      return;
    }
    final code = _relay.text.trim();
    if (code.isNotEmpty) {
      try {
        PairInfo.decode(code);
      } catch (_) {
        setState(() => _error = 'That remote access code is not valid. '
            'Copy it again from the home bridge.');
        return;
      }
    }
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.pop(
      context,
      Printer(
        name: opt(_name) ?? host,
        host: host,
        port: int.tryParse(_port.text) ?? 7125,
        apiKey: opt(_key),
        cameraUrl: opt(_cam),
        relayCode: opt(_relay),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.editing ? 'Edit printer' : 'Add printer'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _field(_name, 'Name', hint: 'K2 Plus'),
            _field(_host, 'IP address', hint: '192.168.1.50'),
            _field(_port, 'Moonraker port', number: true),
            _field(_key, 'API key (optional)'),
            _field(_cam, 'Camera URL (optional)', hint: 'Leave empty to auto-detect'),
            _field(_relay, 'Remote access code (optional)',
                hint: 'PHB1:… from your home bridge, for use away from home',
                suffix: canScan
                    ? IconButton(
                        tooltip: 'Scan QR code',
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        onPressed: _scanRelay,
                      )
                    : null),
            if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Future<void> _scanRelay() async {
    final raw = await scanQr(context, 'Scan remote access code');
    if (raw == null || !mounted) return;
    final code = pairCodeFrom(raw);
    setState(() {
      if (code != null) _relay.text = code;
      _error = code == null ? 'That QR code is not a remote access code.' : null;
    });
  }

  Widget _field(TextEditingController c, String label,
          {String? hint, bool number = false, Widget? suffix}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          keyboardType: number ? TextInputType.number : null,
          decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix),
        ),
      );
}
