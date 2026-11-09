import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'moonraker.dart';
import 'settings.dart';
import 'slicer.dart';
import 'gcode.dart';
import 'ui.dart';
import 'update.dart';

/// One search result on a model site.
class ModelHit {
  final String id, title, image, author;
  final int likes;
  final List<String> images; // when the search result already has them
  const ModelHit(
      {required this.id, required this.title, required this.image, this.author = '', this.likes = 0, this.images = const []});
}

/// A downloadable file of a model. [printer] is set for ready G-code.
class ModelFile {
  final String name;
  final int size;
  final String? printer;
  final Future<Uint8List> Function() download;
  const ModelFile(this.name, this.size, this.download, {this.printer});
  String get ext => name.split('.').last.toLowerCase();
  bool get isGcode => ext == 'gcode';
  bool get sliceable => modelExt.contains(ext) || ext == '3mf';
}

class ModelDetail {
  final String title, summary;
  final List<String> images;
  final List<ModelFile> files;
  const ModelDetail(this.title, this.summary, this.images, this.files);
}

/// A model site the app can search and download from.
abstract class ModelSource {
  String get name;

  /// What's missing before the source can be used (e.g. 'token'), or null.
  String? get blocked => null;

  /// The model's own page on the site.
  Uri webUrl(ModelHit hit);
  Future<List<ModelHit>> search(String query, int page);
  Future<ModelDetail> detail(ModelHit hit);
}

/// Sent to model sites: Printables' firewall turns away Dart's default.
final _ua = {'user-agent': 'PrinterHub/$kAppVersion (+https://github.com/dragonemprorx90/printer-hub)'};

/// A model-site request with a time limit and plain-language failures.
Future<http.Response> _net(Future<http.Response> request, [Duration limit = const Duration(seconds: 20)]) async {
  try {
    return await request.timeout(limit);
  } on TimeoutException {
    throw MoonrakerError('The site didn\'t answer in time. Try again.');
  } on SocketException {
    throw MoonrakerError('No internet connection.');
  } on http.ClientException {
    throw MoonrakerError('No internet connection.');
  }
}

/// [html] as plain text: tags dropped, common entities decoded.
@visibleForTesting
String plainText(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>|</(p|div|li)>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

Future<Uint8List> _get(http.Client h, String url, [Map<String, String>? headers]) async {
  final r = await _net(h.get(Uri.parse(url), headers: {..._ua, ...?headers}), const Duration(minutes: 5));
  if (r.statusCode != 200) throw MoonrakerError('Download failed (HTTP ${r.statusCode})');
  return r.bodyBytes;
}

/// printables.com: its public GraphQL API, no account needed.
class PrintablesSource extends ModelSource {
  final http.Client h;
  PrintablesSource([http.Client? client]) : h = client ?? http.Client();
  @override
  String get name => 'Printables';
  @override
  Uri webUrl(ModelHit hit) => Uri.parse('https://www.printables.com/model/${hit.id}');

  static const _media = 'https://media.printables.com/';

  Future<Map<String, dynamic>> _q(String query) async {
    final r = await _net(h.post(Uri.parse('https://api.printables.com/graphql/'),
        headers: {..._ua, 'content-type': 'application/json'}, body: jsonEncode({'query': query})));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (j['errors'] != null || r.statusCode != 200) throw MoonrakerError('Printables: ${j['errors'] ?? r.statusCode}');
    return j['data'] as Map<String, dynamic>;
  }

  /// A small webp of a Printables image (their own thumbnail size).
  static String thumb(String filePath) {
    final i = filePath.lastIndexOf('/');
    final base = filePath.substring(i + 1).replaceAll(RegExp(r'\.\w+$'), '');
    return '$_media${filePath.substring(0, i)}/thumbs/inside/320x240/jpg/$base.webp';
  }

  @override
  Future<List<ModelHit>> search(String query, int page) async {
    final d = await _q('query { searchPrints2(query: ${jsonEncode(query)}, limit: 24, offset: ${page * 24}) '
        '{ items { id name likesCount image { filePath } user { publicUsername } } } }');
    return [
      for (final p in d['searchPrints2']['items'] as List)
        ModelHit(
          id: '${p['id']}',
          title: '${p['name']}',
          image: p['image'] == null ? '' : thumb('${p['image']['filePath']}'),
          author: '${p['user']?['publicUsername'] ?? ''}',
          likes: (p['likesCount'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<ModelDetail> detail(ModelHit hit) async {
    final d = (await _q('query { print(id: ${hit.id}) { name summary images { filePath } '
        'stls { id name fileSize } gcodes { id name fileSize printer { name } } } }'))['print'] as Map;
    ModelFile file(Map f, String type, [String? printer]) => ModelFile(
          '${f['name']}',
          (f['fileSize'] as num?)?.toInt() ?? 0,
          printer: printer,
          () async {
            final l = await _q('mutation { getDownloadLink(id: ${f['id']}, printId: ${hit.id}, fileType: $type, '
                'source: model_detail) { ok output { link } } }');
            return _get(h, '${l['getDownloadLink']['output']['link']}');
          },
        );
    return ModelDetail(
      '${d['name']}',
      '${d['summary'] ?? ''}',
      [for (final i in d['images'] as List) '$_media${i['filePath']}'],
      [
        for (final f in d['gcodes'] as List) file(f as Map, 'gcode', '${f['printer']?['name'] ?? ''}'),
        for (final f in d['stls'] as List) file(f as Map, 'stl'),
      ],
    );
  }
}

/// thingiverse.com: needs your own free app token (thingiverse.com/developers).
class ThingiverseSource extends ModelSource {
  final http.Client h;
  ThingiverseSource([http.Client? client]) : h = client ?? http.Client();
  @override
  String get name => 'Thingiverse';
  @override
  Uri webUrl(ModelHit hit) => Uri.parse('https://www.thingiverse.com/thing:${hit.id}');
  String get _token => settings.text('models.thingiverse');
  @override
  String? get blocked => _token.isEmpty ? 'token' : null;
  Map<String, String> get _auth => {'Authorization': 'Bearer $_token'};

  Future<dynamic> _j(String path) async {
    final r = await _net(h.get(Uri.parse('https://api.thingiverse.com/$path'), headers: {..._ua, ..._auth}));
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw MoonrakerError('Thingiverse refused the token. Clear it with the key button and paste it again.');
    }
    if (r.statusCode != 200) throw MoonrakerError('Thingiverse: HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  @override
  Future<List<ModelHit>> search(String query, int page) async {
    final j = await _j('search/${Uri.encodeComponent(query)}?type=things&per_page=24&page=${page + 1}'
        '${query.isEmpty ? '&sort=popular' : ''}');
    return [
      for (final t in (j['hits'] as List? ?? const []))
        ModelHit(
          id: '${t['id']}',
          title: '${t['name']}',
          image: '${t['preview_image'] ?? t['thumbnail'] ?? ''}',
          author: '${t['creator']?['name'] ?? ''}',
          likes: (t['like_count'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<ModelDetail> detail(ModelHit hit) async {
    final (t, files, images) =
        await (_j('things/${hit.id}'), _j('things/${hit.id}/files'), _j('things/${hit.id}/images')).wait;
    String large(Map i) {
      final sizes = (i['sizes'] as List).cast<Map>();
      return '${(sizes.where((s) => s['size'] == 'large' && s['type'] == 'display').firstOrNull ?? sizes.first)['url']}';
    }

    return ModelDetail(
      '${t['name']}',
      '${t['description'] ?? ''}',
      [for (final i in images as List) large(i as Map)],
      [
        for (final f in files as List)
          ModelFile('${f['name']}', (f['size'] as num?)?.toInt() ?? 0, () => _get(h, '${f['download_url']}', _auth)),
      ],
    );
  }
}

/// crealitycloud.com: search and its per-printer 3MFs are public; downloads
/// need your account (signed in once on Creality's own page, see [SiteSignIn]).
class CrealitySource extends ModelSource {
  final http.Client h;
  CrealitySource([http.Client? client]) : h = client ?? http.Client();
  @override
  String get name => 'Creality Cloud';
  @override
  Uri webUrl(ModelHit hit) => Uri.parse('https://www.crealitycloud.com/model-detail/${hit.id}');
  static bool get signedIn => token.isNotEmpty;

  /// Forgets the session here and in the sign-in web view.
  static Future<void> signOut() async {
    settings
      ..setText('models.creality.token', '')
      ..setText('models.creality.uid', '');
    await WebViewCookieManager().clearCookies();
  }
  static String get token => settings.text('models.creality.token');
  static String get uid => settings.text('models.creality.uid');

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body, {bool auth = false}) async {
    final r = await _net(h.post(Uri.parse('https://www.crealitycloud.com/api/cxy/$path'),
        headers: {
          ..._ua,
          'content-type': 'application/json',
          if (auth) ...{'__CXY_TOKEN_': token, '__CXY_UID_': uid, '__CXY_PLATFORM_': '6'},
        },
        body: jsonEncode(body)));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (j['code'] == 4) {
      settings.setText('models.creality.token', '');
      throw MoonrakerError('Sign in to Creality Cloud again (the session ended).');
    }
    if (j['code'] != 0) throw MoonrakerError('Creality Cloud: ${j['msg']}');
    return (j['result'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  @override
  Future<List<ModelHit>> search(String query, int page) async {
    // An empty search returns nothing, so start from models for your printers.
    final r = await _post('smart_search/v1/model',
        {'keyword': query.isEmpty ? 'K2 Plus' : query, 'page': page + 1, 'pageSize': 24});
    return [
      for (final m in (r['list'] as List? ?? const []))
        ModelHit(
          id: '${m['id']}',
          title: '${m['groupName']}',
          image: '${(m['covers'] as List?)?.firstOrNull?['url'] ?? ''}',
          images: [for (final c in (m['covers'] as List? ?? const [])) '${c['originUrl'] ?? c['url']}'],
          author: '${m['userInfo']?['nickName'] ?? ''}',
          likes: (m['likeCount'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<ModelDetail> detail(ModelHit hit) async {
    final r = await _post('v3/model/3mfList', {'modelGroupId': hit.id, 'page': 1, 'pageSize': 50});
    return ModelDetail(hit.title, '', hit.images.isEmpty ? [hit.image] : hit.images, [
      for (final f in (r['list'] as List? ?? const []))
        ModelFile(
          _fileName('${hit.title} - ${f['secondName'] ?? f['printerName']}', '3mf'),
          (f['size'] as num?)?.toInt() ?? 0,
          printer: '${f['printerName'] ?? ''}',
          () async {
            if (token.isEmpty) throw const SignInNeeded();
            final d = await _post('v3/model/3mfDownload', {'id': f['id']}, auth: true);
            return _get(h, '${d['downloadUrl']}');
          },
        ),
    ]);
  }
}

/// A safe printer file name: no path characters, at most 120 characters.
String _fileName(String stem, String ext) {
  final s = stem.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
  return '${s.length > 120 ? s.substring(0, 120).trim() : s}.$ext';
}

/// Thrown by a download that needs the site's sign-in first.
class SignInNeeded implements Exception {
  const SignInNeeded();
}

/// A site's own login page in a web view; returns once the session cookies
/// appear (Creality keeps them readable to the page). Your password goes to
/// the site only; the app keeps the session token on this device.
class SiteSignIn extends StatefulWidget {
  const SiteSignIn({super.key});
  @override
  State<SiteSignIn> createState() => _SiteSignInState();

  static Future<bool> creality(BuildContext context) async =>
      await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const SiteSignIn())) ?? false;
}

class _SiteSignInState extends State<SiteSignIn> {
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(
      onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      onPageFinished: (_) => _check(),
    ))
    ..loadRequest(Uri.parse('https://www.crealitycloud.com/model-category/3d-print-all'));
  bool _done = false;
  int _progress = 0;

  Future<void> _check({bool asked = false}) async {
    if (_done) return;
    final raw = '${await _web.runJavaScriptReturningResult('document.cookie').catchError((_) => '')}';
    final c = {
      for (final kv in raw.replaceAll('"', '').split(';'))
        if (kv.contains('=')) kv.split('=').first.trim(): kv.substring(kv.indexOf('=') + 1).trim(),
    };
    final token = c['model_token'] ?? '', uid = c['model_user_id'] ?? '';
    if (!mounted) return;
    if (token.isEmpty || uid.isEmpty) {
      if (asked) toast(context, 'Not signed in yet. Tap Log In on the page and sign in first.');
      return;
    }
    _done = true;
    settings
      ..setText('models.creality.token', token)
      ..setText('models.creality.uid', uid);
    toast(context, 'Signed in to Creality Cloud');
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign in to Creality Cloud'), actions: [
          TextButton(onPressed: () => _check(asked: true), child: const Text('Done')),
        ]),
        body: Column(children: [
          if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Hint('Tap Log In on the page and sign in. Your password goes to Creality only; '
                'the app keeps the session on this device.'),
          ),
          Expanded(child: WebViewWidget(controller: _web)),
        ]),
      );
}

/// makerworld.com in a web view: it doesn't let apps search it, so you browse
/// and sign in as usual, and a model file you download is caught and sliced.
class MakerWorldPage extends StatefulWidget {
  final MoonrakerClient client;
  final String folder;
  const MakerWorldPage({super.key, required this.client, required this.folder});
  @override
  State<MakerWorldPage> createState() => _MakerWorldPageState();
}

class _MakerWorldPageState extends State<MakerWorldPage> {
  static final _file = RegExp(r'\.(3mf|stl|step|stp|obj)(\?|$)', caseSensitive: false);
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(
      onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      onPageFinished: (_) async {
        final back = await _web.canGoBack();
        if (mounted) setState(() => _canBack = back);
      },
      onNavigationRequest: (req) {
        final u = Uri.tryParse(req.url);
        if (u == null || !_file.hasMatch(u.path)) return NavigationDecision.navigate;
        _take(u);
        return NavigationDecision.prevent;
      },
    ))
    ..loadRequest(Uri.parse('https://makerworld.com/en'));
  bool _busy = false, _canBack = false;
  int _progress = 0;

  Future<void> _take(Uri url) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _get(http.Client(), url.toString());
      if (!mounted) return;
      final name = Uri.decodeComponent(url.pathSegments.last);
      final files = await showSliceDialog(context, widget.client, name, bytes, folder: widget.folder);
      if (files != null && files.isNotEmpty && mounted) Navigator.pop(context, files.first);
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
          title: const Text('MakerWorld'),
          actions: [
            IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _canBack ? () => _web.goBack() : null),
          ],
        ),
        body: Column(children: [
          if (_busy) const LinearProgressIndicator() else if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Hint('Find a model and tap Download (3MF or STL). Printer Hub catches the file and slices it '
                'for your printer.'),
          ),
          Expanded(child: WebViewWidget(controller: _web)),
        ]),
      );
}

final _desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Does ready G-code made for [printer] (a site's printer name) suit this one?
@visibleForTesting
bool printerMatches(String? printer, {required bool snapmaker}) {
  final p = (printer ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return snapmaker ? p.contains('snapmakeru1') || p == 'u1' : p.contains('k2plus');
}

/// Search model sites, then print ready G-code or slice the model. Pops with
/// the G-code path now on the printer.
class ModelsPage extends StatefulWidget {
  final MoonrakerClient client;
  final String folder;
  const ModelsPage({super.key, required this.client, this.folder = ''});
  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  static final sources = <ModelSource>[PrintablesSource(), CrealitySource(), ThingiverseSource()];
  late ModelSource _src =
      sources.firstWhere((s) => s.name == settings.text('models.source'), orElse: () => sources.first);
  final _query = TextEditingController();
  final _hits = <ModelHit>[];
  int _page = 0;
  bool _loading = false, _more = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _query.text = settings.text('models.query.${_src.name}');
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search({bool next = false}) async {
    final src = _src;
    setState(() {
      _error = null;
      if (!next) {
        _hits.clear();
        _page = 0;
        _more = true;
      }
    });
    if (src.blocked != null) return;
    settings.setText('models.query.${src.name}', _query.text.trim());
    setState(() => _loading = true);
    try {
      final got = await src.search(_query.text.trim(), _page);
      if (!mounted || src != _src) return;
      setState(() {
        _hits.addAll(got);
        _page++;
        _more = got.isNotEmpty;
      });
    } catch (e) {
      if (mounted && src == _src) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(ModelHit hit) async {
    final path = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => _ModelDetailPage(source: _src, hit: hit, client: widget.client, folder: widget.folder)));
    if (path != null && mounted) Navigator.pop(context, path);
  }

  Widget _tokenSetup() => ListView(padding: const EdgeInsets.all(16), children: [
        const Hint('Thingiverse needs a free app token: sign in at thingiverse.com/developers, '
            'create an app, and paste its App Token here.'),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse('https://www.thingiverse.com/developers'), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Get a token'),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(labelText: 'Thingiverse app token'),
          obscureText: true,
          onSubmitted: (v) {
            settings.setText('models.thingiverse', v.trim());
            _search();
          },
        ),
      ]);

  Widget _results() {
    if (_src.blocked == 'token') return _tokenSetup();
    if (_error != null && _hits.isEmpty) return StateView.error(_error!, onRetry: _search);
    if (_hits.isEmpty && _loading) return const Center(child: CircularProgressIndicator());
    if (_hits.isEmpty) return const StateView.empty(Icons.search_off_rounded, 'No models found');
    return RefreshIndicator(
      onRefresh: _search,
      child: NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600 && !_loading && _more) _search(next: true);
        return false;
      },
      child: GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: (MediaQuery.sizeOf(context).width / 220).floor().clamp(2, 6),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.78,
        ),
        itemCount: _hits.length,
        itemBuilder: (_, i) => _HitCard(hit: _hits[i], onTap: () => _open(_hits[i])),
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Find models'), actions: [
          if (_src is CrealitySource && CrealitySource.signedIn)
            IconButton(
              tooltip: 'Sign out of Creality Cloud',
              icon: const Icon(Icons.logout_rounded),
              onPressed: () async {
                await CrealitySource.signOut();
                if (context.mounted) toast(context, 'Signed out of Creality Cloud');
                setState(() {});
              },
            ),
          if (_src is ThingiverseSource && _src.blocked == null)
            IconButton(
              tooltip: 'Change Thingiverse token',
              icon: const Icon(Icons.key_rounded),
              onPressed: () {
                settings.setText('models.thingiverse', '');
                _search();
              },
            ),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _query,
              autofocus: _desktop,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(hintText: 'Search ${_src.name}', prefixIcon: const Icon(Icons.search_rounded)),
              onSubmitted: (_) => _search(),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
              ...[
              for (final s in sources)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.name),
                    selected: s == _src,
                    onSelected: (_) {
                      settings.setText('models.source', s.name);
                      setState(() => _src = s);
                      _query.text = settings.text('models.query.${s.name}');
                      _search();
                    },
                  ),
                ),
              ],
              ActionChip(
                avatar: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text('MakerWorld'),
                onPressed: () async {
                  final path = await Navigator.push<String>(context,
                      MaterialPageRoute(builder: (_) => MakerWorldPage(client: widget.client, folder: widget.folder)));
                  if (path != null && context.mounted) Navigator.pop(context, path);
                },
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(child: _results()),
        ]),
      );
}

class _HitCard extends StatelessWidget {
  final ModelHit hit;
  final VoidCallback onTap;
  const _HitCard({required this.hit, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final placeholder = Icon(Icons.view_in_ar_rounded, color: C.muted);
    return Semantics(
      button: true,
      label: '${hit.title}${hit.author.isEmpty ? '' : ' by ${hit.author}'}',
      excludeSemantics: true,
      child: Tile(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Container(
            color: C.surfaceHi,
            child: hit.image.isEmpty
                ? placeholder
                : Image.network(hit.image, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(hit.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${hit.author}${hit.likes > 0 ? ' · ♥ ${hit.likes}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.muted)),
          ]),
        ),
      ]),
      ),
    );
  }
}

class _ModelDetailPage extends StatefulWidget {
  final ModelSource source;
  final ModelHit hit;
  final MoonrakerClient client;
  final String folder;
  const _ModelDetailPage({required this.source, required this.hit, required this.client, required this.folder});
  @override
  State<_ModelDetailPage> createState() => _ModelDetailPageState();
}

class _ModelDetailPageState extends State<_ModelDetailPage> {
  late Future<ModelDetail> _detail = widget.source.detail(widget.hit);
  String? _busy; // the file being fetched
  int _image = 0;

  MoonrakerClient get c => widget.client;

  Future<void> _use(ModelFile f, {required bool ready}) async {
    if (f.size > 100 * 1024 * 1024 &&
        !await confirm(context, 'Download ${fmtBytes(f.size)}?',
            message: 'This file is large; on mobile data it may take a while.', action: 'Download')) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = f.name);
    try {
      final Uint8List bytes;
      try {
        bytes = await f.download();
      } on SignInNeeded {
        if (!mounted) return;
        setState(() => _busy = null);
        final signedIn = await SiteSignIn.creality(context);
        if (signedIn && mounted) await _use(f, ready: ready);
        return;
      }
      if (!mounted) return;
      // A 3MF made for this printer may already hold its G-code: print that.
      final plates = ready && f.ext == '3mf' ? platesIn3mf(bytes) : const <int, Uint8List>{};
      if (f.isGcode || plates.isNotEmpty) {
        final name = f.isGcode ? f.name : f.name.replaceAll(RegExp(r'\.3mf$', caseSensitive: false), '.gcode');
        await c.upload(name, f.isGcode ? bytes : plates[plates.keys.reduce((a, b) => a < b ? a : b)]!,
            folder: widget.folder);
        if (mounted) Navigator.pop(context, widget.folder.isEmpty ? name : '${widget.folder}/$name');
        return;
      }
      setState(() => _busy = null);
      final files = await showSliceDialog(context, c, f.name, bytes, folder: widget.folder);
      if (files != null && files.isNotEmpty && mounted) Navigator.pop(context, files.first);
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(s, style: T.label.copyWith(color: C.muted, letterSpacing: 1.1)),
      );

  Widget _fileRow(ModelFile f, {required bool ready}) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(ready ? Icons.print_rounded : Icons.view_in_ar_rounded, color: ready ? C.accent : C.muted),
        title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            [if (f.size > 0) fmtBytes(f.size), if (f.printer?.isNotEmpty ?? false) f.printer!].join(' · '),
            style: T.small.copyWith(color: C.muted)),
        trailing: _busy == f.name
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : FilledButton.tonal(
                onPressed: _busy == null ? () => _use(f, ready: ready) : null, child: Text(ready ? 'Send' : 'Slice')),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.hit.title, overflow: TextOverflow.ellipsis), actions: [
          IconButton(
            tooltip: 'Open on ${widget.source.name}',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => launchUrl(widget.source.webUrl(widget.hit), mode: LaunchMode.externalApplication),
          ),
        ]),
        body: FutureBuilder<ModelDetail>(
          future: _detail,
          builder: (_, snap) {
            if (snap.hasError) {
              return StateView.error('${snap.error}',
                  onRetry: () => setState(() => _detail = widget.source.detail(widget.hit)));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final d = snap.data!;
            bool fits(ModelFile f) => printerMatches(f.printer, snapmaker: c.isSnapmaker);
            final ready = [for (final f in d.files) if ((f.isGcode || f.ext == '3mf' && f.printer != null) && fits(f)) f];
            final models = [for (final f in d.files) if (f.sliceable && !ready.contains(f)) f]
              ..sort((a, b) => a.size.compareTo(b.size)); // smallest (quickest) first
            return ListView(padding: const EdgeInsets.all(16), children: [
              if (d.images.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(R.lg),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Stack(children: [
                      PageView(onPageChanged: (i) => setState(() => _image = i), children: [
                        for (final i in d.images) Container(color: C.surfaceHi, child: Image.network(i, fit: BoxFit.contain)),
                      ]),
                      if (d.images.length > 1)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(99)),
                            child: Text('${_image + 1} / ${d.images.length}',
                                style: T.caption.copyWith(color: Colors.white)),
                          ),
                        ),
                    ]),
                  ),
                ),
              const SizedBox(height: 16),
              Text(d.title, style: T.title),
              if (widget.hit.author.isNotEmpty)
                Text('by ${widget.hit.author} on ${widget.source.name}', style: T.small.copyWith(color: C.muted)),
              if (plainText(d.summary).isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(plainText(d.summary), maxLines: 6, overflow: TextOverflow.ellipsis),
              ],
              if (ready.isNotEmpty) ...[
                _label('READY TO PRINT ON THIS PRINTER'),
                for (final f in ready) _fileRow(f, ready: true),
              ],
              _label(ready.isEmpty ? 'NOT SLICED FOR THIS PRINTER: SLICE A MODEL' : 'OR SLICE A MODEL'),
              if (models.isEmpty) const Hint('This model has no STL, 3MF, STEP or OBJ file to slice.'),
              for (final f in models) _fileRow(f, ready: false),
            ]);
          },
        ),
      );
}
