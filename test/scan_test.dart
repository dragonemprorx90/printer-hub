import 'package:flutter_test/flutter_test.dart';
import 'package:hub_link/hub_link.dart';
import 'package:printer_hub/scan.dart';

void main() {
  test('pairCodeFrom accepts bridge codes and rejects anything else', () {
    final code = PairInfo('wss://relay.example.com', 'room1', List.filled(32, 7)).encode();
    expect(pairCodeFrom('  $code\n'), code);
    expect(pairCodeFrom('PH1:abc'), isNull);
    expect(pairCodeFrom('https://example.com'), isNull);
    expect(pairCodeFrom(null), isNull);
  });
}
