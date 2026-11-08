import 'dart:io';

import 'package:test/test.dart';

import '../bin/bridge.dart';

void main() {
  test('CameraFeed returns the latest frame of an MJPEG stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final jpeg = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9];
    server.listen((req) async {
      req.response.headers.contentType = ContentType('multipart', 'x-mixed-replace');
      for (var i = 0; i < 50; i++) {
        req.response.add([...'--f\r\n\r\n'.codeUnits, ...jpeg, 13, 10]);
        await req.response.flush();
        await Future.delayed(const Duration(milliseconds: 50));
      }
      await req.response.close();
    });
    final feed = CameraFeed(Uri.parse('http://127.0.0.1:${server.port}/stream.mjpg'));
    expect(await feed.frame(), jpeg);
    await server.close(force: true);
  });

  test('CameraFeed reports a camera that sends nothing', () async {
    final feed = CameraFeed(Uri.parse('http://127.0.0.1:9/none'));
    await expectLater(feed.frame(), throwsA(isNot(contains('no picture'))));
  }, timeout: const Timeout(Duration(seconds: 40)));
}
