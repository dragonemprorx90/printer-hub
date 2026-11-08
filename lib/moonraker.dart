import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay.dart';

/// A saved printer. Persisted as JSON in shared_preferences.
class Printer {
  final String name, host;
  final int port;
  final String? apiKey, cameraUrl;

  /// Pairing code from the home bridge ("PHB1:…"), for access from anywhere.
  final String? relayCode;

  const Printer({
    required this.name,
    required this.host,
    this.port = 7125,
    this.apiKey,
    this.cameraUrl,
    this.relayCode,
  });

  String get key => '$host:$port';

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'port': port,
        'apiKey': apiKey,
        'cameraUrl': cameraUrl,
        'relayCode': relayCode,
      };

  factory Printer.fromJson(Map<String, dynamic> j) => Printer(
        name: j['name'],
        host: j['host'],
        port: j['port'] ?? 7125,
        apiKey: j['apiKey'],
        cameraUrl: j['cameraUrl'],
        relayCode: j['relayCode'],
      );
}

/// ponytail: one long-lived client per printer, shared by the printer list
/// and the printer screen. Fine for a handful of printers on a LAN.
final _clients = <String, MoonrakerClient>{};

MoonrakerClient clientFor(Printer p) => _clients.putIfAbsent(
      p.key,
      () => MoonrakerClient(
          host: p.host, port: p.port, apiKey: p.apiKey, relayCode: p.relayCode)
        ..connect(),
    );

void dropClient(Printer p) => _clients.remove(p.key)?.dispose();

class MoonrakerError implements Exception {
  final String message;
  MoonrakerError(this.message);
  @override
  String toString() => message;
}

/// One filament slot in a Creality CFS box.
class CfsSlot {
  final String label; // e.g. "1A"
  final int? color; // ARGB, null when the slot is empty
  final String material; // raw Creality material code
  final double? remain; // only RFID spools report this
  CfsSlot(this.label, this.color, this.material, [this.remain]);
  bool get empty => color == null;
}

class CfsBox {
  final String name;
  final double? temperature, humidity;
  final List<CfsSlot> slots;
  CfsBox(this.name, this.temperature, this.humidity, this.slots);
}

/// CFS reports colours as "0RRGGBB"; "-1" means no filament.
int? parseCfsColor(dynamic v) {
  final s = '$v';
  if (s == '-1' || s.length < 6) return null;
  final n = int.tryParse(s.substring(s.length - 6), radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

double? _num(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

class FanInfo {
  final String object; // "fan", "output_pin fanN", "fan_generic X" or the filter pin
  final String label;
  final double value; // 0..1
  FanInfo(this.object, this.label, this.value);
}

/// An object in the current print (Klipper exclude_object).
class PrintObject {
  final String name;
  final List<(double, double)> polygon;
  final (double, double)? center;
  PrintObject(this.name, this.polygon, this.center);
}

class QueuedJob {
  final String id, filename;
  QueuedJob(this.id, this.filename);
}

class PowerDevice {
  final String name;
  final bool on;
  PowerDevice(this.name, this.on);
}

(double, double) _pt(dynamic p) =>
    ((p[0] as num).toDouble(), (p[1] as num).toDouble());

/// Material of a past job: slicer metadata first, else the filename
/// ("Body1_PLA_1h28m.gcode" → PLA).
String? jobMaterial(Map j) {
  final meta = j['metadata'];
  final m = meta is Map ? meta['filament_type'] : null;
  if (m != null && '$m'.trim().isNotEmpty) return '$m'.split(';').first.trim();
  final r = RegExp(r'(?:^|[_\-\s])(PLA|PETG|ABS|ASA|TPU|PA|PC|PVA|HIPS|PET)(?=[_\-+.\s]|$)',
          caseSensitive: false)
      .firstMatch('${j['filename'] ?? ''}');
  return r?.group(1)?.toUpperCase();
}

/// Live snapshot of one printer, built from Moonraker status deltas.
class PrinterStatus {
  final raw = <String, Map<String, dynamic>>{};
  bool online = false;

  /// K2 chamber heater, or a DragonBreath heater added to Klipper (U1).
  static const chamberHeaters = ['heater_generic chamber_heater', 'heater_generic dragonbreath'];
  static const chamberSensors = ['temperature_sensor chamber_temp', 'temperature_sensor cavity'];
  String _first(List<String> keys) =>
      keys.firstWhere(raw.containsKey, orElse: () => keys.first);
  String get chamberHeater => _first(chamberHeaters);
  String get chamberSensor => _first(chamberSensors);
  static const dragonFilter = 'output_pin dragonbreath_filter';
  static const _fanLabels = {
    'fan0': 'Part cooling',
    'cavity_fan': 'Cavity',
    'exhaust_fan': 'Exhaust',
    'circulation_fan': 'Circulation',
    'e1_fan': 'Part cooling T1',
    'e2_fan': 'Part cooling T2',
    'e3_fan': 'Part cooling T3',
    'fan1': 'Auxiliary',
    'fan2': 'Chamber exhaust',
  };

  /// Merge a status delta (only changed fields are present).
  void applyDelta(Map<String, dynamic> status) {
    status.forEach((k, v) {
      if (v is Map) (raw[k] ??= {}).addAll(Map<String, dynamic>.from(v));
    });
  }

  dynamic _f(String o, String f) => raw[o]?[f];
  double _d(String o, String f) => (_f(o, f) as num?)?.toDouble() ?? 0;

  String get state => (_f('print_stats', 'state') ?? 'standby').toString();
  String? get message {
    final m = _f('display_status', 'message') ?? _f('print_stats', 'message');
    return (m == null || m == '') ? null : '$m';
  }

  double get hotend => _d('extruder', 'temperature');
  double get hotendTarget => _d('extruder', 'target');
  double get bed => _d('heater_bed', 'temperature');
  double get bedTarget => _d('heater_bed', 'target');

  bool get hasChamber =>
      raw.containsKey(chamberHeater) || raw.containsKey(chamberSensor);
  bool get chamberHeatable => raw.containsKey(chamberHeater);
  double get chamber => raw.containsKey(chamberHeater)
      ? _d(chamberHeater, 'temperature')
      : _d(chamberSensor, 'temperature');
  double get chamberTarget => _d(chamberHeater, 'target');

  double get progress {
    final v = _f('virtual_sdcard', 'progress') ?? _f('display_status', 'progress');
    return (v as num?)?.toDouble() ?? 0;
  }

  String? get filename {
    final f = _f('print_stats', 'filename');
    return (f == null || f == '') ? null : '$f';
  }

  double get printDuration => _d('print_stats', 'print_duration');
  double get filamentUsed => _d('print_stats', 'filament_used');
  int? get currentLayer =>
      ((_f('print_stats', 'info') as Map?)?['current_layer'] as num?)?.toInt();
  int? get totalLayers =>
      ((_f('print_stats', 'info') as Map?)?['total_layer'] as num?)?.toInt();

  /// Seconds left, extrapolated from progress. Null until there's signal.
  double? get eta => progress > 0.005 && printDuration > 0
      ? printDuration / progress - printDuration
      : null;

  double get speedFactor =>
      (_f('gcode_move', 'speed_factor') as num?)?.toDouble() ?? 1;
  double get flowFactor =>
      (_f('gcode_move', 'extrude_factor') as num?)?.toDouble() ?? 1;
  String get homedAxes => '${_f('toolhead', 'homed_axes') ?? ''}';
  List<double> get position =>
      ((_f('gcode_move', 'gcode_position') as List?) ?? const [])
          .map((e) => (e as num).toDouble())
          .toList();

  /// "extruder", "extruder1", ... (more than one on multi-tool printers).
  List<String> get extruders =>
      raw.keys.where((k) => RegExp(r'^extruder\d*$').hasMatch(k)).toList()
        ..sort();
  double toolTemp(String e) => _d(e, 'temperature');
  double toolTarget(String e) => _d(e, 'target');
  String get activeExtruder => '${_f('toolhead', 'extruder') ?? 'extruder'}';
  double get pressureAdvance => _d(activeExtruder, 'pressure_advance');

  double get zOffset {
    final h = _f('gcode_move', 'homing_origin') as List?;
    return h != null && h.length > 2 ? (h[2] as num).toDouble() : 0;
  }

  List<double> get axisMax =>
      ((_f('toolhead', 'axis_maximum') as List?) ?? const [300, 300, 300])
          .map((e) => (e as num).toDouble())
          .toList();

  List<List<double>> get mesh => [
        for (final row in (_f('bed_mesh', 'probed_matrix') as List?) ?? const [])
          [for (final v in row as List) (v as num).toDouble()],
      ]..removeWhere((r) => r.isEmpty);
  String get meshProfile => '${_f('bed_mesh', 'profile_name') ?? ''}';

  List<PrintObject> get objects => [
        for (final o in (_f('exclude_object', 'objects') as List?) ?? const [])
          PrintObject(
            '${o['name']}',
            [for (final p in (o['polygon'] as List?) ?? const []) _pt(p)],
            o['center'] is List ? _pt(o['center']) : null,
          ),
      ];
  Set<String> get excludedObjects => {
        for (final e
            in (_f('exclude_object', 'excluded_objects') as List?) ?? const [])
          '$e',
      };
  String? get currentObject {
    final c = _f('exclude_object', 'current_object');
    return c == null ? null : '$c';
  }

  List<FanInfo> get fans {
    final out = <FanInfo>[];
    if (raw['fan'] != null) {
      out.add(FanInfo('fan', 'Part cooling', _d('fan', 'speed')));
    }
    final pins = raw.keys.where((k) => k.startsWith('output_pin fan')).toList()
      ..sort();
    for (final k in pins) {
      final pin = k.substring('output_pin '.length);
      out.add(FanInfo(k, _fanLabels[pin] ?? pin, _d(k, 'value')));
    }
    final generic = raw.keys.where((k) => k.startsWith('fan_generic ')).toList()
      ..sort();
    for (final k in generic) {
      final name = k.substring('fan_generic '.length);
      out.add(FanInfo(k, _fanLabels[name] ?? name, _d(k, 'speed')));
    }
    if (raw.containsKey(dragonFilter)) {
      out.add(FanInfo(dragonFilter, 'Heater filter', _d(dragonFilter, 'value')));
    }
    return out;
  }

  /// Klipper `[led]` the U1 uses for its cavity light (white channel).
  static const cavityLed = 'led cavity_led';

  bool? get led {
    final v = _f('output_pin LED', 'value');
    if (v != null) return (v as num) > 0;
    final c = _f(cavityLed, 'color_data') as List?;
    if (c == null || c.isEmpty) return null;
    return (c.first as List).any((x) => (x as num) > 0);
  }

  /// Creality Filament System boxes that are connected.
  List<CfsBox> get cfs {
    final b = raw['box'];
    if (b == null) return const [];
    final out = <CfsBox>[];
    for (var i = 1; i <= 4; i++) {
      final t = b['T$i'];
      if (t is! Map || t['state'] != 'connect') continue;
      final colors = (t['color_value'] as List?) ?? const [];
      final mats = (t['material_type'] as List?) ?? const [];
      final rem = (t['remain_len'] as List?) ?? const [];
      double? left(int s) {
        final v = s < rem.length ? _num(rem[s]) : null;
        return v != null && v > 0 ? v : null;
      }

      out.add(CfsBox('CFS $i', _num(t['temperature']),
          _num(t['dry_and_humidity']), [
        for (var s = 0; s < colors.length; s++)
          CfsSlot('$i${String.fromCharCode(65 + s)}', parseCfsColor(colors[s]),
              s < mats.length ? '${mats[s]}' : '', left(s)),
      ]));
    }
    return out;
  }
}

enum ConsoleKind { sent, response, error }

class ConsoleLine {
  final String text;
  final ConsoleKind kind;
  final DateTime time;
  ConsoleLine(this.text, this.kind, [DateTime? t]) : time = t ?? DateTime.now();
}

class GcodeFile {
  final String path;
  final int size;
  final DateTime modified;
  GcodeFile(this.path, this.size, this.modified);
  String get name => path.split('/').last;
  String get dir =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

class PrintJob {
  final String filename, status;
  final DateTime start;
  final double duration, filament;
  final bool exists;
  final String? material;
  PrintJob(this.filename, this.status, this.start, this.duration, this.filament,
      this.exists,
      {this.material});
}

class HistoryTotals {
  final int jobs;
  final double printTime, filament, longest;
  HistoryTotals(this.jobs, this.printTime, this.filament, this.longest);
}

/// Moonraker client: JSON-RPC over WebSocket for live state and control,
/// HTTP for files and history. Works for any Klipper/Moonraker printer
/// (Creality K-series, Snapmaker U1, Voron, ...).
class MoonrakerClient {
  final String host;
  final int port;
  final String? apiKey;

  WebSocketChannel? _ch;
  int _id = 0, _gen = 0;
  final _pending = <int, Completer<dynamic>>{};
  Timer? _reconnect, _resub;
  bool _closed = false;

  final status = PrinterStatus();
  final _statusCtrl = StreamController<PrinterStatus>.broadcast();
  Stream<PrinterStatus> get stream => _statusCtrl.stream;

  List<String> macros = const [];

  /// Every G-code command the printer accepts (upper case).
  Set<String> commands = const {};

  /// A print waiting to start at a set time (kept while the app runs).
  (String, DateTime)? scheduled;
  Timer? _schedTimer;

  final console = <ConsoleLine>[];
  final _consoleCtrl = StreamController<List<ConsoleLine>>.broadcast();
  Stream<List<ConsoleLine>> get consoleStream => _consoleCtrl.stream;

  static const _wanted = {
    'print_stats',
    'heater_bed',
    'extruder',
    'display_status',
    'virtual_sdcard',
    'toolhead',
    'gcode_move',
    'fan',
    'box',
    'bed_mesh',
    'exclude_object',
    'output_pin LED',
    PrinterStatus.cavityLed,
    ...PrinterStatus.chamberHeaters,
    ...PrinterStatus.chamberSensors,
    PrinterStatus.dragonFilter,
  };

  /// Set when the printer was paired with a home bridge.
  final PairInfo? relay;
  RelayLink? _link;
  void Function(String)? _sendRaw;
  http.Client _http = http.Client();
  Timer? _homeCheck;
  int _failures = 0;

  /// True while connected through the home bridge instead of the LAN.
  bool viaRelay = false;

  /// Why the last connection attempt failed, for the UI.
  String? linkError;

  MoonrakerClient(
      {required this.host, this.port = 7125, this.apiKey, String? relayCode})
      : relay = _pairOrNull(relayCode);

  static PairInfo? _pairOrNull(String? code) {
    if (code == null || code.trim().isEmpty) return null;
    try {
      return PairInfo.decode(code);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> get authHeaders =>
      apiKey != null ? {'X-Api-Key': apiKey!} : const {};

  Uri _uri(List<String> segments, [Map<String, String>? query]) => Uri(
        scheme: 'http',
        host: host,
        port: port,
        pathSegments: segments,
        queryParameters: query,
      );

  // --- Connection -----------------------------------------------------------

  void connect() {
    _closed = false;
    _open();
  }

  void _open() => _openAsync();

  /// Direct on the LAN when the printer answers there; otherwise (when
  /// paired) through the home bridge. While remote, checks once a minute
  /// whether we're home again and switches back.
  Future<void> _openAsync() async {
    final gen = ++_gen;
    _closeTransport();
    try {
      if (relay != null && !await _lanReachable()) {
        final link = await RelayLink.connect(relay!);
        if (gen != _gen || _closed) {
          link.close();
          return;
        }
        _link = link;
        viaRelay = true;
        _http = RelayHttpClient(link);
        _sendRaw = link.sendMoonraker;
        link.moonraker.listen(_onMessage);
        link.done.then((why) {
          if (gen != _gen) return;
          linkError = why;
          _scheduleReconnect();
        });
        _homeCheck = Timer.periodic(const Duration(minutes: 1), (_) async {
          if (gen == _gen && await _lanReachable()) _open();
        });
      } else {
        viaRelay = false;
        _http = http.Client();
        final q = apiKey != null ? '?token=$apiKey' : '';
        final ch = WebSocketChannel.connect(Uri.parse('ws://$host:$port/websocket$q'));
        _ch = ch;
        _sendRaw = ch.sink.add;
        ch.stream.listen(
          _onMessage,
          onDone: () => gen == _gen ? _scheduleReconnect() : null,
          onError: (_) => gen == _gen ? _scheduleReconnect() : null,
          cancelOnError: true,
        );
      }
      _subscribe();
    } catch (e) {
      linkError = '$e';
      if (gen == _gen) _scheduleReconnect();
    }
  }

  Future<bool> _lanReachable() async {
    try {
      final r = await http
          .get(Uri.parse('http://$host:$port/server/info'), headers: authHeaders)
          .timeout(const Duration(milliseconds: 1500));
      return r.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  void _closeTransport() {
    _homeCheck?.cancel();
    _homeCheck = null;
    _ch?.sink.close();
    _ch = null;
    _link?.close();
    _link = null;
    _sendRaw = null;
  }

  void _scheduleReconnect() {
    status.online = false;
    _emit();
    for (final c in _pending.values) {
      c.completeError(MoonrakerError('Disconnected from printer'));
    }
    _pending.clear();
    if (_closed) return;
    _reconnect?.cancel();
    // Quick retries first, then every 15 s so an offline bridge doesn't
    // burn through the relay's free-plan request allowance.
    _failures++;
    _reconnect = Timer(Duration(seconds: _failures <= 3 ? 3 : 15), _open);
  }

  Future<dynamic> _call(String method,
      [Map<String, dynamic>? params,
      Duration timeout = const Duration(seconds: 10)]) {
    final send = _sendRaw;
    if (send == null) return Future.error(MoonrakerError('Not connected'));
    final id = ++_id;
    final c = Completer<dynamic>();
    _pending[id] = c;
    send(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'id': id,
      'params': ?params,
    }));
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw MoonrakerError('$method timed out');
    });
  }

  Future<void> _subscribe() async {
    _resub?.cancel();
    try {
      final list = await _call('printer.objects.list');
      final objs = List<String>.from(list['objects'] as List);
      hasScreen = objs.contains('machine_state_manager'); // Snapmaker U1
      macros = objs
          .where((o) => o.startsWith('gcode_macro '))
          .map((o) => o.substring('gcode_macro '.length))
          .where((m) => !m.startsWith('_'))
          .toList()
        ..sort();
      _loadCommands();
      final sub = <String, dynamic>{
        for (final o in objs)
          if (_wanted.contains(o) ||
              o.startsWith('output_pin fan') ||
              o.startsWith('fan_generic ') ||
              RegExp(r'^extruder\d+$').hasMatch(o))
            o: null,
      };
      final res = await _call('printer.objects.subscribe', {'objects': sub});
      status.raw.clear();
      status.online = true;
      _failures = 0;
      linkError = null;
      if (res is Map && res['status'] is Map) {
        status.applyDelta(Map<String, dynamic>.from(res['status']));
      }
      _emit();
      _loadConsole();
    } catch (_) {
      // Klipper may still be starting. Moonraker also sends
      // notify_klippy_ready, but retry in case that was missed.
      status.online = false;
      _emit();
      if (!_closed) _resub = Timer(const Duration(seconds: 5), _subscribe);
    }
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String);
    if (msg is! Map) return;
    final id = msg['id'];
    if (id != null && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      final err = msg['error'];
      if (err != null) {
        c.completeError(MoonrakerError('${err['message'] ?? 'Request failed'}'));
      } else {
        c.complete(msg['result']);
      }
      return;
    }
    final params = msg['params'];
    switch (msg['method']) {
      case 'notify_status_update':
        if (params is List && params.isNotEmpty && params[0] is Map) {
          status.applyDelta(Map<String, dynamic>.from(params[0]));
          _emit();
        }
      case 'notify_gcode_response':
        if (params is List && params.isNotEmpty) {
          final t = '${params[0]}';
          _addConsole(ConsoleLine(
              t, t.startsWith('!!') ? ConsoleKind.error : ConsoleKind.response));
        }
      case 'notify_klippy_ready':
        _subscribe();
      case 'notify_klippy_shutdown' || 'notify_klippy_disconnected':
        status.online = false;
        _emit();
    }
  }

  void _emit() {
    if (!_statusCtrl.isClosed) _statusCtrl.add(status);
  }

  // --- Console --------------------------------------------------------------

  Future<void> _loadConsole() async {
    try {
      final res = await _call('server.gcode_store', {'count': 150});
      final items = (res['gcode_store'] as List?) ?? const [];
      console
        ..clear()
        ..addAll([
          for (final e in items)
            ConsoleLine(
              '${e['message']}',
              e['type'] == 'command'
                  ? ConsoleKind.sent
                  : '${e['message']}'.startsWith('!!')
                      ? ConsoleKind.error
                      : ConsoleKind.response,
              DateTime.fromMillisecondsSinceEpoch(
                  (((e['time'] as num?) ?? 0) * 1000).round()),
            ),
        ]);
      _consoleCtrl.add(console);
    } catch (_) {}
  }

  void _addConsole(ConsoleLine line) {
    console.add(line);
    // ponytail: keep the last 500 lines; older output is in Moonraker's store.
    if (console.length > 500) console.removeRange(0, console.length - 500);
    if (!_consoleCtrl.isClosed) _consoleCtrl.add(console);
  }

  // --- Controls -------------------------------------------------------------

  /// Runs G-code and echoes it to the console. Long moves (homing, probing)
  /// can take minutes, hence the long timeout.
  Future<void> gcode(String script) async {
    _addConsole(ConsoleLine(script, ConsoleKind.sent));
    try {
      await _call('printer.gcode.script', {'script': script},
          const Duration(minutes: 10));
    } catch (e) {
      _addConsole(ConsoleLine('!! $e', ConsoleKind.error));
      rethrow;
    }
  }

  Future<void> pause() => _call('printer.print.pause');
  Future<void> resume() => _call('printer.print.resume');
  Future<void> cancel() => _call('printer.print.cancel');
  Future<void> emergencyStop() => _call('printer.emergency_stop');
  Future<void> firmwareRestart() => _call('printer.firmware_restart');
  Future<void> restartKlipper() => _call('printer.restart');
  Future<void> startPrint(String filename) =>
      _call('printer.print.start', {'filename': filename});

  Future<void> home([String axes = '']) => gcode('G28 $axes'.trim());
  Future<void> jog(String axis, double mm) {
    final feed = axis == 'Z' ? 600 : 6000;
    return gcode('G91\nG1 $axis$mm F$feed\nG90');
  }

  Future<void> extrude(double mm) => gcode('M83\nG1 E$mm F300');
  Future<void> setHotend(int t) => gcode('M104 S$t');
  Future<void> setBed(int t) => gcode('M140 S$t');
  Future<void> setChamber(int t) => gcode(
      'SET_HEATER_TEMPERATURE HEATER=${status.chamberHeater.split(' ').last} TARGET=$t');
  Future<void> setSpeed(int pct) => gcode('M220 S$pct');
  Future<void> setFlow(int pct) => gcode('M221 S$pct');
  Future<void> setLed(bool on) => gcode(status.raw.containsKey(PrinterStatus.cavityLed)
      ? 'SET_LED LED=cavity_led WHITE=${on ? 1 : 0}'
      : 'SET_PIN PIN=LED VALUE=${on ? 1 : 0}');

  /// Creality wires its fans as `output_pin fanN` behind an `M106 P<n>` macro;
  /// stock Klipper has a single [fan].
  Future<void> setFan(FanInfo fan, double fraction) {
    final s = (fraction * 255).round();
    if (fan.object == 'fan') return gcode('M106 S$s');
    if (fan.object.startsWith('fan_generic ')) {
      final name = fan.object.substring('fan_generic '.length);
      return gcode('SET_FAN_SPEED FAN=$name SPEED=${fraction.toStringAsFixed(2)}');
    }
    // ponytail: the DragonBreath filter pin is on/off only.
    if (fan.object == PrinterStatus.dragonFilter) {
      return gcode('SET_PIN PIN=dragonbreath_filter VALUE=${fraction > 0 ? 1 : 0}');
    }
    final n = fan.object.substring('output_pin fan'.length);
    return gcode('M106 P$n S$s');
  }

  // --- Files ----------------------------------------------------------------

  void _check(http.Response r) {
    if (r.statusCode >= 300) {
      throw MoonrakerError('HTTP ${r.statusCode} from printer');
    }
  }

  Future<List<GcodeFile>> listFiles() async {
    final r = await _http
        .get(_uri(['server', 'files', 'list'], {'root': 'gcodes'}),
            headers: authHeaders)
        .timeout(const Duration(seconds: 15));
    _check(r);
    final items = (jsonDecode(r.body)['result'] as List?) ?? const [];
    // Slicers unpack 3MF plates into hidden dot-folders; skip those.
    final files = [
      for (final e in items)
        if (!'${e['path']}'.startsWith('.') && !'${e['path']}'.contains('/.'))
          GcodeFile(
            '${e['path']}',
            (e['size'] as num?)?.toInt() ?? 0,
            DateTime.fromMillisecondsSinceEpoch(
                (((e['modified'] as num?) ?? 0) * 1000).round()),
          ),
    ]..sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  Future<Map<String, dynamic>> metadata(String path) async {
    final r = await _http.get(
        _uri(['server', 'files', 'metadata'], {'filename': path}),
        headers: authHeaders);
    if (r.statusCode >= 300) return const {};
    return Map<String, dynamic>.from(jsonDecode(r.body)['result'] ?? const {});
  }

  String thumbnailUrl(String filePath, String relative) {
    final dir = filePath.contains('/')
        ? filePath.substring(0, filePath.lastIndexOf('/') + 1)
        : '';
    return _uri(['server', 'files', 'gcodes', ...'$dir$relative'.split('/')])
        .toString();
  }

  Future<void> deleteFile(String path) async {
    _check(await _http.delete(
        _uri(['server', 'files', 'gcodes', ...path.split('/')]),
        headers: authHeaders));
  }

  Future<void> upload(String name, Uint8List bytes, {String folder = ''}) async {
    final req = http.MultipartRequest('POST', _uri(['server', 'files', 'upload']))
      ..headers.addAll(authHeaders)
      ..fields['root'] = 'gcodes'
      ..fields['path'] = folder
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    final res = await _http.send(req);
    if (res.statusCode >= 300) {
      throw MoonrakerError('Upload failed (HTTP ${res.statusCode})');
    }
  }

  /// One home camera frame (JPEG) through the bridge, while away.
  Future<Uint8List> relayFrame() async {
    final link = _link;
    if (link == null) throw MoonrakerError('Not connected through the home bridge');
    final res = await link.cameraFrame();
    final body = await res.stream.toBytes();
    if (res.statusCode != 200) {
      throw MoonrakerError(utf8.decode(body, allowMalformed: true));
    }
    return body;
  }

  /// Snapmaker U1: the extended firmware can mirror its touchscreen at /screen/.
  bool hasScreen = false;

  Uri _screen(String p, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: host, port: 80, path: '/screen/$p', queryParameters: q);

  Future<Uint8List> screenFrame() async {
    final r = await _http.get(_screen('snapshot'), headers: authHeaders);
    if (r.statusCode != 200 || !(r.headers['content-type'] ?? '').startsWith('image/')) {
      throw MoonrakerError(viaRelay && r.statusCode == 400
          ? 'Update the home bridge to see the screen from away.'
          : 'Remote screen is off. Turn on Remote Screen in the printer\'s firmware-config (Web).');
    }
    return r.bodyBytes;
  }

  Future<void> screenTouch(String action, int x, int y) async {
    await _http.post(_screen('touch', {'a': action, 'x': '$x', 'y': '$y'}),
        headers: authHeaders);
  }

  /// Camera stream URLs registered in Moonraker (standard Klipper setups).
  Future<List<String>> webcams() async {
    final r = await _http.get(_uri(['server', 'webcams', 'list']),
        headers: authHeaders);
    if (r.statusCode >= 300) return const [];
    final cams = (jsonDecode(r.body)['result']?['webcams'] as List?) ?? const [];
    return [
      for (final w in cams)
        if (w['enabled'] != false && '${w['stream_url'] ?? ''}'.isNotEmpty)
          '${w['stream_url']}'.startsWith('http')
              ? '${w['stream_url']}'
              : 'http://$host${w['stream_url']}',
    ];
  }

  // --- History --------------------------------------------------------------

  Future<List<PrintJob>> history({int start = 0, int limit = 40}) async {
    final r = await _http.get(
        _uri(['server', 'history', 'list'],
            {'start': '$start', 'limit': '$limit', 'order': 'desc'}),
        headers: authHeaders);
    _check(r);
    final jobs = (jsonDecode(r.body)['result']?['jobs'] as List?) ?? const [];
    return [
      for (final j in jobs)
        PrintJob(
          '${j['filename']}',
          '${j['status']}',
          DateTime.fromMillisecondsSinceEpoch(
              (((j['start_time'] as num?) ?? 0) * 1000).round()),
          ((j['print_duration'] as num?) ?? (j['total_duration'] as num?) ?? 0)
              .toDouble(),
          ((j['filament_used'] as num?) ?? 0).toDouble(),
          j['exists'] == true,
          material: jobMaterial(j as Map),
        ),
    ];
  }

  /// Every job, newest first.
  Future<List<PrintJob>> allHistory() async {
    final all = <PrintJob>[];
    while (true) {
      final page = await history(start: all.length, limit: 100);
      all.addAll(page);
      if (page.length < 100) return all;
    }
  }

  Future<HistoryTotals> historyTotals() async {
    final r = await _http.get(_uri(['server', 'history', 'totals']),
        headers: authHeaders);
    _check(r);
    final t = jsonDecode(r.body)['result']?['job_totals'] ?? const {};
    double d(String k) => ((t[k] as num?) ?? 0).toDouble();
    return HistoryTotals(((t['total_jobs'] as num?) ?? 0).toInt(),
        d('total_print_time'), d('total_filament_used'), d('longest_job'));
  }

  // --- Commands, tuning -----------------------------------------------------

  Future<void> _loadCommands() async {
    try {
      final r = await _http.get(_uri(['printer', 'gcode', 'help']),
          headers: authHeaders);
      final res = jsonDecode(r.body)['result'];
      if (res is Map) commands = {for (final k in res.keys) '$k'.toUpperCase()};
    } catch (_) {}
  }

  /// Whether the printer knows a command or macro.
  bool has(String command) {
    final c = command.toUpperCase();
    return commands.contains(c) || macros.any((m) => m.toUpperCase() == c);
  }

  Future<void> setToolTemp(String extruder, int t) => extruder == 'extruder'
      ? setHotend(t)
      : gcode('SET_HEATER_TEMPERATURE HEATER=$extruder TARGET=$t');
  Future<void> adjustZOffset(double mm) =>
      gcode('SET_GCODE_OFFSET Z_ADJUST=${mm.toStringAsFixed(3)} MOVE=1');
  Future<void> setPressureAdvance(double v) =>
      gcode('SET_PRESSURE_ADVANCE ADVANCE=${v.toStringAsFixed(4)}');
  Future<void> excludeObject(String name) =>
      gcode('EXCLUDE_OBJECT NAME=$name');

  void schedulePrint(String file, DateTime at) {
    _schedTimer?.cancel();
    scheduled = (file, at);
    _schedTimer = Timer(at.difference(DateTime.now()), () {
      scheduled = null;
      startPrint(file).catchError((_) {});
      _emit();
    });
    _emit();
  }

  void cancelScheduled() {
    _schedTimer?.cancel();
    scheduled = null;
    _emit();
  }

  /// The last ~10 minutes of temperatures Moonraker keeps (1 sample/s).
  /// Keys are sensor names; `<name>#target` holds the targets.
  Future<Map<String, List<double>>> temperatureStore() async {
    final r = await _http.get(
        _uri(['server', 'temperature_store'], {'include_monitors': 'false'}),
        headers: authHeaders);
    _check(r);
    List<double> nums(dynamic l) =>
        [for (final v in (l as List?) ?? const []) (v as num).toDouble()];
    final res = Map<String, dynamic>.from(jsonDecode(r.body)['result'] ?? {});
    return {
      for (final e in res.entries) ...{
        e.key: nums(e.value['temperatures']),
        '${e.key}#target': nums(e.value['targets']),
      },
    };
  }

  // --- Job queue ------------------------------------------------------------

  Future<(List<QueuedJob>, String)> queue() async {
    final r = await _http.get(_uri(['server', 'job_queue', 'status']),
        headers: authHeaders);
    _check(r);
    final res = jsonDecode(r.body)['result'];
    return (
      [
        for (final j in (res['queued_jobs'] as List?) ?? const [])
          QueuedJob('${j['job_id']}', '${j['filename']}'),
      ],
      '${res['queue_state']}',
    );
  }

  Future<void> enqueue(String filename) async => _check(await _http.post(
      _uri(['server', 'job_queue', 'job'], {'filenames': filename}),
      headers: authHeaders));
  Future<void> dequeue(String id) async => _check(await _http.delete(
      _uri(['server', 'job_queue', 'job'], {'job_ids': id}),
      headers: authHeaders));
  Future<void> startQueue() async => _check(await _http
      .post(_uri(['server', 'job_queue', 'start']), headers: authHeaders));
  Future<void> pauseQueue() async => _check(await _http
      .post(_uri(['server', 'job_queue', 'pause']), headers: authHeaders));

  // --- Folders --------------------------------------------------------------

  /// Sub-folders and files of a folder under gcodes ("" = top level).
  Future<(List<String>, List<GcodeFile>)> directory(String path) async {
    final r = await _http
        .get(
            _uri(['server', 'files', 'directory'],
                {'path': path.isEmpty ? 'gcodes' : 'gcodes/$path'}),
            headers: authHeaders)
        .timeout(const Duration(seconds: 15));
    _check(r);
    final res = jsonDecode(r.body)['result'];
    final prefix = path.isEmpty ? '' : '$path/';
    final dirs = [
      for (final d in (res['dirs'] as List?) ?? const [])
        if (!'${d['dirname']}'.startsWith('.')) '${d['dirname']}',
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final files = [
      for (final f in (res['files'] as List?) ?? const [])
        GcodeFile(
          '$prefix${f['filename']}',
          (f['size'] as num?)?.toInt() ?? 0,
          DateTime.fromMillisecondsSinceEpoch(
              (((f['modified'] as num?) ?? 0) * 1000).round()),
        ),
    ];
    return (dirs, files);
  }

  Future<void> moveFile(String from, String to) async => _check(await _http.post(
      _uri(['server', 'files', 'move'],
          {'source': 'gcodes/$from', 'dest': 'gcodes/$to'}),
      headers: authHeaders));
  Future<void> createDir(String path) async => _check(await _http.post(
      _uri(['server', 'files', 'directory'], {'path': 'gcodes/$path'}),
      headers: authHeaders));
  Future<void> deleteDir(String path) async => _check(await _http.delete(
      _uri(['server', 'files', 'directory'],
          {'path': 'gcodes/$path', 'force': 'true'}),
      headers: authHeaders));

  Future<Uint8List> downloadRange(String path, int start, int end) async {
    final r = await _http.get(
      _uri(['server', 'files', 'gcodes', ...path.split('/')]),
      headers: {...authHeaders, 'Range': 'bytes=$start-$end'},
    ).timeout(const Duration(seconds: 20));
    _check(r);
    return r.bodyBytes;
  }

  Future<Uint8List> download(String path) async {
    final r = await _http
        .get(_uri(['server', 'files', 'gcodes', ...path.split('/')]),
            headers: authHeaders)
        .timeout(const Duration(minutes: 3));
    _check(r);
    return r.bodyBytes;
  }

  // --- Power devices (Moonraker [power] sections) ---------------------------

  Future<List<PowerDevice>> powerDevices() async {
    try {
      final r = await _http.get(_uri(['machine', 'device_power', 'devices']),
          headers: authHeaders);
      if (r.statusCode >= 300) return const [];
      return [
        for (final d
            in (jsonDecode(r.body)['result']?['devices'] as List?) ?? const [])
          PowerDevice('${d['device']}', d['status'] == 'on'),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> setPower(String device, bool on) async => _check(await _http.post(
      _uri(['machine', 'device_power', 'device'],
          {'device': device, 'action': on ? 'on' : 'off'}),
      headers: authHeaders));

  void dispose() {
    _closed = true;
    _schedTimer?.cancel();
    _reconnect?.cancel();
    _resub?.cancel();
    _closeTransport();
    _statusCtrl.close();
    _consoleCtrl.close();
  }
}
