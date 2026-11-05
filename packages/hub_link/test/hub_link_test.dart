import 'package:hub_link/hub_link.dart';
import 'package:test/test.dart';

void main() {
  final pair = PairInfo.create('https://relay.example.workers.dev/');

  test('pair code round-trips and normalises the relay URL', () {
    final back = PairInfo.decode(pair.encode());
    expect(back.relay, 'wss://relay.example.workers.dev');
    expect(back.room, pair.room);
    expect(back.secret, pair.secret);
    expect(pair.secret, hasLength(32));
    expect(() => PairInfo.decode('PH1:nope'), throwsFormatException);
    expect(() => PairInfo.decode('PHB1:!!!'), throwsFormatException);
  });

  test('sealed frames open with the same pair only', () async {
    final a = await LinkCrypto.forPair(pair);
    final b = await LinkCrypto.forPair(PairInfo.decode(pair.encode()));
    final frame = await a.seal({'t': 'ws', 'd': '{"method":"printer.info"}'});
    expect(frame, isNot(contains('printer.info'))); // relay sees ciphertext
    final msg = await b.open(frame);
    expect(msg['d'], '{"method":"printer.info"}');

    final other = await LinkCrypto.forPair(PairInfo.create('wss://x'));
    expect(other.open(frame), throwsA(anything));
  });

  test('tampered and stale frames are rejected', () async {
    final c = await LinkCrypto.forPair(pair);
    final frame = await c.seal({'t': 'ws'});
    final flipped = frame.substring(0, 20) +
        (frame[20] == 'A' ? 'B' : 'A') +
        frame.substring(21);
    expect(c.open(flipped), throwsA(anything));
    expect(c.open(frame, maxAge: const Duration(milliseconds: -1)),
        throwsFormatException);
  });

  test('relay token is separate from the encryption key', () async {
    final c = await LinkCrypto.forPair(pair);
    final again = await LinkCrypto.forPair(pair);
    expect(c.relayToken, again.relayToken); // deterministic
    expect(c.relayToken, isNot(b64(pair.secret)));
    expect(await tokenHash('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
}
