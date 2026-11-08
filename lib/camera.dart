import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'moonraker.dart';
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

/// Splits an MJPEG byte stream into JPEG frames (SOI 0xFFD8 … EOI 0xFFD9).
/// Feed chunks with [add]; complete frames come back from it.
class JpegSplitter {
  List<int> _data = const [];

  List<Uint8List> add(List<int> chunk) {
    _data = [..._data, ...chunk];
    final frames = <Uint8List>[];
    var start = -1;
    var consumed = 0;
    for (var i = 0; i + 1 < _data.length; i++) {
      if (_data[i] != 0xFF) continue;
      if (_data[i + 1] == 0xD8 && start < 0) {
        start = i;
      } else if (_data[i + 1] == 0xD9 && start >= 0) {
        frames.add(Uint8List.fromList(_data.sublist(start, i + 2)));
        consumed = i + 2;
        start = -1;
      }
    }
    // Keep only the unfinished tail; drop garbage before it.
    _data = start >= 0 ? _data.sublist(start) : _data.sublist(consumed);
    // ponytail: a corrupt stream without EOI is capped at 4 MB, not unbounded.
    if (_data.length > 4 << 20) _data = const [];
    return frames;
  }
}

/// Live camera. Picks the transport by itself:
///  * a camera URL the user typed (MJPEG, or a WebRTC signalling URL),
///  * Creality K1/K2 WebRTC signalling on :8000,
///  * otherwise the first MJPEG webcam registered in Moonraker.
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
  RTCPeerConnection? _pc;
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
      final url = widget.cameraUrl ?? await _detect();
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

  Future<String?> _detect() async {
    final host = widget.client.host;
    final creality = 'http://$host:8000/call/webrtc_local';
    try {
      final r = await http
          .get(Uri.parse(creality))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) return creality;
    } catch (_) {}
    try {
      final cams = await widget.client.webcams();
      if (cams.isNotEmpty) return cams.first;
    } catch (_) {}
    return null;
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

  /// Creality's signalling: POST the SDP offer as base64(JSON), receive the
  /// answer the same way. Receive-only, LAN-only, so no STUN/TURN.
  Future<void> _startWebRtc(String signalUrl) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    _renderer = renderer;

    final pc = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    // A track arrives as soon as the answer is applied, before any media, so
    // only count the camera as live once a real frame has been decoded.
    renderer.onFirstFrameRendered = () {
      _watchdog?.cancel();
      _set(_Mode.webrtc);
    };
    pc.onTrack = (e) {
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        renderer.srcObject = e.streams.first;
      }
    };
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    await pc.setLocalDescription(await pc.createOffer());
    // Host candidates arrive almost instantly on a LAN.
    await gathered.future.timeout(const Duration(seconds: 2), onTimeout: () {});
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

    _watchdog = Timer(const Duration(seconds: 12), () async {
      if (_mode != _Mode.probing || !mounted) return;
      // The camera serves one viewer at a time and can hold on to a session
      // that just closed, so try again a couple of times before giving up.
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
    _watchdog?.cancel();
    _mjpegClient?.close();
    _mjpegClient = null;
    _frame = null;
    await _pc?.close();
    _pc = null;
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
    final away =
        widget.client.viaRelay && (_mode == _Mode.none || _mode == _Mode.error);
    final child = away
        ? _msg(
            Icons.public_rounded,
            'Camera works at home for now',
            detail: 'Remote camera arrives in the next update',
          )
        : switch (_mode) {
            _Mode.probing => const Center(child: CircularProgressIndicator()),
            _Mode.mjpeg =>
              _frame == null
                  ? const Center(child: CircularProgressIndicator())
                  : Image.memory(
                      _frame!,
                      gaplessPlayback: true,
                      fit: widget.fit,
                    ),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(color: Colors.black, child: child),
      ),
    );
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
