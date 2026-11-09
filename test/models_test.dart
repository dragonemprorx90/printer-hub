import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:printer_hub/models_page.dart';
import 'package:printer_hub/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('ready G-code is matched to the printer it was sliced for', () {
    expect(printerMatches('Creality K2 Plus', snapmaker: false), isTrue);
    expect(printerMatches('K2 Plus Combo', snapmaker: false), isTrue);
    expect(printerMatches('Creality K2 Pro', snapmaker: false), isFalse);
    expect(printerMatches('Prusa MK4S', snapmaker: false), isFalse);
    expect(printerMatches('Snapmaker U1', snapmaker: true), isTrue);
    expect(printerMatches('Snapmaker J1', snapmaker: true), isFalse);
    expect(printerMatches(null, snapmaker: true), isFalse);
  });

  test('Printables search, files and download link', () async {
    final asked = <String>[];
    final p = PrintablesSource(MockClient((req) async {
      if (req.url.host == 'files.printables.com') return http.Response.bytes([7, 7], 200);
      final q = jsonDecode(req.body)['query'] as String;
      asked.add(q);
      if (q.contains('searchPrints2')) {
        return http.Response(jsonEncode({'data': {'searchPrints2': {'items': [
          {'id': '3161', 'name': '3D BENCHY', 'likesCount': 9,
           'image': {'filePath': 'media/prints/3161/images/1_a/benchy.jpg'}, 'user': {'publicUsername': 'CT'}},
        ]}}}), 200);
      }
      if (q.contains('getDownloadLink')) {
        return http.Response(jsonEncode({'data': {'getDownloadLink': {'ok': true,
          'output': {'link': 'https://files.printables.com/x/3dbenchy.stl'}}}}), 200);
      }
      return http.Response(jsonEncode({'data': {'print': {'name': '3D BENCHY', 'summary': 's', 'images': [],
        'stls': [{'id': '49068', 'name': '3dbenchy.stl', 'fileSize': 11}],
        'gcodes': [{'id': '1', 'name': 'b.gcode', 'fileSize': 5, 'printer': {'name': 'Creality K2 Plus'}}]}}}), 200);
    }));
    final hit = (await p.search('benchy', 0)).single;
    expect(hit.image, 'https://media.printables.com/media/prints/3161/images/1_a/thumbs/inside/320x240/jpg/benchy.webp');
    final d = await p.detail(hit);
    expect([for (final f in d.files) (f.name, f.isGcode, f.sliceable, f.printer)],
        [('b.gcode', true, false, 'Creality K2 Plus'), ('3dbenchy.stl', false, true, null)]);
    expect(await d.files.last.download(), [7, 7]);
    expect(asked.last, contains('id: 49068, printId: 3161, fileType: stl'));
  });

  test('Creality Cloud: printer 3MFs, downloads ask for sign-in, then send the session', () async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    final seen = <http.Request>[];
    final c = CrealitySource(MockClient((req) async {
      seen.add(req);
      if (req.url.host != 'www.crealitycloud.com') return http.Response.bytes([3, 3], 200);
      return http.Response(jsonEncode(switch (req.url.path.split('/cxy/').last) {
        'smart_search/v1/model' => {'code': 0, 'result': {'list': [
          {'id': 'g1', 'groupName': 'Vase', 'likeCount': 4, 'userInfo': {'nickName': 'n'},
           'covers': [{'url': 'https://p/a.webp', 'originUrl': 'https://p/a.jpg'}]},
        ]}},
        'v3/model/3mfList' => {'code': 0, 'result': {'list': [
          {'id': 'f1', 'printerName': 'K2 Plus', 'secondName': '0.2mm', 'size': 9},
        ]}},
        _ => {'code': 0, 'result': {'downloadUrl': 'https://oss/x.3mf'}},
      }), 200);
    }));
    final hit = (await c.search('', 0)).single;
    expect(jsonDecode(seen.last.body)['keyword'], 'K2 Plus');
    expect([hit.title, hit.images], ['Vase', ['https://p/a.jpg']]);
    final f = (await c.detail(hit)).files.single;
    expect([f.name, f.printer, printerMatches(f.printer, snapmaker: false)], ['Vase - 0.2mm.3mf', 'K2 Plus', true]);
    await expectLater(f.download(), throwsA(isA<SignInNeeded>()));
    settings.setText('models.creality.token', 't');
    settings.setText('models.creality.uid', 'u');
    expect(await f.download(), [3, 3]);
    final dl = seen.firstWhere((r) => r.url.path.endsWith('3mfDownload'));
    expect([dl.headers['__CXY_TOKEN_'], dl.headers['__CXY_UID_']], ['t', 'u']);
  });

  test('model summaries become plain text', () {
    expect(plainText('<p>Fits <b>M3</b> &amp; M4 screws&nbsp;&lt;5&nbsp;mm&gt;</p><p>Tom&#39;s &quot;remix&quot;&#33;</p>'),
        'Fits M3 & M4 screws <5 mm>\nTom\'s "remix"!');
    expect(plainText('  '), '');
  });
}
