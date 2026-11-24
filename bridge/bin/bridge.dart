// Printer Hub home bridge.
//
// Runs next to the printer (NAS, Raspberry Pi, Mac) and keeps one outgoing
// connection to your relay, so the app can reach the printer from anywhere
// without opening router ports. Every frame is end-to-end encrypted; the
// relay only passes sealed data along.
//
//   bridge --relay https://printer-hub-relay.<you>.workers.dev --printer 192.168.68.53
//   bridge --show-code   print the pairing code / QR again
//   bridge --reset       new code; phones paired with the old one stop working
//
// Options can also come from the environment (handy in Docker):
//   RELAY_URL, PRINTER_HOST, MOONRAKER_PORT, BRIDGE_DATA
//
// Camera from away: --camera / CAMERA_URL is an MJPEG stream or JPEG
// snapshot URL on the LAN (for WebRTC-only cameras, a go2rtc MJPEG URL).
// It is read only while a phone is watching (and, with the failure
// detector, every 30 s during a print).
//
// Failure detection: DETECTOR_URL (default http://127.0.0.1:7072, the
// detector container from COMPOSE_PROFILES=detector) scores camera frames
// for spaghetti. Without the container nothing happens.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';
import 'package:qr/qr.dart';
import 'package:web_socket_channel/io.dart';

/// The last 200 log lines, for the app's "Bridge log" (and /log on the status page).
final recentLog = <String>[];

void log(String m) {
  final line = '${DateTime.now().toIso8601String().substring(0, 19)}  $m';
  stdout.writeln(line);
  recentLog.add(line);
  if (recentLog.length > 200) recentLog.removeRange(0, recentLog.length - 200);
}

/// Answers for the bridge's own paths (`/bridge/info`, `/bridge/log`), or null.
(int, String, String)? bridgeOwn(String path) => switch (path) {
      '/bridge/info' => (200, 'application/json', jsonEncode({'version': kBridgeVersion})),
      '/bridge/log' => (200, 'text/plain; charset=utf-8', recentLog.join('\n')),
      _ => null,
    };

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final hasValue = i + 1 < argv.length && !argv[i + 1].startsWith('--');
    args[a.substring(2)] = hasValue ? argv[++i] : 'true';
  }
  if (args.containsKey('version')) {
    stdout.writeln('printer-hub-bridge $kBridgeVersion');
    return;
  }
  if (args.containsKey('help')) {
    stdout.writeln('Usage: bridge --relay <url> --printer <ip> [--port 7125] '
        '[--data <dir>] [--show-code] [--reset] [--version]');
    return;
  }
  final env = Platform.environment;
  final dataDir = Directory(args['data'] ??
      env['BRIDGE_DATA'] ??
      '${env['HOME'] ?? '.'}/.printer-hub-bridge');
  final stateFile = File('${dataDir.path}/pairing.json');

  if (args['reset'] == 'true' && stateFile.existsSync()) {
    stateFile.deleteSync();
    log('Old pairing removed. Phones must be paired again.');
  }

  Map<String, dynamic> saved = {};
  if (stateFile.existsSync()) {
    saved = Map<String, dynamic>.from(jsonDecode(stateFile.readAsStringSync()));
  }
  final printer = args['printer'] ?? env['PRINTER_HOST'] ?? saved['printer'] as String?;
  final port = int.tryParse(args['port'] ?? env['MOONRAKER_PORT'] ?? '') ??
      (saved['port'] as int?) ??
      7125;
  final relayUrl = args['relay'] ?? env['RELAY_URL'];
  final alertsOff = (args['alerts'] ?? env['ALERTS']) == 'off';
  final ntfyServer = args['ntfy'] ?? env['NTFY_SERVER'] ?? 'https://ntfy.sh';

  PairInfo pair;
  if (saved['code'] is String) {
    pair = PairInfo.decode(saved['code']);
    if (relayUrl != null && PairInfo.normalizeRelay(relayUrl) != pair.relay) {
      stderr.writeln('This bridge is paired with ${pair.relay}. '
          'Use --reset to switch to another relay.');
      exit(2);
    }
  } else {
    if (relayUrl == null || printer == null) {
      stderr.writeln('First run needs --relay <url> and --printer <ip>.');
      exit(2);
    }
    pair = PairInfo.create(relayUrl,
        alerts: alertsOff ? null : PairInfo.newAlertTopic(ntfyServer));
  }
  if (printer == null) {
    stderr.writeln('Missing --printer <ip>.');
    exit(2);
  }

  dataDir.createSync(recursive: true);
  stateFile.writeAsStringSync(jsonEncode({'code': pair.encode(), 'printer': printer, 'port': port}));
  if (!Platform.isWindows) await Process.run('chmod', ['600', stateFile.path]);

  _printPairing(pair);
  if (args['show-code'] == 'true') return;

  final cameraUrl = args['camera'] ?? env['CAMERA_URL'];
  final camera = cameraUrl == null || cameraUrl.isEmpty ? null : CameraFeed(Uri.parse(cameraUrl));
  final topic = pair.alerts;
  final alerts = topic == null || alertsOff
      ? null
      : Alerts(Uri.parse(topic), printer, port,
          name: args['name'] ?? env['PRINTER_NAME'],
          humidityLimit: double.tryParse(env['HUMIDITY_LIMIT'] ?? '') ?? 45,
          camera: camera,
          autoFilter: env['AUTO_FILTER'] != 'off',
          quiet: parseQuietHours(env['QUIET_HOURS']),
          spoolLow: double.tryParse(env['SPOOL_LOW_G'] ?? '') ?? 100,
          detector: env['DETECTOR_URL'] == 'off'
              ? null
              : Uri.parse(env['DETECTOR_URL'] ?? 'http://127.0.0.1:7072'),
          failureThreshold: double.tryParse(env['FAILURE_THRESHOLD'] ?? '') ?? 0.8,
          pauseRepeat: int.tryParse(env['PAUSE_REPEAT_MIN'] ?? '') ?? 15,
          offlineAfter: int.tryParse(env['OFFLINE_ALERT_MIN'] ?? '') ?? 10,
          summaryAt: env['DAILY_SUMMARY'] ?? '',
          bedCool: double.tryParse(env['BED_COOL_C'] ?? '') ?? 35,
          progressAlerts: [for (final v in (env['PROGRESS_ALERTS'] ?? '').split(',')) ?int.tryParse(v.trim())],
          weeklyAt: env['WEEKLY_SUMMARY'] ?? '',
          heatTimeout: int.tryParse(env['HEAT_TIMEOUT_MIN'] ?? '') ?? 15,
          overrunPct: int.tryParse(env['OVERRUN_PCT'] ?? '') ?? 30,
          layerStuck: int.tryParse(env['LAYER_STUCK_MIN'] ?? '') ?? 30,
          extraTopics: [
            for (final t in (env['EXTRA_TOPICS'] ?? '').split(','))
              if (Uri.tryParse(t.trim()) case final u? when u.scheme.startsWith('http') && u.pathSegments.isNotEmpty) u,
          ],
          alertWebhook: webhookUri('@webhook ${env['ALERT_WEBHOOK'] ?? ''}'),
          mqtt: (env['MQTT_URL'] ?? '').startsWith('mqtt://')
              ? MqttStatus(Uri.parse(env['MQTT_URL']!), args['name'] ?? env['PRINTER_NAME'] ?? printer)
              : null);
  if (args['test-alert'] == 'true') {
    if (alerts == null) {
      stderr.writeln('Alerts are off for this pairing (re-pair with --reset to turn them on).');
      exit(2);
    }
    await alerts.send('Printer Hub test alert', 'Alerts from your printer will arrive like this.',
        tags: ['white_check_mark']);
    log('Test alert sent to $topic');
    return;
  }
  if (alerts != null) {
    log('Alerts: push notifications go to $topic');
    unawaited(alerts.run());
  } else if (topic == null && !alertsOff) {
    log('Alerts are off for this pairing. Run with --reset to get a code with alerts.');
  }

  final statusPort = int.tryParse(env['STATUS_PORT'] ?? '');
  if (statusPort != null) unawaited(serveStatus(statusPort, printer, port, alerts, camera: camera));

  log('Printer Hub bridge $kBridgeVersion: printer $printer:$port through ${pair.relay}');
  if (camera != null) log('Camera from away: $cameraUrl');
  final slicerPort = int.tryParse(env['SLICER_PORT'] ?? '') ?? 7070;
  unawaited(_logSlicer(slicerPort));
  await Bridge(pair, await LinkCrypto.forPair(pair), printer, port, camera: camera, slicerPort: slicerPort).run();
}

/// Says once at start whether slicing from the app will work. Tries for a
/// minute: the slicer container often starts alongside the bridge.
Future<void> _logSlicer(int port) async {
  for (var i = 0; i < 12; i++) {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:$port/slicer/presets')).timeout(const Duration(seconds: 3));
      return log(r.statusCode == 200 ? 'Slicer: ready on port $port' : 'Slicer: answered HTTP ${r.statusCode} on port $port');
    } catch (_) {
      await Future.delayed(const Duration(seconds: 5));
    }
  }
  log('Slicer: not running (optional; add slicer to COMPOSE_PROFILES to slice from the app)');
}

/// Reads a home camera (MJPEG stream or JPEG snapshot URL) only while a
/// phone is asking for frames, and keeps the latest one.
class CameraFeed {
  final Uri url;
  CameraFeed(this.url);

  static const _idle = Duration(seconds: 20);
  Uint8List? _frame;
  var _frameAt = DateTime(0), _wanted = DateTime(0);
  var _running = false, _quiet = false;
  String? _error;

  bool get _watched => DateTime.now().difference(_wanted) < _idle;

  /// [quiet]: the failure detector asking, not a phone; not logged.
  Future<Uint8List> frame({bool quiet = false}) async {
    _wanted = DateTime.now();
    if (!quiet && _quiet && _running) log('Camera: a phone is watching');
    if (!quiet) _quiet = false;
    if (!_running) {
      _quiet = quiet;
      unawaited(_run());
    }
    // A cold WebRTC camera behind go2rtc takes ~8 s for its first frame.
    for (var i = 0; i < 200; i++) {
      final f = _frame;
      if (f != null && DateTime.now().difference(_frameAt).inSeconds < 3) return f;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    throw _error ?? 'The camera sent no picture';
  }

  Future<void> _run() async {
    _running = true;
    if (!_quiet) log('Camera: a phone is watching');
    final client = http.Client();
    try {
      while (_watched) {
        try {
          final res = await client.send(http.Request('GET', url)).timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) throw 'Camera returned HTTP ${res.statusCode}';
          final split = JpegSplitter();
          await for (final chunk in res.stream.timeout(const Duration(seconds: 15))) {
            for (final f in split.add(chunk)) {
              _frame = f;
              _frameAt = DateTime.now();
              _error = null;
            }
            if (!_watched) break;
          }
        } on TimeoutException {
          _error = 'The camera sent no picture';
        } catch (e) {
          _error = '$e';
        }
        // Snapshot URLs end after one frame (≈1 fps); streams retry here.
        if (_watched) await Future.delayed(const Duration(seconds: 1));
      }
    } finally {
      client.close();
      _running = false;
      _frame = null;
      if (!_quiet) log('Camera: idle, released');
    }
  }
}

/// Watches the printer around the clock and pushes the moments that matter
/// to an ntfy topic, so alerts arrive even when the app is closed.
class Alerts {
  final Uri topic;
  final String host;
  final int port;
  final String? name;
  final double humidityLimit;
  final CameraFeed? camera;
  final bool autoFilter;
  final _client = http.Client();

  final _stats = <String, dynamic>{};
  final _box = <String, dynamic>{};
  final _dragon = <String, dynamic>{};
  double _progress = 0;
  String? _state;
  final _humidityAlerted = <String, DateTime>{};
  var _sent = <String>{}; // once-per-print alerts already sent
  bool _hasFilter = false;
  DateTime? _started;
  final _lanes = <String, Map<String, dynamic>>{};
  String? _laneDataSent;
  List<Map> _rules = const [];
  final _ranToday = <String>{};
  Timer? _filterOff;

  final (int, int)? quiet; // start and end hour; only urgent alerts then
  final double spoolLow; // grams; warn when a lane's spool has less
  final _spoolWarned = <int, DateTime>{};

  final Uri? detector; // the failure detector container, if any
  final FailureWatch _failure;

  final int pauseRepeat; // minutes between "still paused" alerts, 0 = once
  final int offlineAfter; // minutes unreachable before an alert, 0 = never
  final String summaryAt; // "21:00" = daily summary then, '' = off
  final List<int> progressAlerts; // e.g. [25, 50, 75]: alert at these percents
  final String weeklyAt; // "Sun 20:00" = weekly summary then, '' = off
  DateTime? _pausedAt, _downSince;
  bool _offlineSent = false;
  int _snoozeUntil = 0; // ms; the app sets printer_hub/snooze
  final _sensors = <String, bool>{}; // filament sensor -> filament detected
  final _chamber = <String, dynamic>{};
  double? _bedTemp, _bedTarget, _nozzle, _nozzleTarget;
  DateTime? _heatingSince; // nozzle set but not near its target yet
  final int heatTimeout; // minutes before "still heating" alerts, 0 = off
  final int overrunPct; // alert when a print runs this % over the slicer's estimate, 0 = off
  final int layerStuck; // minutes on one layer before an alert, 0 = off
  final List<Uri> extraTopics; // more ntfy topics that get every alert (family)
  final Uri? alertWebhook; // every alert also POSTed here as JSON
  final MqttStatus? mqtt; // status to Home Assistant over MQTT
  DateTime _mqttAt = DateTime(0);
  double? _estimate; // slicer's estimate for the current print
  int? _layer;
  DateTime? _layerSince;
  double? get nozzle => _nozzle;
  double? get bedTemp => _bedTemp;
  double? get chamber => (_chamber['temperature'] as num?)?.toDouble();
  bool _waitBedCool = false; // after a finished print, until the bed is cool
  int _queuedIdle = 0; // jobs in Moonraker's queue while idle (checked each minute)
  bool _fromQueue = false; // the current print was taken from the queue
  DateTime? _idleSince; // when the printer last stopped printing
  final _idleRan = <String>{}; // idle rules already run in this idle stretch
  final _lastRan = <String, int>{}; // rule signature -> when it last ran (s), shown in the app
  bool _lastRanDirty = false;
  final _alertLog = <Map<String, Object>>[]; // last 100 alerts, kept in Moonraker for the app
  bool _alertLogDirty = false;
  final double bedCool; // °C; "take the print off" below this, 0 = off
  final counters = <String, int>{'alerts': 0, 'rules': 0, 'prints_started': 0};
  String? get state => _state;
  double get progress => _progress;
  String get file => '${_stats['filename'] ?? ''}'.split('/').last;
  bool get online => _downSince == null;

  Alerts(this.topic, this.host, this.port,
      {this.name,
      this.humidityLimit = 45,
      this.camera,
      this.autoFilter = true,
      this.quiet,
      this.spoolLow = 100,
      this.detector,
      double failureThreshold = 0.8,
      this.pauseRepeat = 15,
      this.offlineAfter = 10,
      this.summaryAt = '',
      this.bedCool = 35,
      this.progressAlerts = const [],
      this.weeklyAt = '',
      this.heatTimeout = 15,
      this.overrunPct = 30,
      this.layerStuck = 30,
      this.extraTopics = const [],
      this.alertWebhook,
      this.mqtt})
      : _failure = FailureWatch(threshold: failureThreshold);

  String get _title => name ?? host;

  /// RFC 2047 so ntfy headers can carry UTF-8 (printer names, emoji).
  static String _h(String v) => '=?UTF-8?B?${base64.encode(utf8.encode(v))}?=';

  /// ntfy's JSON publish endpoint takes UTF-8 titles (headers can't). With
  /// [picture] and a camera, the current frame is attached instead.
  Future<void> send(String title, String message,
      {List<String> tags = const [], int priority = 3, bool picture = false, List<int>? jpeg}) async {
    if (priority < 5 && inQuietHours(quiet, DateTime.now().hour)) {
      log('Quiet hours: held back "$title"');
      return;
    }
    if (priority < 5 && DateTime.now().millisecondsSinceEpoch < _snoozeUntil) {
      log('Snoozed: held back "$title"');
      return;
    }
    counters['alerts'] = counters['alerts']! + 1;
    _alertLog.add({'at': DateTime.now().millisecondsSinceEpoch ~/ 1000, 'title': title, 'message': message});
    if (_alertLog.length > 100) _alertLog.removeAt(0);
    _alertLogDirty = true;
    unawaited(_fanOut(title, message, priority));
    final server = topic.replace(path: '', query: null);
    final name = topic.pathSegments.last;
    if (jpeg != null || (picture && camera != null)) {
      try {
        jpeg ??= await camera!.frame();
        final r = await _client
            .put(topic,
                headers: {
                  'Filename': 'printer.jpg',
                  'Title': _h(title),
                  'Message': _h(message),
                  'Tags': tags.join(','),
                  'Priority': '$priority',
                  'Click': openLink(_title),
                  'Actions': 'view, Open in Printer Hub, ${openLink(_title)}',
                },
                body: jpeg)
            .timeout(const Duration(seconds: 30));
        if (r.statusCode < 300) return;
        log('Alert picture not delivered (HTTP ${r.statusCode}); sending text only');
      } catch (e) {
        log('No picture for the alert ($e); sending text only');
      }
    }
    try {
      final r = await _client
          .post(server,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'topic': name,
                'title': title,
                'message': message,
                'tags': tags,
                'priority': priority,
                // Tapping the alert opens this printer in Printer Hub.
                'click': openLink(_title),
                'actions': [
                  {'action': 'view', 'label': 'Open in Printer Hub', 'url': openLink(_title)},
                ],
              }))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) log('Alert not delivered (HTTP ${r.statusCode})');
    } catch (e) {
      log('Alert not delivered: $e');
    }
  }

  /// Copies of an alert: extra ntfy topics (text only) and the alert webhook.
  Future<void> _fanOut(String title, String message, int priority) async {
    for (final t in extraTopics) {
      try {
        await _client
            .post(t.replace(path: '', query: null),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'topic': t.pathSegments.last, 'title': title, 'message': message, 'priority': priority, 'click': openLink(_title)}))
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        log('Extra topic not reached: $e');
      }
    }
    final hook = alertWebhook;
    if (hook == null) return;
    try {
      await _client
          .post(hook,
              headers: {'Content-Type': 'application/json'},
              // "content" makes it show up in a Discord channel as is.
              body: jsonEncode({'printer': _title, 'title': title, 'message': message, 'priority': priority, 'content': '**$title**\n$message'}))
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      log('Alert webhook not reached: $e');
    }
  }

  Future<void> run() async {
    unawaited(_rulesLoop());
    if (detector != null && camera != null) unawaited(_failureLoop());
    var backoff = 2;
    while (true) {
      final started = DateTime.now();
      try {
        await _watch();
      } catch (e) {
        log('Alerts: lost the printer ($e)');
      }
      _downSince ??= DateTime.now();
      if (offlineAfter > 0 && !_offlineSent && DateTime.now().difference(_downSince!).inMinutes >= offlineAfter) {
        _offlineSent = true;
        await send('$_title: offline', 'The bridge has not reached the printer for $offlineAfter minutes.',
            tags: ['electric_plug'], priority: 4);
      }
      if (DateTime.now().difference(started).inMinutes >= 1) backoff = 2;
      await Future.delayed(Duration(seconds: backoff));
      backoff = math.min(backoff * 2, 60);
    }
  }

  Future<void> _watch() async {
    final ws = await WebSocket.connect('ws://$host:$port/websocket')
        .timeout(const Duration(seconds: 10));
    var id = 0;
    if (_offlineSent) {
      _offlineSent = false;
      unawaited(send('$_title: back online', 'The bridge can reach the printer again.', tags: ['electric_plug']));
    }
    _downSince = null;
    // U1 AFC lanes, so OrcaSlicer's own filament sync can read them.
    List<String> lanes = const [], sensors = const [], chambers = const [];
    try {
      final r = await _client.get(Uri.parse('http://$host:$port/printer/objects/list'));
      final objs = [for (final o in (jsonDecode(r.body)['result']?['objects'] as List?) ?? const []) '$o'];
      lanes = [for (final o in objs) if (o.startsWith('AFC_lane ')) o];
      sensors = [for (final o in objs) if (o.startsWith('filament_switch_sensor ') || o.startsWith('filament_motion_sensor ')) o];
      chambers = [for (final o in objs) if (o == 'heater_generic chamber_heater' || o == 'heater_generic dragonbreath') o];
    } catch (_) {}
    void subscribe() => ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': ++id,
          'method': 'printer.objects.subscribe',
          'params': {
            'objects': {
              'print_stats': ['state', 'filename', 'message', 'print_duration', 'filament_used', 'info'],
              'virtual_sdcard': ['progress'],
              'box': null,
              'dragonbreath': ['connected', 'fault', 'fault_reason', 'mode'],
              'output_pin dragonbreath_filter': null,
              for (final l in lanes) l: ['map', 'load', 'color', 'material', 'spool_id', 'filament_name'],
              for (final f in sensors) f: ['filament_detected', 'enabled'],
              for (final c in chambers) c: ['temperature', 'target'],
              'heater_bed': ['temperature', 'target'],
              'extruder': ['temperature', 'target'],
            },
          },
        }));
    subscribe();
    await for (final raw in ws) {
      final Map msg;
      try {
        msg = jsonDecode('$raw') as Map;
      } catch (_) {
        continue;
      }
      final method = msg['method'];
      if (method == 'notify_klippy_ready') {
        subscribe();
        continue;
      }
      if (method == 'notify_klippy_shutdown') {
        await send('$_title: printer shut down',
            'Klipper stopped (often an error or emergency stop). Check the printer.',
            tags: ['rotating_light'], priority: 5);
        continue;
      }
      Map? status;
      final result = msg['result'];
      if (result is Map && result['status'] is Map) {
        status = result['status'] as Map;
      } else if (method == 'notify_status_update' &&
          msg['params'] is List &&
          (msg['params'] as List).isNotEmpty) {
        status = (msg['params'] as List).first as Map?;
      }
      if (status != null) await _apply(status);
    }
  }

  Future<void> _apply(Map status) async {
    final ps = status['print_stats'];
    if (ps is Map) _stats.addAll(Map<String, dynamic>.from(ps));
    final box = status['box'];
    if (box is Map) _box.addAll(Map<String, dynamic>.from(box));
    var lanesChanged = false;
    for (final e in status.entries) {
      if ('${e.key}'.startsWith('AFC_lane ') && e.value is Map) {
        (_lanes['${e.key}'] ??= {}).addAll(Map<String, dynamic>.from(e.value as Map));
        lanesChanged = true;
      }
    }
    if (lanesChanged) unawaited(_publishLaneData());
    for (final e in status.entries) {
      final k = '${e.key}';
      final v = e.value;
      if ((k.startsWith('filament_switch_sensor ') || k.startsWith('filament_motion_sensor ')) && v is Map) {
        final det = v['filament_detected'];
        if (det is bool) {
          final was = _sensors[k];
          _sensors[k] = det;
          if (was == true && !det && (_state == 'printing' || _state == 'paused') && v['enabled'] != false) {
            await send('$_title: filament ran out', 'The ${k.split(' ').last} sensor sees no filament.',
                tags: ['warning'], priority: 5, picture: true);
            unawaited(_runRules((r) => r['on'] == 'runout'));
          }
        }
      }
      if (k.startsWith('heater_generic ') && v is Map) _chamber.addAll(Map<String, dynamic>.from(v));
    }
    final bt = (status['heater_bed'] as Map?)?['temperature'];
    if (bt is num) _bedTemp = bt.toDouble();
    final bg = (status['heater_bed'] as Map?)?['target'];
    if (bg is num) _bedTarget = bg.toDouble();
    final ex = status['extruder'];
    if (ex is Map) {
      if (ex['temperature'] is num) _nozzle = (ex['temperature'] as num).toDouble();
      if (ex['target'] is num) _nozzleTarget = (ex['target'] as num).toDouble();
    }
    // A heater that never gets there: a loose thermistor, a bad heater, a draught.
    final heating = stillHeating(_nozzle, _nozzleTarget) || stillHeating(_bedTemp, _bedTarget, margin: 3);
    if (!heating) {
      _heatingSince = null;
      _sent.remove('heat_timeout');
    } else if (heatTimeout > 0 &&
        DateTime.now().difference(_heatingSince ??= DateTime.now()).inMinutes >= heatTimeout &&
        _sent.add('heat_timeout')) {
      await send('$_title: still heating', 'Nozzle ${_nozzle?.round()}°C of ${_nozzleTarget?.round()}°C, bed ${_bedTemp?.round()}°C of ${_bedTarget?.round()}°C after $heatTimeout minutes. Check the heaters.',
          tags: ['thermometer'], priority: 4);
    }
    if (_waitBedCool && bedCool > 0 && _bedTemp != null && _bedTemp! < bedCool) {
      _waitBedCool = false;
      await send('$_title: bed has cooled', 'Down to ${_bedTemp!.round()}°C. Prints usually come off easily now.',
          tags: ['snowflake'], priority: 3);
      unawaited(_runRules((r) => r['on'] == 'bed_cool'));
    }
    final ct = (_chamber['temperature'] as num?)?.toDouble(), cg = (_chamber['target'] as num?)?.toDouble();
    if (chamberReady(ct, cg)) {
      if (_sent.add('chamber_ready $cg')) {
        await send('$_title: chamber at ${cg!.round()}°C', 'Ready to print.', tags: ['thermometer'], priority: 3);
        unawaited(_runRules((r) => r['on'] == 'chamber_ready'));
      }
    } else if (cg == null || cg <= 0) {
      _sent.removeWhere((x) => x.startsWith('chamber_ready'));
    }
    final db = status['dragonbreath'];
    final wasDrying = _dragon['mode'] == 'drying';
    if (db is Map) _dragon.addAll(Map<String, dynamic>.from(db));
    if (wasDrying && db is Map && db.containsKey('mode') && _dragon['mode'] != 'drying' && _dragon['fault'] != true) {
      await send('$_title: filament is dry', 'The DragonBreath finished drying.', tags: ['sunny'], priority: 3);
      unawaited(_runRules((r) => r['on'] == 'dry_done'));
    }
    if (status['output_pin dragonbreath_filter'] != null) _hasFilter = true;
    final p = status['virtual_sdcard']?['progress'];
    if (p is num) _progress = p.toDouble();

    final state = _stats['state'] as String?;
    final file = '${_stats['filename'] ?? ''}'.split('/').last;
    // At most every 10 s, or at once when the state changes.
    if (mqtt != null && (state != _state || DateTime.now().difference(_mqttAt).inSeconds >= 10)) {
      _mqttAt = DateTime.now();
      final dur = (_stats['print_duration'] as num?)?.toDouble() ?? 0;
      unawaited(mqtt!.publish({
        'state': state,
        'progress': (_progress * 100).round(),
        'eta_min': state == 'printing' && _progress > 0.01 && dur > 0 ? (dur / _progress - dur) ~/ 60 : null,
        'nozzle': _nozzle?.round(),
        'bed': _bedTemp?.round(),
        'file': file,
        'layer': (_stats['info'] as Map?)?['current_layer'],
        'chamber': chamber?.round(),
        'filament_m': (((_stats['filament_used'] as num?) ?? 0) / 1000).toStringAsFixed(2),
      }));
    }
    final note = '${_stats['message'] ?? ''}'.trim();
    final last = _state;
    _state = state;
    if (last != null && state != null && state != last) {
      unawaited(_runRules((r) => r['on'] == state));
      switch (state) {
        case 'complete':
          _waitBedCool = true;
          if (_fromQueue) {
            unawaited(_queueSize().then((n) async {
              if (n == 0) await send('$_title: queue finished', 'Every job in the queue has printed.', tags: ['tada'], priority: 3);
            }));
          }
          await send('$_title: print finished', finishedText(file, _stats),
              tags: ['white_check_mark'], priority: 4, jpeg: await _keep('end'));
          unawaited(_checkSpools());
          unawaited(_prune());
        case 'error':
          await send('$_title: print failed',
              '${note.isEmpty ? file : note} (at ${(_progress * 100).round()}%${(_stats['info'] as Map?)?['current_layer'] is num ? ', layer ${(_stats['info'] as Map)['current_layer']}' : ''})',
              tags: ['warning'], priority: 5, jpeg: await _keep('end'));
        case 'cancelled':
          await send('$_title: print cancelled', file, tags: ['x']);
        case 'paused' when last == 'printing':
          _pausedAt = DateTime.now();
          _layerSince = null; // a pause isn't a stuck layer
          await send('$_title: print paused',
              note.isEmpty ? 'Check the printer (filament run-out?)' : note,
              tags: ['pause_button'], priority: 4, picture: true);
        case 'printing' when last == 'standby' || last == 'complete' || last == 'cancelled' || last == 'error':
          _sent = {};
          _waitBedCool = false;
          _estimate = null;
          _layer = null;
          _layerSince = null;
          _started = DateTime.now();
          counters['prints_started'] = counters['prints_started']! + 1;
          unawaited(_queueSize().then((n) => _fromQueue = _queuedIdle > n));
          _failure.reset();
          await send('$_title: print started', await _startedText(file), tags: ['printer'], priority: 2);
          if (autoFilter && _hasFilter) unawaited(_filterFor('${_stats['filename'] ?? ''}'));
      }
      if (state != 'printing' && state != 'paused' && _filterOn) {
        // Keep filtering a while so fumes clear, then stop.
        _filterOff?.cancel();
        _filterOff = Timer(const Duration(minutes: 10), () {
          if (_state != 'printing') _setFilter(false);
        });
      }
    }

    if (state == 'printing') {
      final dur0 = (_stats['print_duration'] as num?)?.toDouble() ?? 0;
      if (overrunPct > 0 && overran(dur0, _estimate, overrunPct) && _sent.add('overrun')) {
        await send('$_title: taking longer than planned',
            'Printing ${(dur0 / 60).round()} min against an estimate of ${(_estimate! / 60).round()} min. Worth a look.',
            tags: ['hourglass'], priority: 3, picture: true);
      }
      final cl = (_stats['info'] as Map?)?['current_layer'];
      if (cl is num && cl.toInt() != _layer) {
        _layer = cl.toInt();
        _layerSince = DateTime.now();
        _sent.remove('stuck');
        unawaited(_runRules((r) => r['on'] == 'layer' && int.tryParse('${r['at']}') == _layer));
      } else if (_layerSince == null) {
        _layerSince = DateTime.now(); // just resumed: start counting again
      } else if (layerStuck > 0 && _layer != null &&
          DateTime.now().difference(_layerSince!).inMinutes >= layerStuck && _sent.add('stuck')) {
        await send('$_title: stuck on layer $_layer?', 'The same layer for $layerStuck minutes. Check for a clog or a stall.',
            tags: ['warning'], priority: 4, picture: true);
      }
      final layer = (_stats['info'] as Map?)?['current_layer'];
      if (layer is num && layer >= 2 && _sent.add('first_layer')) {
        await send('$_title: first layer done', 'Have a look before it carries on.',
            tags: ['mag'], priority: 2, jpeg: await _keep('first'));
        unawaited(_runRules((r) => r['on'] == 'first_layer'));
      }
      for (final at in progressAlerts) {
        if (at > 0 && at < 100 && _progress * 100 >= at && _sent.add('pct $at')) {
          await send('$_title: $at% done', file, tags: ['hourglass_flowing_sand'], priority: 2);
        }
      }
      for (final r in _rules.where((r) => r['on'] == 'progress')) {
        final at = double.tryParse('${r['at']}');
        if (at != null && _progress * 100 >= at && _sent.add('progress $at ${r['do']}')) {
          unawaited(_runRules((x) => identical(x, r)));
        }
      }
      final dur = (_stats['print_duration'] as num?)?.toDouble() ?? 0;
      if (_progress > 0.5 && dur > 0) {
        final left = dur * (1 - _progress) / _progress;
        if (left < 600 && _sent.add('almost_done')) {
          await send('$_title: about ${(left / 60).ceil()} min left', file, tags: ['hourglass'], priority: 3);
        }
      }
    }

    if (_dragon['fault'] == true && _sent.add('heater_fault')) {
      await send('$_title: chamber heater fault', '${_dragon['fault_reason'] ?? 'Check the DragonBreath.'}',
          tags: ['fire'], priority: 5);
      unawaited(_runRules((r) => r['on'] == 'heater_fault'));
    } else if (_dragon['fault'] == false) {
      _sent.remove('heater_fault');
    }

    for (var i = 1; i <= 4; i++) {
      final t = _box['T$i'];
      if (t is! Map || t['state'] != 'connect') continue;
      final h = double.tryParse('${t['dry_and_humidity']}');
      final prev = _humidityAlerted['T$i'];
      if (h == null || h < humidityLimit) continue;
      if (prev != null && DateTime.now().difference(prev).inHours < 6) continue;
      _humidityAlerted['T$i'] = DateTime.now();
      unawaited(_runRules((r) => r['on'] == 'humidity'));
      await send('$_title: CFS $i humidity ${h.toStringAsFixed(0)}%',
          'Above ${humidityLimit.toStringAsFixed(0)}%. Dry the filament before it absorbs more moisture.',
          tags: ['droplet']);
    }
  }
}

/// AFC_lane status -> Moonraker `lane_data` (the AFC / Happy Hare format
/// OrcaSlicer's Moonraker agent reads for "Sync filaments").
Map<String, Map<String, dynamic>> laneData(Map<String, Map<String, dynamic>> lanes) => {
      for (final e in lanes.entries)
        // Keyed T0..T3 like HelixScreen writes, so one entry per tool (no stale twins).
        'T${int.tryParse('${e.value['map'] ?? ''}'.replaceAll(RegExp(r'\D'), '')) ?? 0}': {
          'lane': '${int.tryParse('${e.value['map'] ?? ''}'.replaceAll(RegExp(r'\D'), '')) ?? 0}',
          'name': e.key.substring('AFC_lane '.length),
          'color': e.value['load'] == true ? '${e.value['color'] ?? ''}' : '',
          'material': e.value['load'] == true ? '${e.value['material'] ?? ''}' : '',
          if (e.value['spool_id'] is num && (e.value['spool_id'] as num) > 0) 'spool_id': e.value['spool_id'],
          if ('${e.value['filament_name'] ?? ''}'.isNotEmpty) 'filament_name': e.value['filament_name'],
        },
    };

extension on Alerts {
  Future<void> _publishLaneData() async {
    final data = laneData(_lanes);
    final body = jsonEncode(data);
    if (body == _laneDataSent) return;
    try {
      // Moonraker stores a namespace as items; write each lane, then drop stale ones.
      for (final e in data.entries) {
        await _client.post(Uri.parse('http://$host:$port/server/database/item'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'namespace': 'lane_data', 'key': e.key, 'value': e.value}));
      }
      // Bridge 1.12.0 wrote lane1..lane4; remove them so Orca sees each tool once.
      if (_laneDataSent == null) {
        for (var i = 1; i <= 8; i++) {
          await _client.delete(Uri.parse('http://$host:$port/server/database/item?namespace=lane_data&key=lane$i'));
        }
      }
      _laneDataSent = body;
    } catch (e) {
      log('lane_data not written: $e');
    }
  }

  /// Rules come from Moonraker's database (the app edits them). Reloaded each
  /// minute, when daily ones are due too.
  Future<void> _rulesLoop() async {
    // Keep the alert history across bridge restarts: load what's saved, then append.
    try {
      final r = await _client.get(Uri.parse('http://$host:$port/server/database/item?namespace=printer_hub&key=alerts_log'));
      final saved = r.statusCode == 200 ? (jsonDecode(r.body)['result']?['value'] as List?) ?? const [] : const [];
      _alertLog.insertAll(0, [for (final a in saved) if (a is Map) Map<String, Object>.from(a)]);
      if (_alertLog.length > 100) _alertLog.removeRange(0, _alertLog.length - 100);
    } catch (_) {}
    while (true) {
      try {
        final r = await _client.get(Uri.parse(
            'http://$host:$port/server/database/item?namespace=printer_hub&key=rules'));
        _rules = r.statusCode == 200
            ? List<Map>.from((jsonDecode(r.body)['result']?['value'] as List?) ?? const [])
            : const [];
      } catch (_) {}
      try {
        final r = await _client.get(Uri.parse(
            'http://$host:$port/server/database/item?namespace=printer_hub&key=snooze'));
        _snoozeUntil = r.statusCode == 200 ? ((jsonDecode(r.body)['result']?['value'] as num?)?.toInt() ?? 0) : 0;
      } catch (_) {}
      final now = DateTime.now();
      if (_state != 'printing' && _state != 'paused') _queuedIdle = await _queueSize();
      // "Idle for N minutes" rules, once per idle stretch (e.g. a smart plug off).
      if (_state == 'printing' || _state == 'paused') {
        _idleSince = null;
        _idleRan.clear();
      } else {
        _idleSince ??= now;
        final idle = now.difference(_idleSince!).inMinutes;
        await _runRules((r) =>
            r['on'] == 'idle' &&
            (int.tryParse('${r['at']}') ?? 0) > 0 &&
            idle >= int.parse('${r['at']}') &&
            _idleRan.add('${r['at']} ${r['do']}'));
      }
      if (_state == 'paused' && _pausedAt != null && pauseRepeat > 0) {
        final m = now.difference(_pausedAt!).inMinutes;
        if (m > 0 && m % pauseRepeat == 0) {
          await send('$_title: still paused', 'Paused for $m minutes. Resume or cancel it.', tags: ['pause_button'], priority: 4);
        }
      }
      final hhmm = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final day = '${now.year}-${now.month}-${now.day}';
      await _runRules((r) => r['on'] == 'time' && r['at'] == hhmm && _ranToday.add('$day ${r['at']} ${r['do']}'));
      if (summaryAt == hhmm && _ranToday.add('$day summary')) unawaited(_summary(now));
      if (weeklyDue(weeklyAt, now) && _ranToday.add('$day weekly')) unawaited(_summary(now, days: 7));
      final mins = _started == null ? 0 : now.difference(_started!).inMinutes;
      if (_state == 'printing' && mins > 0) {
        await _runRules((r) => r['on'] == 'interval' && (int.tryParse('${r['at']}') ?? 0) > 0 &&
            mins % int.parse('${r['at']}') == 0);
      }
      if (_alertLogDirty) {
        _alertLogDirty = false;
        try {
          await _client.post(Uri.parse('http://$host:$port/server/database/item'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'namespace': 'printer_hub', 'key': 'alerts_log', 'value': _alertLog}));
        } catch (_) {}
      }
      if (_lastRanDirty) {
        _lastRanDirty = false;
        try {
          await _client.post(Uri.parse('http://$host:$port/server/database/item'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'namespace': 'printer_hub', 'key': 'rules_ran', 'value': _lastRan}));
        } catch (_) {}
      }
      await Future.delayed(Duration(seconds: 60 - DateTime.now().second));
    }
  }

  Future<int> _queueSize() async {
    try {
      final r = await _client.get(Uri.parse('http://$host:$port/server/job_queue/status'));
      return ((jsonDecode(r.body)['result']?['queued_jobs'] as List?) ?? const []).length;
    } catch (_) {
      return 0; // no job queue on this printer
    }
  }

  /// "Benchy.gcode, done about 18:40" from the file's slicer estimate.
  Future<String> _startedText(String file) async {
    try {
      final r = await _client.get(Uri.parse('http://$host:$port/server/files/metadata?filename='
          '${Uri.encodeQueryComponent('${_stats['filename'] ?? ''}')}'));
      final est = (jsonDecode(r.body)['result']?['estimated_time'] as num?)?.toDouble();
      _estimate = est;
      if (est == null || est <= 0) return file;
      final at = DateTime.now().add(Duration(seconds: est.round()));
      return '$file, done about ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return file;
    }
  }

  /// Today's prints, hours and failures, sent at [summaryAt].
  Future<void> _summary(DateTime now, {int days = 1}) async {
    try {
      final since = DateTime(now.year, now.month, now.day - (days - 1)).millisecondsSinceEpoch / 1000;
      final r = await _client.get(Uri.parse('http://$host:$port/server/history/list?limit=100&since=$since'));
      final jobs = (jsonDecode(r.body)['result']?['jobs'] as List?) ?? const [];
      await send('$_title: ${days == 1 ? 'today' : 'this week'}',
          summaryText(jobs).replaceFirst('No prints today.', days == 1 ? 'No prints today.' : 'No prints this week.'),
          tags: ['bar_chart'], priority: 2);
    } catch (e) {
      log('Daily summary skipped: $e');
    }
  }

  /// The DragonBreath named in the printer's config, spoken to directly.
  Future<void> _heaterCommand(String name, Map<String, dynamic> fields) async {
    try {
      final cfg = jsonDecode((await _client.get(
              Uri.parse('http://$host:$port/printer/objects/query?configfile=settings')))
          .body)['result']?['status']?['configfile']?['settings']?['dragonbreath'];
      if (cfg == null) return log('Rule: no DragonBreath on this printer');
      final h = {'Content-Type': 'application/json', 'X-DragonBreath-Auth': '${cfg['token'] ?? 'web'}'};
      final base = 'http://${cfg['host']}/api/v2';
      final rev = jsonDecode((await _client.get(Uri.parse('$base/state'), headers: h)).body)['state_revision'];
      final r = await _client.post(Uri.parse('$base/command'),
          headers: h,
          body: jsonEncode({
            'api_version': 2,
            'request_id': 'bridge-${DateTime.now().microsecondsSinceEpoch}',
            'expected_revision': rev,
            'actor': {'kind': 'web', 'id': 'printer-hub-bridge'},
            'command': {'name': name, ...fields},
          }));
      log('Rule: heater $name -> ${jsonDecode(r.body)['ok'] == true ? 'ok' : r.body}');
    } catch (e) {
      log('Rule: heater $name failed: $e');
    }
  }

  /// Spoolman spools linked to U1 lanes that are running out.
  Future<void> _checkSpools() async {
    try {
      Future<dynamic> get(String p) async =>
          jsonDecode((await _client.get(Uri.parse('http://$host:$port$p'))).body)['result'];
      final lanes = [
        for (final o in (await get('/printer/objects/list'))['objects'] as List)
          if ('$o'.startsWith('AFC_lane ')) '$o',
      ];
      if (lanes.isEmpty) return;
      final st = (await get('/printer/objects/query?${lanes.map(Uri.encodeQueryComponent).join('&')}'))['status'] as Map;
      for (final e in st.entries) {
        final id = (e.value as Map)['spool_id'];
        if (id is! num || id <= 0) continue;
        final r = await _client.post(Uri.parse('http://$host:$port/server/spoolman/proxy'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'request_method': 'GET', 'path': '/v1/spool/$id', 'use_v2_response': true}));
        final spool = jsonDecode(r.body)['result']?['response'];
        final left = (spool?['remaining_weight'] as num?)?.toDouble();
        if (left == null || left >= spoolLow) continue;
        final prev = _spoolWarned[id.toInt()];
        if (prev != null && DateTime.now().difference(prev).inHours < 24) continue;
        _spoolWarned[id.toInt()] = DateTime.now();
        final lane = (e.value as Map)['map'] ?? '${e.key}'.substring(9);
        await send('$_title: spool in $lane is low', '${left.round()} g left on ${spool['filament']?['name'] ?? 'the spool'}.',
            tags: ['warning']);
      }
    } catch (_) {} // no Spoolman or no lanes: nothing to check
  }

  Future<void> _runRules(bool Function(Map) match) async {
    for (final r in _rules.where((r) => r['off'] != true).where((r) => ruleAllowed(r, DateTime.now())).where(match)) {
      counters['rules'] = counters['rules']! + 1;
      _lastRan[ruleSig(r)] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _lastRanDirty = true;
      final g = '${r['do'] ?? ''}'.trim();
      if (g.isEmpty) continue;
      if (g == '@keep') {
        await _keep('t${DateTime.now().millisecondsSinceEpoch ~/ 60000}');
        continue;
      }
      if (g.startsWith('@dry')) {
        final p = g.split(' ');
        await _heaterCommand('drying_start', {
          'target_c': int.tryParse(p.elementAtOrNull(1) ?? '') ?? 55,
          'hours': int.tryParse(p.elementAtOrNull(2) ?? '') ?? 6,
        });
        continue;
      }
      if (g.startsWith('@webhook')) {
        final u = webhookUri(g);
        if (u == null) {
          log('Rule: bad webhook "$g" (needs http:// or https://)');
          continue;
        }
        try {
          final res = await _client
              .post(u,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'printer': _title,
                    'event': r['on'],
                    'state': _state,
                    'file': file,
                    'progress': (_progress * 100).round(),
                  }))
              .timeout(const Duration(seconds: 15));
          log('Rule webhook -> HTTP ${res.statusCode}');
        } catch (e) {
          log('Rule webhook failed: $e');
        }
        continue;
      }
      if (g.startsWith('@power')) {
        // "@power <device> on|off": a Moonraker power device (smart plug, relay).
        final parts = g.split(RegExp(r'\s+'));
        if (parts.length != 3 || !const {'on', 'off'}.contains(parts[2])) {
          log('Rule: bad power action "$g"');
          continue;
        }
        try {
          await _client.post(Uri.parse('http://$host:$port/machine/device_power/device'
              '?device=${Uri.encodeQueryComponent(parts[1])}&action=${parts[2]}'));
          log('Rule: power ${parts[1]} ${parts[2]}');
        } catch (e) {
          log('Rule power failed: $e');
        }
        continue;
      }
      if (g.startsWith('@notify')) {
        final text = g.substring(7).trim();
        await send('$_title: ${text.isEmpty ? 'rule' : text}', file.isEmpty ? 'From your rule' : file, tags: ['bell']);
        continue;
      }
      if (g == '@picture') {
        final file = '${_stats['filename'] ?? ''}'.split('/').last;
        final pct = _state == 'printing' ? ' (${(_progress * 100).round()}%)' : '';
        await send('$_title: picture$pct', file.isEmpty ? 'From your rule' : file,
            tags: ['camera'], picture: true);
        continue;
      }
      try {
        await _client.post(Uri.parse('http://$host:$port/printer/gcode/script'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'script': g}));
        log('Rule ran: ${r['on']}${r['at'] == null ? '' : ' ${r['at']}'} -> $g');
      } catch (e) {
        log('Rule failed ($g): $e');
      }
    }
  }

  /// Grabs a camera frame and keeps it on the printer (hidden folder in
  /// gcodes) so the app's history can show it, at home and from away.
  /// ponytail: never pruned; ~60 KB x 2 per print. Add cleanup if it adds up.
  Future<List<int>?> _keep(String kind) async {
    if (camera == null) return null;
    try {
      final jpeg = await camera!.frame();
      final file = '${_stats['filename'] ?? ''}'.split('/').last;
      final name = snapshotName(file, _started ?? DateTime.now(), kind);
      final req = http.MultipartRequest('POST', Uri.parse('http://$host:$port/server/files/upload'))
        ..fields['root'] = 'gcodes'
        ..fields['path'] = '.printer-hub/snapshots'
        ..files.add(http.MultipartFile.fromBytes('file', jpeg, filename: name));
      final r = await _client.send(req).timeout(const Duration(seconds: 30));
      if (r.statusCode >= 300) log('Snapshot not saved (HTTP ${r.statusCode})');
      return jpeg;
    } catch (e) {
      log('No snapshot ($e)');
      return null;
    }
  }

  /// Deletes old snapshots (see [snapshotsToPrune]); run after each print.
  Future<void> _prune() async {
    const dir = '.printer-hub/snapshots';
    try {
      final r = await _client.get(Uri.parse('http://$host:$port/server/files/directory?path=gcodes/$dir'));
      final files = [for (final f in (jsonDecode(r.body)['result']?['files'] as List? ?? const [])) '${f['filename']}'];
      final old = snapshotsToPrune(files, DateTime.now());
      for (final n in old) {
        await _client.delete(Uri.parse('http://$host:$port/server/files/gcodes/$dir/${Uri.encodeComponent(n)}'));
      }
      if (old.isNotEmpty) log('Removed ${old.length} old snapshots');
    } catch (e) {
      log('Snapshot cleanup skipped: $e');
    }
  }

  /// Every 30 s of a print: one camera frame to the detector. The smoothed
  /// score goes to Moonraker's database (`printer_hub/failure_watch`, the
  /// app shows it); a sustained high one alerts once per print, and pauses
  /// when the app's "Pause if seen" (`printer_hub/failure`) is on.
  Future<void> _failureLoop() async {
    var down = false;
    while (true) {
      await Future.delayed(const Duration(seconds: 30));
      if (_state != 'printing') continue;
      final Uint8List jpeg;
      final double score;
      try {
        jpeg = await camera!.frame(quiet: true);
        final r = await _client
            .post(detector!.resolve('/detect'), headers: {'Content-Type': 'image/jpeg'}, body: jpeg)
            .timeout(const Duration(seconds: 30));
        score = ((jsonDecode(r.body) as Map)['score'] as num).toDouble();
        if (down) log('Failure detector: back');
        down = false;
      } catch (e) {
        if (!down) log('Failure detector not reachable ($e); trying every 30 s');
        down = true;
        continue;
      }
      var paused = false;
      if (_failure.add(score) && _sent.add('spaghetti')) {
        log('Failure detector: possible failure (score ${_failure.level.toStringAsFixed(2)})');
        Map settings = const {};
        try {
          final r = await _client.get(Uri.parse(
              'http://$host:$port/server/database/item?namespace=printer_hub&key=failure'));
          if (r.statusCode == 200) settings = (jsonDecode(r.body)['result']?['value'] as Map?) ?? const {};
        } catch (_) {}
        if (settings['pause'] == true) {
          try {
            await _client.post(Uri.parse('http://$host:$port/printer/print/pause'));
            paused = true;
          } catch (e) {
            log('Pause failed: $e');
          }
        }
        await send('$_title: possible print failure',
            paused ? 'Looks like spaghetti. The print is paused; check the camera.' : 'Looks like spaghetti. Check the camera.',
            tags: ['rotating_light'], priority: 5, jpeg: jpeg);
      }
      try {
        await _client.post(Uri.parse('http://$host:$port/server/database/item'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'namespace': 'printer_hub',
              'key': 'failure_watch',
              'value': {
                'level': double.parse(_failure.level.toStringAsFixed(3)),
                'score': score,
                'failing': _sent.contains('spaghetti'),
                'file': '${_stats['filename'] ?? ''}',
                'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              },
            }));
      } catch (_) {}
    }
  }

  bool get _filterOn => _sent.contains('filter_on');

  Future<void> _setFilter(bool on) async {
    try {
      await _client.post(Uri.parse('http://$host:$port/printer/gcode/script'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'script': 'SET_PIN PIN=dragonbreath_filter VALUE=${on ? 1 : 0}'}));
      on ? _sent.add('filter_on') : _sent.remove('filter_on');
      log('Heater filter ${on ? 'on' : 'off'}');
    } catch (e) {
      log('Heater filter not switched: $e');
    }
  }

  /// Runs the DragonBreath filter for fume-heavy materials.
  Future<void> _filterFor(String file) async {
    try {
      final r = await _client.get(Uri.parse('http://$host:$port/server/files/metadata')
          .replace(queryParameters: {'filename': file}));
      final type = '${jsonDecode(r.body)['result']?['filament_type'] ?? ''}'.toUpperCase();
      if (fumeMaterial(type)) {
        _filterOff?.cancel();
        await _setFilter(true);
      }
    } catch (_) {}
  }
}

/// Smooths the detector's per-frame scores (sum of failure-box
/// confidences, as Obico computes it) so one odd frame doesn't alert:
/// failing once the moving average reaches [threshold]. With frames 30 s
/// apart, a clear spaghetti (score ~3) trips it on the second frame, about a minute in.
/// ponytail: plain EWMA; Obico also compares short and long rolling means.
/// FAILURE_THRESHOLD is the knob if a camera gives false alarms.
class FailureWatch {
  final double threshold;
  double level = 0;
  FailureWatch({this.threshold = 0.8});
  bool add(double score) => (level = level * 0.8 + score * 0.2) >= threshold;
  void reset() => level = 0;
}

/// Set at build time (dart compile exe -DVERSION=1.23.0).
const kBridgeVersion = String.fromEnvironment('VERSION', defaultValue: 'dev');

/// Snapshot files to delete: older than [maxAge] (by the print start in the
/// name), or past the newest [keep]. Names without a time are left alone.
List<String> snapshotsToPrune(Iterable<String> names, DateTime now,
    {int keep = 3000, Duration maxAge = const Duration(days: 180)}) {
  final dated = <(String, int)>[
    for (final n in names)
      if (RegExp(r'__(\d+)__').firstMatch(n) case final m?) (n, int.parse(m[1]!)),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final oldest = now.subtract(maxAge).millisecondsSinceEpoch ~/ 1000;
  return [
    for (var i = 0; i < dated.length; i++)
      if (i >= keep || dated[i].$2 < oldest) dated[i].$1,
  ];
}

/// "cube.gcode" started at t, kind "first" -> "cube__1794164593__first.jpg".
/// The app matches it to the history job by name and start time.
String snapshotName(String gcode, DateTime started, String kind) {
  final stem = gcode.replaceAll(RegExp(r'\.gcode$', caseSensitive: false), '').replaceAll(RegExp(r'[^\w.-]+'), '_');
  return '${stem}__${started.millisecondsSinceEpoch ~/ 1000}__$kind.jpg';
}

/// A rule's optional window: `days` (1 = Mon … 7 = Sun) and `from`/`to`
/// ("22:00"–"07:00" wraps past midnight). Rules without them always run.
bool ruleAllowed(Map r, DateTime now) {
  final days = r['days'];
  if (days is List && days.isNotEmpty && !days.map((d) => '$d').contains('${now.weekday}')) return false;
  final from = '${r['from'] ?? ''}', to = '${r['to'] ?? ''}';
  int? mins(String s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
    return m == null ? null : int.parse(m[1]!) * 60 + int.parse(m[2]!);
  }
  final a = mins(from), b = mins(to);
  if (a == null || b == null) return true;
  final t = now.hour * 60 + now.minute;
  return a <= b ? t >= a && t < b : t >= a || t < b;
}

/// Identifies a rule across edits of other rules (when + what).
String ruleSig(Map r) => '${r['on']}|${r['at'] ?? ''}|${r['do']}';

/// "@webhook https://…" -> its URL; only http(s).
Uri? webhookUri(String action) {
  final u = Uri.tryParse(action.replaceFirst('@webhook', '').trim());
  return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty ? u : null;
}

/// MQTT 3.1.1 "remaining length" bytes.
List<int> mqttLength(int n) {
  final out = <int>[];
  do {
    var b = n % 128;
    n ~/= 128;
    if (n > 0) b |= 0x80;
    out.add(b);
  } while (n > 0);
  return out;
}

List<int> _mqttString(String s) {
  final b = utf8.encode(s);
  return [b.length >> 8, b.length & 0xFF, ...b];
}

/// CONNECT packet (clean session, 60 s keep-alive, optional user/password).
List<int> mqttConnect(String clientId, {String? user, String? password}) {
  final flags = 0x02 | (user != null ? 0x80 : 0) | (password != null ? 0x40 : 0);
  final body = [
    ..._mqttString('MQTT'), 4, flags, 0, 60, //
    ..._mqttString(clientId),
    if (user != null) ..._mqttString(user),
    if (password != null) ..._mqttString(password),
  ];
  return [0x10, ...mqttLength(body.length), ...body];
}

/// PUBLISH packet, QoS 0, optionally retained.
List<int> mqttPublish(String topic, String payload, {bool retain = false}) {
  final body = [..._mqttString(topic), ...utf8.encode(payload)];
  return [0x30 | (retain ? 1 : 0), ...mqttLength(body.length), ...body];
}

/// Publishes printer status to an MQTT broker (Home Assistant's Mosquitto),
/// with Home Assistant discovery so the sensors appear by themselves.
/// ponytail: QoS 0, no subscriptions; reconnects on the next publish if the
/// broker went away. Add QoS 1 if status ever needs to be guaranteed.
class MqttStatus {
  final Uri url; // mqtt://user:pass@host:1883
  final String name;
  Socket? _s;
  bool _announced = false;
  Timer? _ping;
  MqttStatus(this.url, this.name);

  String get slug => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  String get base => 'printerhub/$slug';

  Future<Socket?> _socket() async {
    if (_s != null) return _s;
    try {
      final s = await Socket.connect(url.host, url.hasPort ? url.port : 1883, timeout: const Duration(seconds: 10));
      final info = url.userInfo.split(':');
      s.add(mqttConnect('printerhub-$slug-${DateTime.now().millisecondsSinceEpoch % 100000}',
          user: info.first.isEmpty ? null : Uri.decodeComponent(info.first),
          password: info.length > 1 ? Uri.decodeComponent(info[1]) : null));
      s.listen((_) {}, onDone: _drop, onError: (_) => _drop(), cancelOnError: true);
      _ping = Timer.periodic(const Duration(seconds: 45), (_) => _s?.add(const [0xC0, 0])); // PINGREQ
      _s = s;
      _announced = false;
      return s;
    } catch (e) {
      log('MQTT: no broker at ${url.host} ($e)');
      return null;
    }
  }

  void _drop() {
    _ping?.cancel();
    _s?.destroy();
    _s = null;
  }

  /// Home Assistant discovery: one sensor per value, all on one device.
  void _announce(Socket s) {
    final device = {'identifiers': ['printerhub_$slug'], 'name': name, 'manufacturer': 'Printer Hub'};
    for (final (key, label, unit, cls) in const [
      ('state', 'State', null, null),
      ('progress', 'Progress', '%', null),
      ('eta_min', 'Time left', 'min', 'duration'),
      ('nozzle', 'Nozzle', '°C', 'temperature'),
      ('bed', 'Bed', '°C', 'temperature'),
      ('file', 'File', null, null),
      ('layer', 'Layer', null, null),
      ('chamber', 'Chamber', '°C', 'temperature'),
      ('filament_m', 'Filament used', 'm', 'distance'),
    ]) {
      s.add(mqttPublish(
          'homeassistant/sensor/printerhub_${slug}_$key/config',
          jsonEncode({
            'name': label,
            'unique_id': 'printerhub_${slug}_$key',
            'state_topic': '$base/state',
            'value_template': '{{ value_json.$key }}',
            'unit_of_measurement': ?unit,
            'device_class': ?cls,
            'device': device,
          }),
          retain: true));
    }
    // On while a print runs (or is paused), for automations.
    s.add(mqttPublish(
        'homeassistant/binary_sensor/printerhub_${slug}_printing/config',
        jsonEncode({
          'name': 'Printing',
          'unique_id': 'printerhub_${slug}_printing',
          'state_topic': '$base/state',
          'value_template': "{{ 'ON' if value_json.state in ['printing', 'paused'] else 'OFF' }}",
          'device_class': 'running',
          'device': device,
        }),
        retain: true));
    _announced = true;
  }

  Future<void> publish(Map<String, Object?> state) async {
    final s = await _socket();
    if (s == null) return;
    try {
      if (!_announced) _announce(s);
      s.add(mqttPublish('$base/state', jsonEncode(state), retain: true));
    } catch (e) {
      _drop();
    }
  }
}

/// printerhub://printer/<name>: opens that printer in the app (iPhone, Mac).
String openLink(String printer) => 'printerhub://printer/${Uri.encodeComponent(printer)}';

/// "Benchy.gcode · 1h 12m · 14.2 m of filament".
String finishedText(String file, Map stats) {
  final secs = (stats['print_duration'] as num?)?.toDouble() ?? 0;
  final mm = (stats['filament_used'] as num?)?.toDouble() ?? 0;
  final h = secs ~/ 3600, m = (secs % 3600) ~/ 60;
  return [
    file,
    if (secs > 0) h > 0 ? '${h}h ${m}m' : '${m}m',
    if (mm > 0) '${(mm / 1000).toStringAsFixed(1)} m of filament',
  ].join(' · ');
}

/// "Sun 20:00" matches Sunday at 20:00.
bool weeklyDue(String spec, DateTime now) {
  final m = RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(\d{1,2}):(\d{2})$', caseSensitive: false).firstMatch(spec.trim());
  if (m == null) return false;
  const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  return days.indexOf(m[1]!.toLowerCase()) + 1 == now.weekday && int.parse(m[2]!) == now.hour && int.parse(m[3]!) == now.minute;
}

/// The print has run [pct]% longer than the slicer's estimate.
bool overran(double elapsed, double? estimate, int pct) =>
    estimate != null && estimate > 600 && elapsed > estimate * (1 + pct / 100);

/// A heater with a target that is still more than [margin] below it.
bool stillHeating(double? temp, double? target, {double margin = 5}) =>
    temp != null && target != null && target > 0 && temp < target - margin;

/// The chamber is within 1°C of a set target.
bool chamberReady(double? temp, double? target) =>
    temp != null && target != null && target > 0 && temp >= target - 1;

/// One line for the daily summary from Moonraker history jobs.
String summaryText(List jobs) {
  if (jobs.isEmpty) return 'No prints today.';
  final ok = jobs.where((j) => j['status'] == 'completed').length;
  final failed = jobs.where((j) => j['status'] == 'error').length;
  final secs = jobs.fold<double>(0, (a, j) => a + ((j['print_duration'] as num?) ?? 0));
  final h = secs ~/ 3600, m = (secs % 3600) ~/ 60;
  return '${jobs.length} prints ($ok finished${failed > 0 ? ', $failed failed' : ''}), ${h}h ${m}m printing.';
}

/// Prometheus text for the status endpoint.
String metricsText(Map<String, num> values) => [
      for (final e in values.entries) ...[
        '# TYPE printer_hub_${e.key} gauge',
        'printer_hub_${e.key} ${e.value}',
      ],
    ].join('\n') + '\n';

/// A small read-only status page on the home network (STATUS_PORT):
/// `/` (HTML), `/status.json` and `/metrics` (Prometheus). It never
/// controls the printer.
/// Moonraker history jobs as CSV (newest first).
String historyCsv(List jobs) {
  String cell(Object? v) {
    final s = '${v ?? ''}';
    return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }
  return [
    'file,status,started,duration_s,filament_mm',
    for (final j in jobs)
      [
        j['filename'],
        j['status'],
        DateTime.fromMillisecondsSinceEpoch((((j['start_time'] as num?) ?? 0) * 1000).round()).toIso8601String(),
        ((j['print_duration'] as num?) ?? 0).round(),
        ((j['filament_used'] as num?) ?? 0).round(),
      ].map(cell).join(','),
  ].join('\n');
}

Future<void> serveStatus(int port, String printer, int moonraker, Alerts? alerts, {CameraFeed? camera}) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  log('Status page on port $port (/, /status.json, /metrics)');
  await for (final req in server) {
    final res = req.response;
    final a = alerts;
    final st = {
      'version': kBridgeVersion,
      'printer': '$printer:$moonraker',
      'online': a?.online,
      'state': a?.state,
      'file': a?.file,
      'progress': a == null ? null : (a.progress * 100).round(),
      'nozzle': a?.nozzle,
      'bed': a?.bedTemp,
      'chamber': a?.chamber,
      'counters': a?.counters,
    };
    if (req.method != 'GET') {
      res.statusCode = HttpStatus.methodNotAllowed;
    } else if (req.uri.path == '/status.json') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(st));
    } else if (req.uri.path == '/history.csv') {
      try {
        final r = await http.get(Uri.parse('http://$printer:$moonraker/server/history/list?limit=1000&order=desc'));
        final jobs = (jsonDecode(r.body)['result']?['jobs'] as List?) ?? const [];
        res.headers
          ..contentType = ContentType('text', 'csv', charset: 'utf-8')
          ..set('content-disposition', 'attachment; filename="print-history.csv"');
        res.write(historyCsv(jobs));
      } catch (e) {
        res.statusCode = HttpStatus.badGateway;
        res.write('Printer not reachable: $e');
      }
    } else if (req.uri.path == '/snapshot.jpg') {
      // A still for Home Assistant's generic camera (or a browser).
      if (camera == null) {
        res.statusCode = HttpStatus.notFound;
        res.write('No CAMERA_URL set');
      } else {
        try {
          final jpeg = await camera.frame(quiet: true);
          res.headers
            ..contentType = ContentType('image', 'jpeg')
            ..set('cache-control', 'no-store');
          res.add(jpeg);
        } catch (e) {
          res.statusCode = HttpStatus.badGateway;
          res.write('Camera not reachable: $e');
        }
      }
    } else if (req.uri.path == '/log') {
      res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      res.write(recentLog.join('\n'));
    } else if (req.uri.path == '/metrics') {
      res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      res.write(metricsText({
        'up': 1,
        'printer_online': a?.online == true ? 1 : 0,
        'printing': a?.state == 'printing' ? 1 : 0,
        'progress_ratio': a?.progress ?? 0,
        if (a?.nozzle != null) 'nozzle_celsius': a!.nozzle!,
        if (a?.bedTemp != null) 'bed_celsius': a!.bedTemp!,
        if (a?.chamber != null) 'chamber_celsius': a!.chamber!,
        for (final e in (a?.counters ?? const <String, int>{}).entries) '${e.key}_total': e.value,
      }));
    } else if (req.uri.path == '/') {
      res.headers.contentType = ContentType.html;
      String esc(Object? v) => const HtmlEscape().convert('${v ?? '—'}');
      res.write('<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">'
          '<meta http-equiv=refresh content=10><title>Printer Hub bridge</title>'
          '<style>body{font:15px system-ui;margin:24px;background:#0b0e13;color:#e9edf3}td{padding:4px 12px 4px 0}'
          'h1{font-size:20px}</style><h1>Printer Hub bridge ${esc(kBridgeVersion)}</h1><table>'
          '${[for (final e in st.entries) if (e.key != 'counters') '<tr><td>${esc(e.key)}<td>${esc(e.value)}'].join()}'
          '${[for (final e in (a?.counters ?? const <String, int>{}).entries) '<tr><td>${esc(e.key)}<td>${esc(e.value)}'].join()}'
          '</table>'
          '${camera == null ? '' : '<p><img src="/snapshot.jpg" style="max-width:100%;border-radius:12px" alt="camera"></p>'}'
          '<p><a style="color:#2ee6a6" href="/history.csv">history.csv</a> · <a style="color:#2ee6a6" href="/metrics">metrics</a> · '
          '<a style="color:#2ee6a6" href="/status.json">status.json</a> · <a style="color:#2ee6a6" href="/log">log</a></p>');
    } else {
      res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }
}

/// "23-7" -> (23, 7). Null when unset or malformed.
(int, int)? parseQuietHours(String? v) {
  final m = RegExp(r'^\s*(\d{1,2})\s*-\s*(\d{1,2})\s*$').firstMatch(v ?? '');
  if (m == null) return null;
  final a = int.parse(m[1]!), b = int.parse(m[2]!);
  return a < 24 && b < 24 ? (a, b) : null;
}

bool inQuietHours((int, int)? q, int hour) {
  if (q == null || q.$1 == q.$2) return false;
  final (a, b) = q;
  return a < b ? hour >= a && hour < b : hour >= a || hour < b;
}

/// ABS, ASA, PC and nylon give off fumes worth filtering.
bool fumeMaterial(String type) => RegExp(r'\b(ABS|ASA|PC|PA\d*|NYLON)\b').hasMatch(type.toUpperCase());

void _printPairing(PairInfo pair) {
  final code = pair.encode();
  final qr = QrImage(QrCode.fromData(data: code, errorCorrectLevel: QrErrorCorrectLevel.L));
  final n = qr.moduleCount;
  bool dark(int r, int c) => r >= 0 && c >= 0 && r < n && c < n && qr.isDark(r, c);
  final out = StringBuffer('\nScan in Printer Hub (Add/Edit printer → Remote access code),\n'
      'or copy the code below. Keep it private: it controls your printer.\n\n');
  // Two QR rows per text line, dark modules on a light background.
  for (var r = -2; r < n + 2; r += 2) {
    out.write('\x1B[30;47m  ');
    for (var c = -2; c < n + 2; c++) {
      final top = dark(r, c), bottom = dark(r + 1, c);
      out.write(top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' ');
    }
    out.writeln('  \x1B[0m');
  }
  out.writeln('\n$code\n');
  final alerts = pair.alerts;
  if (alerts != null) {
    out.writeln('Alerts with the app closed: install the free "ntfy" app and subscribe to\n'
        '  $alerts\n(Printer Hub shows this too, under Tools → Away from home.)\n');
  }
  stdout.write(out);
}

/// One phone connected through the relay, with its own Moonraker socket.
class _Session {
  WebSocket? moonraker;
  final pending = <String>[];
  final uploads = <int, BytesBuilder>{};
  bool closed = false;

  void close() {
    closed = true;
    moonraker?.close();
  }
}

class Bridge {
  final PairInfo pair;
  final LinkCrypto crypto;
  final String host;
  final int port;
  final CameraFeed? camera;

  /// The slicer container next to the bridge (COMPOSE_PROFILES=slicer).
  final int slicerPort;

  IOWebSocketChannel? _relay;
  final _sessions = <String, _Session>{};
  final _client = http.Client();
  Future<void> _recvChain = Future.value();
  Future<void> _sendChain = Future.value();

  Bridge(this.pair, this.crypto, this.host, this.port, {this.camera, this.slicerPort = 7070});

  Future<void> run() async {
    var backoff = 1;
    while (true) {
      final started = DateTime.now();
      try {
        await _connectOnce();
      } catch (e) {
        log('Relay: $e');
      }
      if (DateTime.now().difference(started).inMinutes >= 1) backoff = 1;
      log('Reconnecting in ${backoff}s');
      await Future.delayed(Duration(seconds: backoff));
      backoff = math.min(backoff * 2, 60);
    }
  }

  Future<void> _connectOnce() async {
    final ch = IOWebSocketChannel.connect(pair.socketUri('bridge', crypto.relayToken),
        connectTimeout: const Duration(seconds: 15));
    await ch.ready;
    _relay = ch;
    log('Connected to relay. Waiting for phones.');
    final ping = Timer.periodic(const Duration(seconds: 30), (_) => ch.sink.add('ping'));
    try {
      await for (final raw in ch.stream) {
        if (raw is! String || raw == 'pong') continue;
        final Map env;
        try {
          env = jsonDecode(raw) as Map;
        } catch (_) {
          continue;
        }
        final c = '${env['c']}';
        if (env['open'] == true) {
          _open(c);
        } else if (env['close'] == true) {
          _sessions.remove(c)?.close();
          log('Phone $c disconnected');
        } else if (env['p'] is String) {
          final frame = env['p'] as String;
          // Decrypt in arrival order; long HTTP transfers run alongside.
          _recvChain = _recvChain.then((_) => _onFrame(c, frame));
        }
      }
    } finally {
      ping.cancel();
      _relay = null;
      for (final s in _sessions.values) {
        s.close();
      }
      _sessions.clear();
    }
    throw 'connection closed (${ch.closeCode ?? '-'} ${ch.closeReason ?? ''})';
  }

  Future<void> _send(String c, Map<String, dynamic> msg) =>
      _sendChain = _sendChain.then((_) async {
        final relay = _relay;
        if (relay == null) return;
        relay.sink.add(jsonEncode({'c': c, 'p': await crypto.seal(msg)}));
      });

  void _open(String c) {
    _sessions.remove(c)?.close();
    final s = _Session();
    _sessions[c] = s;
    log('Phone $c connected');
    _connectMoonraker(c, s);
  }

  Future<void> _connectMoonraker(String c, _Session s) async {
    try {
      final ws = await WebSocket.connect('ws://$host:$port/websocket')
          .timeout(const Duration(seconds: 10));
      if (s.closed) {
        ws.close();
        return;
      }
      s.moonraker = ws;
      for (final p in s.pending) {
        ws.add(p);
      }
      s.pending.clear();
      ws.listen(
        (m) => _send(c, {'t': 'ws', 'd': '$m'}),
        onDone: () {
          if (!s.closed) _send(c, {'t': 'ws_closed', 'e': 'Printer closed the connection'});
        },
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (e) {
      log('Printer unreachable: $e');
      _send(c, {'t': 'ws_closed', 'e': 'The bridge cannot reach the printer at $host:$port'});
    }
  }

  Future<void> _onFrame(String c, String frame) async {
    final Map<String, dynamic> m;
    try {
      m = await crypto.open(frame);
    } catch (e) {
      log('Rejected a frame from phone $c ($e)');
      return;
    }
    final s = _sessions[c];
    if (s == null) return;
    switch (m['t']) {
      case 'ws':
        final d = '${m['d']}';
        final ws = s.moonraker;
        ws == null ? s.pending.add(d) : ws.add(d);
      case 'http':
        final id = m['id'] as int;
        final body = s.uploads.putIfAbsent(id, BytesBuilder.new);
        if (m['b'] is String) body.add(unb64(m['b'] as String));
        if (m['more'] == true) return;
        s.uploads.remove(id);
        unawaited(_http(c, m, body.takeBytes()));
      case 'cam':
        unawaited(_camera(c, m['id']));
    }
  }

  /// One camera frame, end-to-end encrypted like everything else.
  Future<void> _camera(String c, Object? id) async {
    final cam = camera;
    if (cam == null) {
      return _reply(c, id, 404, utf8.encode('This home bridge has no camera set up (CAMERA_URL)'));
    }
    try {
      await _reply(c, id, 200, await cam.frame(), type: 'image/jpeg');
    } catch (e) {
      await _reply(c, id, 503, utf8.encode('$e'));
    }
  }

  /// Sends a whole response body in relay-sized chunks.
  Future<void> _reply(String c, Object? id, int status, List<int> body, {String? type}) async {
    for (var i = 0; i == 0 || i < body.length; i += kChunkBytes) {
      final end = math.min(i + kChunkBytes, body.length);
      await _send(c, {
        't': 'res',
        'id': id,
        if (i == 0) 's': status,
        if (i == 0) 'h': {'content-type': ?type},
        'b': b64(body.sublist(i, end)),
        'more': end < body.length,
      });
    }
  }

  static const _forwardHeaders = {'range', 'content-type', 'x-api-key', 'accept'};

  (String, String)? _heater; // DragonBreath host and token, from the printer

  /// Where a relayed path goes: Moonraker, the U1's remote screen on port 80,
  /// the DragonBreath heater named in the printer's own [dragonbreath], or
  /// the slicer container on this machine. Never anywhere else.
  Future<(Uri, Map<String, String>)> target(String path) async {
    if (!path.startsWith('/') || path.startsWith('//')) throw const FormatException('bad path');
    if (path.startsWith('/slicer/')) {
      final uri = Uri.parse('http://127.0.0.1:$slicerPort$path');
      if (uri.host != '127.0.0.1' || uri.port != slicerPort) throw const FormatException('bad path');
      return (uri, const <String, String>{});
    }
    if (path.startsWith('/dragonbreath/')) {
      if (_heater == null) {
        final r = await _client.get(
            Uri.parse('http://$host:$port/printer/objects/query?configfile=settings'));
        final dynamic j = jsonDecode(r.body);
        final db = j['result']?['status']?['configfile']?['settings']?['dragonbreath'];
        if (db == null) throw const FormatException('no DragonBreath on this printer');
        _heater = ('${db['host']}', '${db['token'] ?? 'web'}');
      }
      final uri = Uri.parse('http://${_heater!.$1}${path.substring('/dragonbreath'.length)}');
      if (uri.host != _heater!.$1) throw const FormatException('bad path');
      return (uri, {'X-DragonBreath-Auth': _heater!.$2});
    }
    // The U1 extended firmware serves its remote screen on port 80 (nginx).
    final p = path.startsWith('/screen/') ? 80 : port;
    final uri = Uri.parse('http://$host:$p$path');
    if (uri.host != host || uri.port != p) throw const FormatException('bad path');
    return (uri, const <String, String>{});
  }

  /// Performs a request against Moonraker only (never any other host) and
  /// streams the reply back in chunks.
  Future<void> _http(String c, Map<String, dynamic> m, List<int> body) async {
    final id = m['id'];
    final path = '${m['p']}';
    if (bridgeOwn(path) case (final s, final type, final text)) {
      await _send(c, {'t': 'res', 'id': id, 's': s, 'h': {'content-type': type}, 'b': b64(utf8.encode(text)), 'more': false});
      return;
    }
    try {
      final (uri, extra) = await target(path);
      final req = http.Request('${m['m']}', uri)..bodyBytes = body;
      final headers = Map<String, dynamic>.from((m['h'] as Map?) ?? const {});
      headers.forEach((k, v) {
        if (_forwardHeaders.contains(k.toLowerCase())) req.headers[k] = '$v';
      });
      req.headers.addAll(extra);
      // Meshing a STEP file or orienting a big model can take minutes.
      final res = await _client
          .send(req)
          .timeout(path.startsWith('/slicer/') ? const Duration(minutes: 15) : const Duration(seconds: 60));
      final head = {
        if (res.headers['content-type'] != null) 'content-type': res.headers['content-type'],
      };
      var first = true;
      final buf = BytesBuilder(copy: false);
      Future<void> flush(bool more) async {
        await _send(c, {
          't': 'res',
          'id': id,
          if (first) 's': res.statusCode,
          if (first) 'h': head,
          'b': b64(buf.takeBytes()),
          'more': more,
        });
        first = false;
      }

      await for (final chunk in res.stream) {
        buf.add(chunk);
        while (buf.length >= kChunkBytes) {
          final all = buf.takeBytes();
          buf.add(all.sublist(0, kChunkBytes));
          final rest = all.sublist(kChunkBytes);
          await flush(true);
          buf.add(rest);
        }
      }
      await flush(false);
    } catch (e) {
      if (path.startsWith('/dragonbreath/')) _heater = null; // its IP may have changed
      await _send(c, {'t': 'res', 'id': id, 's': e is FormatException ? 400 : 502, 'h': {}, 'b': b64(utf8.encode('$e')), 'more': false});
    }
  }
}
