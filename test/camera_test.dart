import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/camera.dart';

void main() {
  test('completeAnswer declines offer sections the printer left out', () {
    // Trimmed versions of the real K2 Plus exchange.
    const offer = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
        'a=group:BUNDLE 0 1\r\n'
        'm=video 64564 UDP/TLS/RTP/SAVPF 96 97\r\na=mid:0\r\na=recvonly\r\n'
        'm=audio 54517 UDP/TLS/RTP/SAVPF 111 63\r\na=mid:1\r\na=recvonly\r\n';
    const answer = 'v=0\r\no=- 9 9 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\n'
        'a=group:BUNDLE 0\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 98\r\na=sendonly\r\na=mid:0\r\n';

    final fixed = completeAnswer(offer, answer);
    final mLines =
        fixed.split('\r\n').where((l) => l.startsWith('m=')).toList();

    expect(mLines, [
      'm=video 9 UDP/TLS/RTP/SAVPF 96 98', // printer's video kept as-is
      'm=audio 0 UDP/TLS/RTP/SAVPF 111', // audio declined, same order as offer
    ]);
    expect(fixed, contains('a=mid:1\r\na=inactive'));
    expect(fixed.endsWith('\r\n'), isTrue);
  });

  test('completeAnswer leaves a complete answer unchanged in content', () {
    const offer = 'v=0\na=group:BUNDLE 0\nm=video 1 RTP/SAVPF 96\na=mid:0\n';
    const answer = 'v=0\na=group:BUNDLE 0\nm=video 9 RTP/SAVPF 96\na=mid:0\n';
    expect(completeAnswer(offer, answer), answer);
  });
}
