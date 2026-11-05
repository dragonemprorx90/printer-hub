import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:hub_link/hub_link.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class RelayError implements Exception {
  final String message;
  RelayError(this.message);
  @override
  String toString() => message;
}

/// An end-to-end encrypted session with the home bridge, through the relay.
/// Carries the printer's Moonraker WebSocket and HTTP requests.
class RelayLink {
  final PairInfo pair;
  final LinkCrypto _crypto;
  final WebSocketChannel _ch;
  final _moonraker = StreamController<String>();
  final _done = Completer<String>();
  final _requests = <int, _Pending>{};
  int _nextId = 0;
  Future<void> _recv = Future.value(), _send = Future.value();
  Timer? _ping;

  RelayLink._(this.pair, this._crypto, this._ch);

  /// Moonraker WebSocket messages from the printer.
  Stream<String> get moonraker => _moonraker.stream;

  /// Completes with the reason when the session ends.
  Future<String> get done => _done.future;

  static Future<RelayLink> connect(PairInfo pair) async {
    final crypto = await LinkCrypto.forPair(pair);
    final ch = WebSocketChannel.connect(pair.socketUri('app', crypto.relayToken));
    try {
      await ch.ready.timeout(const Duration(seconds: 10));
    } catch (_) {
      throw RelayError('Could not reach your relay (or this remote code was replaced)');
    }
    final link = RelayLink._(pair, crypto, ch);
    final online = Completer<bool>();
    link._listen(online);
    final ok = await online.future
        .timeout(const Duration(seconds: 8), onTimeout: () => false);
    if (!ok) {
      link.close();
      throw RelayError('Your home bridge is offline');
    }
    return link;
  }

  void _listen(Completer<bool> online) {
    _ping = Timer.periodic(const Duration(seconds: 30), (_) => _ch.sink.add('ping'));
    _ch.stream.listen(
      (raw) {
        if (raw is! String || raw == 'pong') return;
        if (raw.startsWith('{')) {
          // Relay control message: {"bridge": true|false}.
          final bridge = (jsonDecode(raw) as Map)['bridge'];
          if (!online.isCompleted) {
            online.complete(bridge == true);
          } else if (bridge == false) {
            _end('Your home bridge went offline');
          }
          return;
        }
        _recv = _recv.then((_) => _onFrame(raw));
      },
      onDone: () => _end('Relay connection closed'),
      onError: (_) => _end('Relay connection failed'),
    );
  }

  Future<void> _onFrame(String frame) async {
    final Map<String, dynamic> m;
    try {
      m = await _crypto.open(frame);
    } catch (_) {
      return; // Not sealed by our bridge: ignore.
    }
    switch (m['t']) {
      case 'ws':
        if (!_moonraker.isClosed) _moonraker.add('${m['d']}');
      case 'ws_closed':
        _end('${m['e'] ?? 'Printer connection closed'}');
      case 'res':
        final id = m['id'];
        final p = _requests[id];
        if (p == null) return;
        p.add(m);
        if (m['more'] != true) _requests.remove(id);
    }
  }

  Future<void> _seal(Map<String, dynamic> msg) => _send = _send.then((_) async {
        if (_done.isCompleted) return;
        _ch.sink.add(await _crypto.seal(msg));
      });

  void sendMoonraker(String text) => _seal({'t': 'ws', 'd': text});

  /// Runs an HTTP request on the printer via the bridge. Only the path and
  /// query are used; the bridge always targets its own printer.
  Future<http.StreamedResponse> request(http.BaseRequest req) async {
    if (_done.isCompleted) throw RelayError('Not connected to your home bridge');
    final id = ++_nextId;
    final body = await req.finalize().toBytes();
    final pending = _Pending(req);
    _requests[id] = pending;
    final path = req.url.hasQuery ? '${req.url.path}?${req.url.query}' : req.url.path;
    final parts = body.isEmpty ? 1 : (body.length / kChunkBytes).ceil();
    for (var i = 0; i < parts; i++) {
      final chunk = body.isEmpty
          ? const <int>[]
          : body.sublist(i * kChunkBytes, math.min((i + 1) * kChunkBytes, body.length));
      await _seal({
        't': 'http',
        'id': id,
        'm': req.method,
        'p': path,
        'h': req.headers,
        'b': b64(chunk),
        'more': i < parts - 1,
      });
    }
    return pending.response.future;
  }

  void _end(String why) {
    if (_done.isCompleted) return;
    _ping?.cancel();
    _done.complete(why);
    for (final p in _requests.values) {
      p.fail(RelayError(why));
    }
    _requests.clear();
    _moonraker.close();
    _ch.sink.close();
  }

  void close() => _end('Closed');
}

class _Pending {
  final http.BaseRequest request;
  final response = Completer<http.StreamedResponse>();
  StreamController<List<int>>? _body;
  _Pending(this.request);

  void add(Map<String, dynamic> m) {
    var body = _body;
    if (body == null) {
      body = _body = StreamController<List<int>>();
      final headers = <String, String>{
        for (final e in ((m['h'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
      };
      response.complete(http.StreamedResponse(
        body.stream,
        (m['s'] as num?)?.toInt() ?? 502,
        headers: headers,
        request: request,
      ));
    }
    final b = m['b'];
    if (b is String && b.isNotEmpty) body.add(unb64(b));
    if (m['more'] != true) body.close();
  }

  void fail(Object e) {
    if (!response.isCompleted) {
      response.completeError(e);
    } else if (_body != null && !_body!.isClosed) {
      _body!
        ..addError(e)
        ..close();
    }
  }
}

/// An http.Client that sends every request through a [RelayLink].
class RelayHttpClient extends http.BaseClient {
  final RelayLink link;
  RelayHttpClient(this.link);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => link.request(request);
}
