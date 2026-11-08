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
// It is read only while a phone is watching.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';
import 'package:qr/qr.dart';
import 'package:web_socket_channel/io.dart';

void log(String m) =>
    stdout.writeln('${DateTime.now().toIso8601String().substring(0, 19)}  $m');

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final hasValue = i + 1 < argv.length && !argv[i + 1].startsWith('--');
    args[a.substring(2)] = hasValue ? argv[++i] : 'true';
  }
  if (args.containsKey('help')) {
    stdout.writeln('Usage: bridge --relay <url> --printer <ip> [--port 7125] '
        '[--data <dir>] [--show-code] [--reset]');
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
          spoolLow: double.tryParse(env['SPOOL_LOW_G'] ?? '') ?? 100);
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

  log('Bridging printer $printer:$port through ${pair.relay}');
  if (camera != null) log('Camera from away: $cameraUrl');
  await Bridge(pair, await LinkCrypto.forPair(pair), printer, port, camera: camera).run();
}

/// Reads a home camera (MJPEG stream or JPEG snapshot URL) only while a
/// phone is asking for frames, and keeps the latest one.
class CameraFeed {
  final Uri url;
  CameraFeed(this.url);

  static const _idle = Duration(seconds: 20);
  Uint8List? _frame;
  var _frameAt = DateTime(0), _wanted = DateTime(0);
  var _running = false;
  String? _error;

  bool get _watched => DateTime.now().difference(_wanted) < _idle;

  Future<Uint8List> frame() async {
    _wanted = DateTime.now();
    if (!_running) unawaited(_run());
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
    log('Camera: a phone is watching');
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
      log('Camera: idle, released');
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
  List<Map> _rules = const [];
  final _ranToday = <String>{};
  Timer? _filterOff;

  final (int, int)? quiet; // start and end hour; only urgent alerts then
  final double spoolLow; // grams; warn when a lane's spool has less
  final _spoolWarned = <int, DateTime>{};

  Alerts(this.topic, this.host, this.port,
      {this.name, this.humidityLimit = 45, this.camera, this.autoFilter = true, this.quiet, this.spoolLow = 100});

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
              }))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) log('Alert not delivered (HTTP ${r.statusCode})');
    } catch (e) {
      log('Alert not delivered: $e');
    }
  }

  Future<void> run() async {
    unawaited(_rulesLoop());
    var backoff = 2;
    while (true) {
      final started = DateTime.now();
      try {
        await _watch();
      } catch (e) {
        log('Alerts: lost the printer ($e)');
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
    void subscribe() => ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': ++id,
          'method': 'printer.objects.subscribe',
          'params': {
            'objects': {
              'print_stats': ['state', 'filename', 'message', 'print_duration', 'info'],
              'virtual_sdcard': ['progress'],
              'box': null,
              'dragonbreath': ['connected', 'fault', 'fault_reason'],
              'output_pin dragonbreath_filter': null,
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
    final db = status['dragonbreath'];
    if (db is Map) _dragon.addAll(Map<String, dynamic>.from(db));
    if (status['output_pin dragonbreath_filter'] != null) _hasFilter = true;
    final p = status['virtual_sdcard']?['progress'];
    if (p is num) _progress = p.toDouble();

    final state = _stats['state'] as String?;
    final file = '${_stats['filename'] ?? ''}'.split('/').last;
    final note = '${_stats['message'] ?? ''}'.trim();
    final last = _state;
    _state = state;
    if (last != null && state != null && state != last) {
      unawaited(_runRules((r) => r['on'] == state));
      switch (state) {
        case 'complete':
          await send('$_title: print finished', file,
              tags: ['white_check_mark'], priority: 4, jpeg: await _keep('end'));
          unawaited(_checkSpools());
        case 'error':
          await send('$_title: print failed', note.isEmpty ? file : note,
              tags: ['warning'], priority: 5, jpeg: await _keep('end'));
        case 'cancelled':
          await send('$_title: print cancelled', file, tags: ['x']);
        case 'paused' when last == 'printing':
          await send('$_title: print paused',
              note.isEmpty ? 'Check the printer (filament run-out?)' : note,
              tags: ['pause_button'], priority: 4, picture: true);
        case 'printing' when last == 'standby' || last == 'complete' || last == 'cancelled' || last == 'error':
          _sent = {};
          _started = DateTime.now();
          await send('$_title: print started', file, tags: ['printer'], priority: 2);
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
      final layer = (_stats['info'] as Map?)?['current_layer'];
      if (layer is num && layer >= 2 && _sent.add('first_layer')) {
        await send('$_title: first layer done', 'Have a look before it carries on.',
            tags: ['mag'], priority: 2, jpeg: await _keep('first'));
        unawaited(_runRules((r) => r['on'] == 'first_layer'));
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
      await send('$_title: CFS $i humidity ${h.toStringAsFixed(0)}%',
          'Above ${humidityLimit.toStringAsFixed(0)}%. Dry the filament before it absorbs more moisture.',
          tags: ['droplet']);
    }
  }
}

extension on Alerts {
  /// Rules come from Moonraker's database (the app edits them). Reloaded each
  /// minute, when daily ones are due too.
  Future<void> _rulesLoop() async {
    while (true) {
      try {
        final r = await _client.get(Uri.parse(
            'http://$host:$port/server/database/item?namespace=printer_hub&key=rules'));
        _rules = r.statusCode == 200
            ? List<Map>.from((jsonDecode(r.body)['result']?['value'] as List?) ?? const [])
            : const [];
      } catch (_) {}
      final now = DateTime.now();
      final hhmm = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final day = '${now.year}-${now.month}-${now.day}';
      await _runRules((r) => r['on'] == 'time' && r['at'] == hhmm && _ranToday.add('$day ${r['at']} ${r['do']}'));
      final mins = _started == null ? 0 : now.difference(_started!).inMinutes;
      if (_state == 'printing' && mins > 0) {
        await _runRules((r) => r['on'] == 'interval' && (int.tryParse('${r['at']}') ?? 0) > 0 &&
            mins % int.parse('${r['at']}') == 0);
      }
      await Future.delayed(Duration(seconds: 60 - DateTime.now().second));
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
    for (final r in _rules.where((r) => r['off'] != true).where(match)) {
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

/// "cube.gcode" started at t, kind "first" -> "cube__1794164593__first.jpg".
/// The app matches it to the history job by name and start time.
String snapshotName(String gcode, DateTime started, String kind) {
  final stem = gcode.replaceAll(RegExp(r'\.gcode$', caseSensitive: false), '').replaceAll(RegExp(r'[^\w.-]+'), '_');
  return '${stem}__${started.millisecondsSinceEpoch ~/ 1000}__$kind.jpg';
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

  IOWebSocketChannel? _relay;
  final _sessions = <String, _Session>{};
  final _client = http.Client();
  Future<void> _recvChain = Future.value();
  Future<void> _sendChain = Future.value();

  Bridge(this.pair, this.crypto, this.host, this.port, {this.camera});

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
  /// or the DragonBreath heater named in the printer's own [dragonbreath].
  /// Never anywhere else.
  Future<(Uri, Map<String, String>)> target(String path) async {
    if (!path.startsWith('/') || path.startsWith('//')) throw const FormatException('bad path');
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
    try {
      final (uri, extra) = await target(path);
      final req = http.Request('${m['m']}', uri)..bodyBytes = body;
      final headers = Map<String, dynamic>.from((m['h'] as Map?) ?? const {});
      headers.forEach((k, v) {
        if (_forwardHeaders.contains(k.toLowerCase())) req.headers[k] = '$v';
      });
      req.headers.addAll(extra);
      final res = await _client.send(req).timeout(const Duration(seconds: 60));
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
