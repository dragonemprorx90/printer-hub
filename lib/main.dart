import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';
import 'package:url_launcher/url_launcher.dart';

import 'camera.dart';
import 'discovery.dart';
import 'gcode.dart';
import 'insights.dart';
import 'moonraker.dart';
import 'notify.dart';
import 'orca_link.dart';
import 'printer_page.dart';
import 'settings.dart';
import 'scan.dart';
import 'settings_page.dart';
import 'slice_where.dart';
import 'u1_panels.dart';
import 'ui.dart';
import 'workshop_page.dart';
import 'update.dart';
import 'wall_page.dart';
import 'whats_new.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await migrateSandboxPrefs();
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
    final palette = settings.flag('highContrast', false) ? _palette.contrast() : _palette;
    Units.fahrenheit = settings.flag('fahrenheit', false);
    Units.twelveHour = settings.flag('twelveHour', false);
    Units.grams = settings.flag('filamentGramsUnit', false);
    final accent = accents[settings.accent] ?? accents['Mint']!;
    final look = '${palette.bg.toARGB32()}-${palette.muted.toARGB32()}-${settings.accent}-${Units.fahrenheit}-${Units.twelveHour}'
        '-${settings.flag('bigButtons', false)}-${settings.flag('boldText', false)}-${Units.grams}';
    var theme = buildTheme(palette, accent);
    if (settings.flag('bigButtons', false)) {
      // Bigger touch targets everywhere.
      theme = theme.copyWith(visualDensity: VisualDensity.comfortable, materialTapTargetSize: MaterialTapTargetSize.padded);
    }
    if (_lastLook != null && _lastLook != look) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
    }
    _lastLook = look;
    return MaterialApp(
      title: 'Printer Hub',
      debugShowCheckedModeBanner: false,
      theme: theme,
      // In-app text size (Settings → Appearance) on top of the system's.
      builder: (context, child) {
        final scale = settings.number('textScale', 1);
        final still = settings.flag('reduceMotion', false), bold = settings.flag('boldText', false);
        if (scale == 1 && !still && !bold) return child!;
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(mq.textScaler.scale(1) * scale),
            disableAnimations: still || mq.disableAnimations,
            boldText: bold || mq.boldText,
          ),
          child: child!,
        );
      },
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

  static const _launch = MethodChannel('printerhub/launch');

  /// `printerhub://printer/NAME`, `printerhub://wall`, or `file:PATH` (a
  /// G-code / 3MF opened with Printer Hub). The Mac menu sends a printer key.
  Future<void> _handleLaunch(String what) async {
    if (!mounted || _printers.isEmpty) return;
    if (what.startsWith('file:')) {
      final f = File(what.substring(5));
      if (!f.existsSync()) return;
      final bytes = await f.readAsBytes();
      return _fromOrca((name: f.uri.pathSegments.last, bytes: bytes, print: false, printer: null));
    }
    final u = Uri.tryParse(what);
    if (u != null && u.scheme == 'printerhub') {
      if (u.host == 'wall') {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => WallPage(printers: _printers)));
      } else if (u.host == 'printer' && u.pathSegments.isNotEmpty) {
        final name = u.pathSegments.first.toLowerCase();
        final p = _printers
            .where((p) => p.name.toLowerCase() == name || printerSlug(p.name) == name || p.host == name)
            .firstOrNull;
        if (p != null) _open(p);
      }
      return;
    }
    final p = _printers.where((p) => p.key == what).firstOrNull;
    if (p != null) _open(p);
  }

  void _open(Printer p) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PrinterPage(printer: p)));
  }

  @override
  void initState() {
    super.initState();
    for (final p in _printers) {
      watchPrinter(p, clientFor(p));
    }
    onOpenFromNotification = (key) => _handleLaunch(key);
    _whileAway();
    const MethodChannel('printerhub/statusbar').setMethodCallHandler((call) async {
      if (call.method == 'openPrinter') await _handleLaunch('${call.arguments}');
    });
    if (Platform.isIOS) {
      _launch.setMethodCallHandler((call) async {
        if (call.method == 'open') await _handleLaunch('${call.arguments}');
      });
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final pending = await _launch.invokeListMethod<String>('pending').catchError((_) => null);
        for (final w in pending ?? const <String>[]) {
          await _handleLaunch(w);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await showWhatsNewIfUpdated(context, freshInstall: _printers.isEmpty);
      if (mounted) autoCheckForUpdate(context);
    });
    if (Platform.isMacOS && settings.flag('orcaLink')) {
      orcaLink = OrcaLink(onUpload: _fromOrca, printers: () => _printers);
      orcaLink!.start().catchError((Object e) => debugPrint('Orca link: $e'));
    }
    // Mac: G-code saved into a watched folder goes to a printer (asks before printing).
    if (Platform.isMacOS) _watch = Timer.periodic(const Duration(seconds: 10), (_) => _checkWatched());
    // Models the phone sent to this Mac's OrcaSlicer wait in each printer's inbox.
    if (Platform.isMacOS && orcaApp() != null) {
      _inbox = Timer.periodic(const Duration(seconds: 20), (_) => _checkInbox());
    }
  }

  Timer? _inbox, _watch;
  bool _inboxBusy = false, _watchBusy = false;

  Future<void> _checkWatched() async {
    final dir = settings.text('watch.dir');
    if (dir.isEmpty || _watchBusy || !mounted) return;
    final target = _printers.where((p) => p.key == settings.text('watch.printer')).firstOrNull;
    if (target == null) return;
    _watchBusy = true;
    try {
      final since = settings.number('watch.since', DateTime.now().millisecondsSinceEpoch.toDouble());
      final d = Directory(dir);
      if (!d.existsSync()) return;
      final fresh = [
        for (final f in d.listSync().whereType<File>())
          if (f.path.toLowerCase().endsWith('.gcode') && f.lastModifiedSync().millisecondsSinceEpoch > since) f,
      ];
      if (fresh.isEmpty) {
        if (settings.number('watch.since', -1) < 0) settings.setNumber('watch.since', since);
        return;
      }
      settings.setNumber('watch.since', DateTime.now().millisecondsSinceEpoch.toDouble());
      // Give a slicer a moment to finish writing.
      await Future.delayed(const Duration(seconds: 2));
      for (final f in fresh) {
        if (!mounted) return;
        await _fromOrca((name: f.uri.pathSegments.last, bytes: await f.readAsBytes(), print: true, printer: printerSlug(target.name)));
      }
    } catch (e) {
      debugPrint('Watch folder: $e');
    } finally {
      _watchBusy = false;
    }
  }

  Future<void> _checkInbox() async {
    if (_inboxBusy) return;
    _inboxBusy = true;
    try {
      for (final p in [..._printers]) {
        final c = clientFor(p);
        if (!c.status.online) continue;
        for (final name in await takeInbox(c)) {
          if (mounted) toast(context, 'Opened $name from your phone in OrcaSlicer');
        }
      }
    } finally {
      _inboxBusy = false;
    }
  }

  @override
  void dispose() {
    _inbox?.cancel();
    _watch?.cancel();
    super.dispose();
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
    } else if (await confirm(context, 'Print $name on ${to.name}?', action: 'Print') && mounted && await preflight(context) && mounted) {
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
    if (existing == null && _printers.any((x) => x.key == p.key)) {
      if (mounted) toast(context, '${p.host}:${p.port} is already in your list', error: true);
      return;
    }
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
          onAddAll: (list) {
            Navigator.pop(context);
            _import([for (final f in list) Printer(name: f.name, host: f.host)]);
            toast(context, 'Added ${list.length} printers. Edit each to add its camera or remote access code.');
          },
          onAdd: (f) {
            Navigator.pop(context);
            _edit(prefill: Printer(name: f.name, host: f.host));
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Keyboard: ⌘/Ctrl 1–9 open a printer, L the camera wall, comma Settings.
    final mod = Platform.isMacOS;
    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < _printers.length && i < 9; i++)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: mod, control: !mod):
              () => _open(_printers[i]),
        SingleActivator(LogicalKeyboardKey.keyL, meta: mod, control: !mod): () => _handleLaunch('printerhub://wall'),
        SingleActivator(LogicalKeyboardKey.comma, meta: mod, control: !mod): () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => SettingsPage(printers: _printers, onImport: _import))),
      },
      child: Focus(autofocus: true, child: _scaffold()),
    );
  }

  /// "While you were away…", worked out a few seconds after opening.
  String _away = '';

  Future<void> _whileAway() async {
    final since = DateTime.fromMillisecondsSinceEpoch(settings.number('lastOpen', 0).toInt());
    settings.setNumber('lastOpen', DateTime.now().millisecondsSinceEpoch.toDouble());
    if (since.millisecondsSinceEpoch == 0) return;
    await Future.delayed(const Duration(seconds: 6)); // History loads when each printer connects
    if (!mounted) return;
    final text = awaySummary([
      for (final p in _printers)
        if (clientFor(p).lastHistory case final h?) (p.name, h.$1),
    ], since);
    if (text.isNotEmpty && mounted) setState(() => _away = text);
  }

  Stream<void>? _fleetStream;
  String _fleetKeys = '';

  /// Fires when any printer's status changes (made again when the list changes).
  Stream<void> get _fleet {
    final keys = _printers.map((p) => p.key).join(',');
    if (_fleetStream == null || keys != _fleetKeys) {
      _fleetKeys = keys;
      _fleetStream = StreamGroupLite.merge([for (final p in _printers) clientFor(p).stream]).asBroadcastStream();
    }
    return _fleetStream!;
  }

  List<String> _attention() => attentionItems([
        for (final p in _printers)
          (
            p.name,
            clientFor(p).status,
            settings.jsonList('maint.${p.key}'),
            clientFor(p).lastHistory == null ? null : clientFor(p).lastHistory!.$2.printTime / 3600,
            settings.jsonList('parts.${p.key}'),
          ),
      ], humidityLimit: settings.number('humidityLimit', 45));

  /// Side by side on wide screens (iPad landscape, a big Mac window), when on.
  Printer? _side;

  Widget _scaffold() {
    return LayoutBuilder(builder: (context, box) {
      final split = box.maxWidth >= 1100 && _printers.isNotEmpty && settings.flag('splitView', false);
      final list = _listScaffold(split);
      if (!split) return list;
      final sel = _printers.contains(_side) ? _side! : _printers.first;
      return Row(children: [
        SizedBox(width: 380, child: list),
        VerticalDivider(width: 1, color: C.border),
        Expanded(child: PrinterPage(key: ValueKey(sel.key), printer: sel)),
      ]);
    });
  }

  Widget _listScaffold(bool split) {
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
            StreamBuilder<void>(
              stream: _fleet,
              builder: (context, _) {
                final items = _attention();
                return IconButton(
                  tooltip: items.isEmpty ? 'Nothing needs you' : '${items.length} things need you',
                  icon: Badge(
                    isLabelVisible: items.isNotEmpty,
                    label: Text('${items.length}'),
                    child: const Icon(Icons.notifications_none_rounded),
                  ),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    builder: (ctx) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true, children: [
                      Text('Needs you', style: T.title),
                      if (items.isEmpty) const Hint('All good: nothing paused, failed, offline, damp or due.'),
                      for (final i in items)
                        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.chevron_right_rounded), title: Text(i)),
                    ]),
                  ),
                );
              },
            ),
          if (_printers.length > 1)
            IconButton(
              tooltip: 'All printers: stats',
              icon: const Icon(Icons.insights_rounded),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FleetPage(printers: _printers))),
            ),
          if (_printers.isNotEmpty)
            IconButton(
              tooltip: 'Wall view',
              icon: const Icon(Icons.grid_view_rounded),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => WallPage(printers: _printers))),
            ),
          if (_printers.length > 1)
            PopupMenuButton<String>(
              tooltip: 'All printers',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) async {
                final cs = [for (final p in _printers) clientFor(p)];
                if (v == 'lights') {
                  await run(context, () async {
                    for (final c in cs.where((c) => c.status.online && c.status.led == true)) {
                      await c.setLed(false);
                    }
                  }, done: 'Lights off');
                } else if (v == 'pause') {
                  final busy = cs.where((c) => c.status.online && c.status.state == 'printing').toList();
                  if (busy.isEmpty) return toast(context, 'Nothing is printing');
                  if (!await confirm(context, 'Pause ${busy.length} print${busy.length == 1 ? '' : 's'}?',
                          message: 'Each printer pauses where it is. Resume them from their screens.', action: 'Pause all') ||
                      !mounted) {
                    return;
                  }
                  await run(context, () async {
                    for (final c in busy) {
                      await c.pause();
                    }
                  }, done: 'Paused');
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'lights', child: Text('Turn every light off')),
                PopupMenuItem(value: 'pause', child: Text('Pause every print…')),
              ],
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
                child: StreamBuilder<void>(
                  // Rebuild the summary line as printers change state.
                  stream: _fleet,
                  builder: (context, _) {
                    final hideOff = settings.flag('hideOffline', false);
                    final problemsFirst = settings.flag('listSort', false);
                    final shown = [
                      for (final p in _printers)
                        if (!hideOff || clientFor(p).status.online) p,
                    ];
                    if (problemsFirst) {
                      final idx = {for (final (i, p) in shown.indexed) p: i};
                      shown.sort((a, b) {
                        int rank(Printer p) {
                          final s = clientFor(p).status;
                          return !s.online || s.state == 'error' || s.state == 'paused' ? 0 : s.state == 'printing' ? 1 : 2;
                        }
                        final r = rank(a).compareTo(rank(b));
                        return r != 0 ? r : idx[a]!.compareTo(idx[b]!);
                      });
                    }
                    final next = nextDone([for (final p in _printers) (p.name, clientFor(p).status)]);
                    return Column(children: [
                      if (_away.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Row(children: [
                            Expanded(child: Hint(_away)),
                            IconButton(
                              tooltip: 'Dismiss',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => setState(() => _away = ''),
                            ),
                          ]),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                        child: Row(children: [
                          Expanded(
                            child: Text(
                                [
                                  fleetSummary([for (final p in _printers) clientFor(p).status]),
                                  if (next != null)
                                    'next done ${fmtTime(DateTime.now().add(Duration(seconds: next.$2.round())))} (${next.$1})',
                                ].where((x) => x.isNotEmpty).join(' · '),
                                style: T.small.copyWith(color: C.muted)),
                          ),
                          IconButton(
                            tooltip: problemsFirst ? 'Sorted: problems first' : 'Your order',
                            icon: Icon(Icons.sort_rounded, size: 20, color: problemsFirst ? C.accent : null),
                            onPressed: () => setState(() => settings.setFlag('listSort', !problemsFirst)),
                          ),
                          IconButton(
                            tooltip: hideOff ? 'Show offline printers' : 'Hide offline printers',
                            icon: Icon(hideOff ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                            onPressed: () => setState(() => settings.setFlag('hideOffline', !hideOff)),
                          ),
                        ]),
                      ),
                      Expanded(
                        child: ReorderableListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                          buildDefaultDragHandles: false,
                          itemCount: shown.length,
                          onReorderItem: (a, b) {
                            final from = _printers.indexOf(shown[a]), to = _printers.indexOf(shown[b]);
                            setState(() => _printers.insert(to, _printers.removeAt(from)));
                            _save();
                          },
                          itemBuilder: (_, i) {
                            final p = shown[i];
                            // Drag the handle to reorder (long-press the card opens quick actions).
                            return Stack(
                              key: ValueKey(p.key),
                              children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Reveal(index: i, child: _PrinterCard(
                                  printer: p,
                                  onOpen: split
                                      ? () => setState(() => _side = p)
                                      : () => Navigator.push(context, MaterialPageRoute(builder: (_) => PrinterPage(printer: p))),
                                  onEdit: () => _edit(existing: p),
                                  onDelete: () => _delete(p),
                                  onDuplicate: () => _edit(
                                      prefill: Printer.fromJson({...p.toJson(), 'name': '${p.name} copy'})),
                                )),
                              ),
                              if (shown.length > 1)
                                Positioned(
                                  left: 2,
                                  top: 0,
                                  bottom: 12,
                                  child: ReorderableDragStartListener(
                                    index: i,
                                    child: Tooltip(
                                      message: 'Drag to reorder',
                                      child: Icon(Icons.drag_indicator_rounded, size: 18, color: C.muted.withValues(alpha: 0.6)),
                                    ),
                                  ),
                                ),
                            ]);
                          },
                        ),
                      ),
                    ]);
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
  final VoidCallback onOpen, onEdit, onDelete, onDuplicate;
  const _PrinterCard({
    required this.printer,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    required this.onDuplicate,
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
        return Semantics(
          label: '${printer.name}, ${s.online ? s.state : 'offline'}'
              '${active ? ', ${(s.progress * 100).round()} percent${eta == null ? '' : ', ${fmtDuration(eta)} left'}' : ''}',
          hint: 'Opens the printer. Long-press for quick actions.',
          child: Tile(
          radius: 20,
          onTap: onOpen,
          onLongPress: () => _quick(context, client, s),
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
                        ? '${(s.progress * 100).toStringAsFixed(0)}%'
                            '${s.currentLayer != null && (s.totalLayers ?? 0) > 0 ? ' · layer ${s.currentLayer}/${s.totalLayers}' : ''}'
                            ' · ${s.filename ?? ''}'
                        : '${printer.host}:${printer.port}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: C.muted, fontSize: 13),
                  ),
                  if (s.state == 'paused' && (s.message ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(s.message!, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.ink(C.warn))),
                    ),
                  if (settings.text('pinNote.${printer.key}') case final pin when pin.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('📌 $pin', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.ink(C.warn))),
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
                onSelected: (v) async {
                  switch (v) {
                    case 'edit':
                      onEdit();
                    case 'delete':
                      onDelete();
                    case 'copy':
                      Clipboard.setData(ClipboardData(text: '${printer.host}:${printer.port}'));
                      toast(context, 'Address copied');
                    case 'web':
                      // The printer's own web page (Mainsail, Fluidd or Creality's).
                      await launchUrl(Uri.parse('http://${printer.host}'), mode: LaunchMode.externalApplication);
                    case 'duplicate':
                      onDuplicate();
                    case 'link':
                      // For Shortcuts, Home Assistant or a note: opens this printer in the app.
                      Clipboard.setData(ClipboardData(text: 'printerhub://printer/${Uri.encodeComponent(printer.name)}'));
                      toast(context, 'App link copied');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                  PopupMenuItem(value: 'copy', child: Text('Copy address')),
                  PopupMenuItem(value: 'link', child: Text('Copy app link')),
                  PopupMenuItem(value: 'web', child: Text('Open its web page')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ]),
          ),
        ));
      },
    );
  }

  /// Long-press: the things you reach for most, without opening the printer.
  void _quick(BuildContext context, MoonrakerClient client, PrinterStatus s) => showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text(printer.name, style: T.title), subtitle: Text(fleetSummary([s]))),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(
                    builder: (_) => CameraFullscreen(client: client, cameraUrl: printer.cameraUrl, title: printer.name)));
              },
            ),
            if (s.led != null)
              ListTile(
                leading: Icon(s.led! ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded),
                title: Text(s.led! ? 'Light off' : 'Light on'),
                onTap: () {
                  Navigator.pop(ctx);
                  run(context, () => client.setLed(!s.led!));
                },
              ),
            if (s.state == 'printing')
              ListTile(
                leading: const Icon(Icons.pause_rounded),
                title: const Text('Pause'),
                onTap: () {
                  Navigator.pop(ctx);
                  run(context, client.pause);
                },
              ),
            if (s.state == 'paused')
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('Resume'),
                onTap: () {
                  Navigator.pop(ctx);
                  run(context, client.resume);
                },
              ),
            if (s.online && (s.state == 'complete' || s.state == 'cancelled') && (s.filename ?? '').isNotEmpty)
              ListTile(
                leading: const Icon(Icons.replay_rounded),
                title: Text('Print ${s.filename!.split('/').last} again'),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (await confirm(context, 'Print it again?', message: 'Make sure the plate is clear first.', action: 'Print') &&
                      context.mounted &&
                      await preflight(context) &&
                      context.mounted) {
                    run(context, () => client.startPrint(s.filename!), done: 'Print started');
                  }
                },
              ),
            if (s.online && s.state != 'printing' && s.state != 'paused' && (s.hotendTarget > 0 || s.bedTarget > 0))
              ListTile(
                leading: const Icon(Icons.ac_unit_rounded),
                title: const Text('Heaters off'),
                onTap: () {
                  Navigator.pop(ctx);
                  run(context, () => client.gcode('TURN_OFF_HEATERS'), done: 'Heaters off');
                },
              ),
            ListTile(
              leading: const Icon(Icons.handyman_outlined),
              title: const Text('Workshop'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => WorkshopPage(client: client, printer: printer)));
              },
            ),
          ]),
        ),
      );

  Widget _mini(IconData icon, Color color, double t, double target) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          '${Units.deg(t)}'
          '${target > 0 ? ' / ${Units.deg(target)}' : ''}',
          style: const TextStyle(fontSize: 13),
        ),
      ]);
}

class _DiscoverySheet extends StatefulWidget {
  final Set<String> known;
  final ValueChanged<FoundPrinter> onAdd;
  final ValueChanged<List<FoundPrinter>> onAddAll;
  const _DiscoverySheet({required this.known, required this.onAdd, required this.onAddAll});
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
    _start();
  }

  void _scan() {
    setState(() {
      _found.clear();
      _done = false;
      _progress = 0;
    });
    _start();
  }

  void _start() {
    discoverPrinters(onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    }).listen(
      (f) => mounted ? setState(() => _found.add(f)) : null,
      onDone: () => mounted ? setState(() => _done = true) : null,
      onError: (_) => mounted ? setState(() => _done = true) : null,
    );
  }

  List<FoundPrinter> get _new => [for (final f in _found) if (!widget.known.contains(f.host)) f];

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
            if (_done)
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(onPressed: _scan, icon: const Icon(Icons.refresh_rounded), label: const Text('Scan again')),
                if (_new.length > 1)
                  FilledButton.tonal(onPressed: () => widget.onAddAll(_new), child: Text('Add all ${_new.length}')),
              ]),
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
  /// A throwaway client for the address typed so far (not saved, not watched).
  MoonrakerClient _probe() => MoonrakerClient(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 7125,
      apiKey: _key.text.trim().isEmpty ? null : _key.text.trim());

  /// Asks Moonraker who it is, so a typo shows before you save.
  Future<void> _test() async {
    if (_host.text.trim().isEmpty) return toast(context, 'Type the printer\'s address first', error: true);
    try {
      final r = await http
          .get(Uri.parse('http://${_host.text.trim()}:${int.tryParse(_port.text.trim()) ?? 7125}/server/info'),
              headers: {if (_key.text.trim().isNotEmpty) 'X-Api-Key': _key.text.trim()})
          .timeout(const Duration(seconds: 5));
      final info = jsonDecode(r.body)['result'] as Map?;
      if (!mounted) return;
      if (r.statusCode != 200 || info == null) return toast(context, 'It answered, but not like Moonraker (HTTP ${r.statusCode})', error: true);
      toast(context, 'Found Moonraker ${info['moonraker_version'] ?? ''} · Klipper ${info['klippy_state'] ?? '?'}');
    } catch (e) {
      if (mounted) toast(context, 'No answer from ${_host.text.trim()}: $e', error: true);
    }
  }

  /// Fills the camera field from the printer's own webcam list.
  Future<void> _findCamera() async {
    if (_host.text.trim().isEmpty) return toast(context, 'Type the printer\'s address first', error: true);
    final cams = await _probe().webcams().catchError((_) => <String>[]);
    if (!mounted) return;
    if (cams.isEmpty) return toast(context, 'The printer lists no cameras. Leave the field empty to auto-detect.');
    final pick = cams.length == 1
        ? cams.first
        : await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(title: const Text('Which camera?'), children: [
              for (final c in cams) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c), child: Text(c)),
            ]),
          );
    if (pick != null && mounted) setState(() => _cam.text = pick);
  }

  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _host = TextEditingController(text: widget.initial?.host ?? '');
  late final _port = TextEditingController(text: '${widget.initial?.port ?? 7125}');
  late final _key = TextEditingController(text: widget.initial?.apiKey ?? '');
  late final _cam = TextEditingController(text: widget.initial?.cameraUrl ?? '');
  late final _relay = TextEditingController(text: widget.initial?.relayCode ?? '');
  late final _slicer = TextEditingController(text: widget.initial?.slicerUrl ?? '');
  late Connection _connection = widget.initial?.connection ?? Connection.auto;
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
    if (_slicer.text.trim().isNotEmpty && slicerBase(_slicer.text) == null) {
      setState(() => _error = 'Enter the slicer as address:port, e.g. 100.85.247.10:7070');
      return;
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
        connection: _connection,
        slicerUrl: opt(_slicer),
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: DropdownButtonFormField<Connection>(
                initialValue: _connection,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Connection'),
                items: [
                  for (final c in Connection.values)
                    DropdownMenuItem(value: c, child: Text(c.label, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (c) => setState(() => _connection = c ?? Connection.auto),
              ),
            ),
            _field(_slicer, 'Slicer address (optional)',
                hint: 'e.g. 100.85.247.10:7070, to slice without the relay'),
            if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
          ]),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _test,
          icon: const Icon(Icons.network_check_rounded, size: 18),
          label: const Text('Test'),
        ),
        TextButton.icon(
          onPressed: _findCamera,
          icon: const Icon(Icons.videocam_outlined, size: 18),
          label: const Text('Find camera'),
        ),
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

/// Merges broadcast streams into one that fires when any of them does.
class StreamGroupLite {
  static Stream<void> merge(List<Stream<Object?>> streams) {
    late StreamController<void> c;
    final subs = <StreamSubscription<Object?>>[];
    c = StreamController<void>(
      onListen: () {
        for (final s in streams) {
          subs.add(s.listen((_) => c.add(null)));
        }
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return c.stream;
  }
}
