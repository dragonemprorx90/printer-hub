/// Pairing codes and end-to-end encryption shared by Printer Hub (the app)
/// and its home bridge. The cloud relay in between only ever sees sealed
/// frames, so it can neither read nor forge printer commands.
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Raw bytes per relayed HTTP chunk. Sealed and base64'd twice this stays
/// well under Cloudflare's 1 MiB WebSocket message limit.
const kChunkBytes = 256 * 1024;

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
List<int> unb64(String s) =>
    base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

/// What a phone needs to reach a printer through the relay. The bridge shows
/// it once as a code / QR at home. Whoever holds it controls the printer, so
/// it is treated like a password (and can be revoked by re-pairing).
class PairInfo {
  final String relay; // wss://… of the relay
  final String room; // random id
  final List<int> secret; // 32 random bytes, never sent to the relay

  /// ntfy topic URL the bridge pushes alerts to (null = alerts off).
  final String? alerts;

  const PairInfo(this.relay, this.room, this.secret, {this.alerts});

  static const _tag = 'PHB1:';

  factory PairInfo.create(String relay, {Random? rng, String? alerts}) {
    final r = rng ?? Random.secure();
    List<int> bytes(int n) => List.generate(n, (_) => r.nextInt(256));
    return PairInfo(normalizeRelay(relay), b64(bytes(16)), bytes(32), alerts: alerts);
  }

  /// A fresh private ntfy topic URL on [server]. The topic name is random,
  /// so only people holding the pairing code know where alerts go.
  static String newAlertTopic(String server, [Random? rng]) {
    final r = rng ?? Random.secure();
    final id = b64(List.generate(15, (_) => r.nextInt(256)));
    return '${server.trim().replaceAll(RegExp(r'/+$'), '')}/printerhub-$id';
  }

  /// https:// → wss://, trailing slash removed.
  static String normalizeRelay(String url) {
    var u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.startsWith('https://')) u = 'wss://${u.substring(8)}';
    if (u.startsWith('http://')) u = 'ws://${u.substring(7)}';
    if (!u.startsWith('ws://') && !u.startsWith('wss://')) u = 'wss://$u';
    return u;
  }

  String encode() => _tag +
      b64(utf8.encode(jsonEncode(
          {'r': relay, 'o': room, 's': b64(secret), 'n': ?alerts})));

  static PairInfo decode(String code) {
    final c = code.trim();
    if (!c.startsWith(_tag)) {
      throw const FormatException('Not a Printer Hub remote code');
    }
    final Map j;
    try {
      j = jsonDecode(utf8.decode(unb64(c.substring(_tag.length)))) as Map;
    } catch (_) {
      throw const FormatException('Damaged remote code');
    }
    final secret = unb64('${j['s']}');
    if (secret.length != 32 || '${j['o']}'.isEmpty) {
      throw const FormatException('Damaged remote code');
    }
    final n = j['n'];
    return PairInfo('${j['r']}', '${j['o']}', secret,
        alerts: n is String && n.startsWith('http') ? n : null);
  }

  Uri socketUri(String role, String token) => Uri.parse('$relay/v1/room/$room')
      .replace(queryParameters: {'role': role, 'token': token});
}

/// Keys derived from a [PairInfo]: one for sealing frames, one (unrelated)
/// token that proves room membership to the relay.
class LinkCrypto {
  final SecretKey _key;

  /// Sent to the relay; it stores only the SHA-256 ([tokenHash]).
  final String relayToken;

  LinkCrypto._(this._key, this.relayToken);

  static final _aead = Chacha20.poly1305Aead();

  static Future<LinkCrypto> forPair(PairInfo p) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final master = SecretKey(p.secret);
    final salt = utf8.encode(p.room);
    final enc = await hkdf.deriveKey(
        secretKey: master, nonce: salt, info: utf8.encode('printerhub/e2e/v1'));
    final tok = await hkdf.deriveKey(
        secretKey: master, nonce: salt, info: utf8.encode('printerhub/relay/v1'));
    return LinkCrypto._(enc, b64(await tok.extractBytes()));
  }

  /// Encrypts [msg]. Result: base64url(nonce ‖ ciphertext ‖ tag).
  Future<String> seal(Map<String, dynamic> msg) async {
    final clear = utf8.encode(
        jsonEncode({...msg, 'ts': DateTime.now().millisecondsSinceEpoch}));
    final box = await _aead.encrypt(clear, secretKey: _key);
    return b64(box.concatenation());
  }

  /// Decrypts a frame. Throws if it was tampered with, sealed with another
  /// key, or is older than [maxAge] (a replayed command).
  Future<Map<String, dynamic>> open(String frame,
      {Duration maxAge = const Duration(minutes: 10)}) async {
    final box = SecretBox.fromConcatenation(unb64(frame),
        nonceLength: 12, macLength: 16);
    final clear = await _aead.decrypt(box, secretKey: _key);
    final msg = Map<String, dynamic>.from(jsonDecode(utf8.decode(clear)) as Map);
    final ts = msg['ts'];
    final age = ts is int ? (DateTime.now().millisecondsSinceEpoch - ts).abs() : -1;
    if (age < 0 || age > maxAge.inMilliseconds) {
      throw const FormatException('Stale or replayed frame');
    }
    return msg;
  }
}

/// SHA-256 (hex) of a relay token, as the relay stores it.
Future<String> tokenHash(String token) async {
  final h = await Sha256().hash(utf8.encode(token));
  return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
