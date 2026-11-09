import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';

import 'moonraker.dart';
import 'settings.dart';
import 'ui.dart';

enum _Mode { probing, mjpeg, webrtc, none, error, stopped }

/// Creality cameras answer only the video section, but libwebrtc always
/// offers audio too and rejects an answer with fewer m-lines than the offer.
/// Rebuild the answer in offer order, declining (port 0) what's missing.
String completeAnswer(String offer, String answer) {
  final nl = answer.contains('\r\n') ? '\r\n' : '\n';
  List<String> sections(String sdp) => sdp.trim().split(RegExp(r'\r?\n(?=m=)'));
  String? midOf(String s) =>
      RegExp(r'^a=mid:(\S+)', multiLine: true).firstMatch(s)?.group(1);

  final ans = sections(answer);
  final byMid = {for (final s in ans.skip(1)) midOf(s): s};
  final out = [ans.first];
  for (final s in sections(offer).skip(1)) {
    final mid = midOf(s);
    final have = byMid[mid];
    if (have != null) {
      out.add(have);
      continue;
    }
    final m = RegExp(r'^m=(\S+) \S+ (\S+) (\S+)').firstMatch(s);
    if (m == null || mid == null) continue;
    out.add(
      [
        'm=${m[1]} 0 ${m[2]} ${m[3]}',
        'c=IN IP4 0.0.0.0',
        'a=mid:$mid',
        'a=inactive',
      ].join(nl),
    );
  }
  return '${out.join(nl)}$nl';
}

/// Creality K1/K2 signalling (`:8000/call/webrtc_local`). Any other URL with
/// "webrtc" in it is camera-streamer's (Snapmaker U1, many Klipper printers).
bool isCrealitySignal(String url) => url.contains('/call/webrtc');

/// Camera URL per printer host, found once per app run. Probing the K2's
/// :8000 endpoint can take seconds, so later opens skip it.
final _detected = <String, String?>{};

/// The camera to use for [client]: [typed] if set, else Creality's WebRTC
/// signalling on :8000, else the first webcam Moonraker knows. Null = none.
Future<String?> detectCamera(MoonrakerClient client, String? typed) async {
  if (typed != null && typed.isNotEmpty) return typed;
  final host = client.host;
  if (_detected.containsKey(host)) return _detected[host];
  final creality = 'http://$host:8000/call/webrtc_local';
  // Both probes at once; Creality wins when it answers.
  final cams = client.webcams().then<List<String>?>((v) => v).catchError((_) => null);
  try {
    final r = await http.get(Uri.parse(creality)).timeout(const Duration(seconds: 3));
    if (r.statusCode == 200) return _detected[host] = creality;
  } catch (_) {}
  final list = await cams;
  if (list == null) return null; // Moonraker unreachable: don't cache
  return _detected[host] = list.isEmpty ? null : list.first;
}

/// One WebRTC connection per camera, shared by every view of it and by the
/// Orca panel's snapshot, and kept [linger] after the last user leaves.
/// Creality cameras serve one viewer and refuse a new one for ~30 s after a
/// session ends, so reopening a page or going fullscreen reuses this.
class RtcCamera {
  static final _all = <String, RtcCamera>{};
  static const linger = Duration(seconds: 45);

  final String url;

  /// The video stream once it arrives; back to null if the session drops.
  final stream = ValueNotifier<MediaStream?>(null);
  late final Future<void> ready;
  RTCPeerConnection? _pc;
  int _users = 0;
  Timer? _linger;
  bool _closed = false;

  RtcCamera._(this.url) {
    ready = _connect();
    ready.catchError((_) => close()); // a failed session is never reused
  }

  static RtcCamera acquire(String url) {
    final c = _all.putIfAbsent(url, () => RtcCamera._(url));
    c._users++;
    c._linger?.cancel();
    return c;
  }

  void release() {
    if (--_users > 0 || _closed) return;
    _linger = Timer(linger, close);
  }

  /// Ends the connection now; the next [acquire] starts a fresh one.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _linger?.cancel();
    if (identical(_all[url], this)) _all.remove(url);
    stream.value = null;
    await _pc?.close();
    _pc = null;
  }

  Future<void> _connect() async {
    final pc = await createPeerConnection({'iceServers': [], 'sdpSemantics': 'unified-plan'});
    if (_closed) return pc.close();
    _pc = pc;
    pc.onTrack = (e) {
      if (e.track.kind == 'video' && e.streams.isNotEmpty && !_closed) stream.value = e.streams.first;
    };
    pc.onConnectionState = (st) {
      if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          st == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        close();
      }
    };
    // LAN only: host candidates come at once. Send the offer/answer shortly
    // after the first one instead of waiting for gathering to "complete",
    // which can take seconds with several network interfaces.
    final gathered = Completer<void>();
    void done() => gathered.isCompleted ? null : gathered.complete();
    pc.onIceCandidate = (_) => Timer(const Duration(milliseconds: 250), done);
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) done();
    };
    final g = gathered.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (isCrealitySignal(url)) {
      await _crealitySignal(pc, url, g);
    } else {
      await _cameraStreamerSignal(pc, url, g);
    }
  }

  /// One still frame (PNG) from the live stream, waiting up to [wait] for
  /// the first decoded frame.
  Future<Uint8List> frame({Duration wait = const Duration(seconds: 8)}) async {
    await ready;
    final until = DateTime.now().add(wait);
    while (true) {
      final track = stream.value?.getVideoTracks().firstOrNull;
      if (track != null) {
        try {
          final b = (await track.captureFrame()).asUint8List();
          if (b.length > 1000) return b; // not a blank first frame
        } catch (_) {}
      }
      if (DateTime.now().isAfter(until)) throw 'The camera sent no picture';
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }
}

/// Creality: POST our SDP offer as base64(JSON), receive the answer the
/// same way.
Future<void> _crealitySignal(
  RTCPeerConnection pc,
  String signalUrl,
  Future<void> gathered,
) async {
  await pc.addTransceiver(
    kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
    init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
  );

  await pc.setLocalDescription(await pc.createOffer());
  // Host candidates arrive almost instantly on a LAN.
  await gathered.timeout(const Duration(seconds: 2), onTimeout: () {});
  final local = await pc.getLocalDescription();

  final body = base64.encode(
    utf8.encode(jsonEncode({'type': 'offer', 'sdp': local!.sdp})),
  );
  final r = await http
      .post(
        Uri.parse(signalUrl),
        headers: {'Content-Type': 'plain/text'},
        body: body,
      )
      .timeout(const Duration(seconds: 8));
  final txt = r.body.trim();
  final answer = jsonDecode(
    txt.startsWith('{') ? txt : utf8.decode(base64.decode(txt)),
  );
  await pc.setRemoteDescription(
    RTCSessionDescription(
      completeAnswer(local.sdp!, '${answer['sdp']}'),
      '${answer['type']}',
    ),
  );
}

/// camera-streamer: the camera offers (JSON), we answer with its session
/// id. With keepAlive it pings over a data channel and wants pongs.
Future<void> _cameraStreamerSignal(
  RTCPeerConnection pc,
  String signalUrl,
  Future<void> gathered,
) async {
  pc.onDataChannel = (ch) =>
      ch.onMessage = (_) => ch.send(RTCDataChannelMessage('pong'));
  Future<Map> post(Map body) async {
    final r = await http
        .post(
          Uri.parse(signalUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode >= 300) throw 'Camera returned HTTP ${r.statusCode}';
    return r.body.trim().isEmpty ? const {} : jsonDecode(r.body) as Map;
  }

  final offer = await post({'type': 'request', 'keepAlive': true});
  await pc.setRemoteDescription(
    RTCSessionDescription('${offer['sdp']}', '${offer['type']}'),
  );
  await pc.setLocalDescription(await pc.createAnswer());
  await gathered.timeout(const Duration(seconds: 2), onTimeout: () {});
  final local = await pc.getLocalDescription();
  await post({'type': 'answer', 'id': offer['id'], 'sdp': local!.sdp});
}

/// Live camera. Picks the transport by itself:
///  * away from home: JPEG frames from the home bridge through the relay,
///  * a camera URL the user typed (MJPEG, or a WebRTC signalling URL),
///  * Creality K1/K2 WebRTC signalling on :8000,
///  * otherwise the first webcam registered in Moonraker (MJPEG or
///    camera-streamer WebRTC).
class PrinterCamera extends StatefulWidget {
  final MoonrakerClient client;
  final String? cameraUrl;
  final BoxFit fit;
  const PrinterCamera({
    super.key,
    required this.client,
    this.cameraUrl,
    this.fit = BoxFit.cover,
  });

  @override
  State<PrinterCamera> createState() => PrinterCameraState();
}

class PrinterCameraState extends State<PrinterCamera> {
  _Mode _mode = _Mode.probing;
  String? _error;
  RTCVideoRenderer? _renderer;
  Timer? _watchdog;
  http.Client? _mjpegClient;
  Uint8List? _frame;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _set(_Mode m) {
    if (mounted) setState(() => _mode = m);
  }

  Future<void> _start() async {
    _set(_Mode.probing);
    try {
      if (widget.client.viaRelay) return await _startRelay();
      final url = await detectCamera(widget.client, widget.cameraUrl);
      if (url == null) return _set(_Mode.none);
      if (url.contains('webrtc')) {
        await _startWebRtc(url);
      } else {
        await _startMjpeg(url);
      }
    } catch (e) {
      _error = '$e';
      _set(_Mode.error);
    }
  }

  int _gen = 0;

  /// Away from home the bridge reads the camera on the LAN and sends JPEG
  /// frames end-to-end encrypted through the relay, a few per second and
  /// only while this view is open.
  Future<void> _startRelay() async {
    final gen = ++_gen;
    var failures = 0;
    while (mounted && gen == _gen) {
      if (!widget.client.viaRelay) return restart(); // home again
      final Uint8List f;
      try {
        f = await widget.client.relayFrame();
        failures = 0;
      } catch (_) {
        // A WebRTC camera that just had a viewer can refuse the bridge for
        // ~30 s; the bridge keeps trying, so ask again a few times.
        if (++failures >= 3) rethrow;
        continue;
      }
      if (!mounted || gen != _gen) return;
      _frame = f;
      _set(_Mode.mjpeg);
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> _startMjpeg(String url) async {
    final client = http.Client();
    _mjpegClient = client;
    final res = await client
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 300) throw 'Camera returned HTTP ${res.statusCode}';
    _set(_Mode.mjpeg);
    final splitter = JpegSplitter();
    res.stream.listen(
      (chunk) {
        final frames = splitter.add(chunk);
        if (frames.isNotEmpty && mounted) setState(() => _frame = frames.last);
      },
      onError: (Object e) {
        _error = '$e';
        _set(_Mode.error);
      },
      cancelOnError: true,
    );
  }

  RtcCamera? _rtc;
  VoidCallback? _onStream;

  /// Receive-only WebRTC on the LAN (no STUN/TURN), through the shared
  /// [RtcCamera] session for this camera.
  Future<void> _startWebRtc(String signalUrl) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    _renderer = renderer;
    final cam = _rtc = RtcCamera.acquire(signalUrl);
    // A track arrives as soon as the answer is applied, before any media, so
    // only count the camera as live once a real frame has been decoded.
    renderer.onFirstFrameRendered = () {
      _watchdog?.cancel();
      _set(_Mode.webrtc);
    };
    void attach() {
      final st = cam.stream.value;
      if (st != null) {
        renderer.srcObject = st;
      } else if (_mode == _Mode.webrtc && mounted) {
        restart(); // the shared session dropped
      }
    }
    cam.stream.addListener(_onStream = attach);
    attach();
    await cam.ready;

    _watchdog = Timer(const Duration(seconds: 8), () async {
      if (_mode != _Mode.probing || !mounted) return;
      // No frame: drop this session (it may be a refused one) and retry a
      // couple of times, the camera can hold on to a session that just closed.
      await cam.close();
      if (_attempts < 3) {
        _attempts++;
        await _teardown();
        if (mounted) _start();
        return;
      }
      _error =
          'The camera answered but sent no video. '
          'Close other camera viewers (Creality app, other devices) and retry.';
      _set(_Mode.error);
    });
  }

  int _attempts = 0;

  /// True once real video (WebRTC) or a first MJPEG frame is showing.
  bool get isLive =>
      _mode == _Mode.webrtc || (_mode == _Mode.mjpeg && _frame != null);

  String get debugState => '$_mode ${_error ?? ''}';

  Future<void> _teardown() async {
    _gen++;
    _watchdog?.cancel();
    _mjpegClient?.close();
    _mjpegClient = null;
    _frame = null;
    if (_onStream != null) _rtc?.stream.removeListener(_onStream!);
    _onStream = null;
    _rtc?.release();
    _rtc = null;
    await _renderer?.dispose();
    _renderer = null;
  }

  /// Releases the camera (e.g. while a fullscreen view has its own session).
  Future<void> stop() async {
    await _teardown();
    _set(_Mode.stopped);
  }

  Future<void> restart() async {
    await _teardown();
    _error = null;
    _attempts = 0;
    _start();
  }

  /// The current frame as image bytes (PNG for WebRTC, JPEG for MJPEG).
  Future<Uint8List?> snapshot() async {
    if (_mode == _Mode.mjpeg) return _frame;
    final track = _renderer?.srcObject?.getVideoTracks().firstOrNull;
    if (track == null) return null;
    final buf = await track.captureFrame();
    return buf.asUint8List();
  }

  String get snapshotExtension => _mode == _Mode.mjpeg ? 'jpg' : 'png';

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  Widget _msg(
    IconData icon,
    String text, {
    String? detail,
    bool retry = false,
  }) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white54, size: 36),
        const SizedBox(height: 8),
        Text(text, style: const TextStyle(color: Colors.white70)),
        if (detail != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Text(
              detail,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
        if (retry)
          TextButton.icon(
            onPressed: restart,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final child = switch (_mode) {
      _Mode.probing => const Center(child: CircularProgressIndicator()),
      _Mode.mjpeg =>
        _frame == null
            ? const Center(child: CircularProgressIndicator())
            : Image.memory(_frame!, gaplessPlayback: true, fit: widget.fit),
      _Mode.webrtc => RTCVideoView(
        _renderer!,
        objectFit: widget.fit == BoxFit.contain
            ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
            : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      ),
      _Mode.none => _msg(
        Icons.videocam_off_rounded,
        'No camera found',
        detail: 'Set a camera URL in the printer settings',
      ),
      _Mode.error => _msg(
        Icons.error_outline_rounded,
        'Camera unavailable',
        detail: _error,
        retry: true,
      ),
      _Mode.stopped => _msg(
        Icons.pause_circle_outline_rounded,
        'Camera paused',
        retry: true,
      ),
    };
    final turns = settings.number(_turnsKey, 0).toInt(), flip = settings.flag(_flipKey, false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(R.lg),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: RotatedBox(
            quarterTurns: turns,
            child: Transform.flip(flipX: flip, child: child),
          ),
        ),
      ),
    );
  }

  String get _turnsKey => 'cam.turns.${widget.client.host}';
  String get _flipKey => 'cam.flip.${widget.client.host}';

  /// Rotate / flip the picture (mounted upside down or mirrored cameras).
  Future<void> adjust(BuildContext context) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (k, icon, label) in [
            ('rotate', Icons.rotate_right_rounded, 'Rotate 90°'),
            ('flip', Icons.flip_rounded, 'Mirror'),
            ('reset', Icons.restart_alt_rounded, 'Reset'),
          ])
            ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(ctx, k)),
        ]),
      ),
    );
    if (pick == null) return;
    setState(() {
      if (pick == 'rotate') settings.setNumber(_turnsKey, ((settings.number(_turnsKey, 0) + 1) % 4));
      if (pick == 'flip') settings.setFlag(_flipKey, !settings.flag(_flipKey, false));
      if (pick == 'reset') {
        settings.setNumber(_turnsKey, 0);
        settings.setFlag(_flipKey, false);
      }
    });
  }
}

/// Fullscreen camera with pinch / scroll zoom.
class CameraFullscreen extends StatelessWidget {
  final MoonrakerClient client;
  final String? cameraUrl;
  final String title;
  const CameraFullscreen({
    super.key,
    required this.client,
    this.cameraUrl,
    required this.title,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(title),
    ),
    body: InteractiveViewer(
      maxScale: 6,
      child: Center(
        child: PrinterCamera(
          client: client,
          cameraUrl: cameraUrl,
          fit: BoxFit.contain,
        ),
      ),
    ),
  );
}

/// Small round icon button used over video.
class OverlayButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  const OverlayButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        foregroundColor: active ? C.warn : Colors.white,
      ),
    ),
  );
}
