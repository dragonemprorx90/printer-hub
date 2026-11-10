import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'settings.dart';
import 'ui.dart';

/// Keep in step with `version:` in pubspec.yaml.
const kAppVersion = '1.25.0';

/// Where releases are published; can be changed in Settings.
const kUpdateRepo = 'dragonemprorx90/printer-hub';

String get updateRepo => settings.text('updateRepo', kUpdateRepo).trim();

class UpdateError implements Exception {
  final String message;
  UpdateError(this.message);
  @override
  String toString() => message;
}

class UpdateInfo {
  final String version, notes, pageUrl;
  final String? downloadUrl;
  UpdateInfo(this.version, this.notes, this.pageUrl, this.downloadUrl);
}

/// True when [candidate] (e.g. "v1.2.0") is a later version than [current].
bool isNewer(String candidate, String current) {
  List<int> parts(String v) => v
      .trim()
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((e) => int.tryParse(e) ?? 0)
      .toList();
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// The release asset for this platform: .ipa on iPhone, .apk on Android,
/// .dmg/.zip on the Mac. Null means "open the release page instead".
String? pickAsset(List assets, {String? platform}) {
  final os = platform ?? Platform.operatingSystem;
  final wanted = switch (os) {
    'ios' => ['.ipa'],
    'android' => ['.apk'],
    'macos' => ['.dmg', '-macos.zip', '.app.zip'],
    _ => const <String>[],
  };
  for (final ext in wanted) {
    for (final a in assets) {
      final name = '${a['name']}'.toLowerCase();
      if (name.endsWith(ext)) return '${a['browser_download_url']}';
    }
  }
  return null;
}

/// Asks GitHub for the latest release of the repo set in Settings
/// ("owner/repo"). Returns null when this build is already current.
Future<UpdateInfo?> checkForUpdate() async {
  final repo = updateRepo;
  if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
    throw UpdateError('Set the update source (owner/repo) in Settings first');
  }
  final http.Response r;
  try {
    r = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 12));
  } catch (_) {
    throw UpdateError('Could not reach GitHub. Check your internet connection.');
  }
  if (r.statusCode == 404) throw UpdateError('No releases published for $repo yet');
  if (r.statusCode >= 300) throw UpdateError('GitHub returned ${r.statusCode}');
  settings.setNumber(
      'updateCheckedAt', DateTime.now().millisecondsSinceEpoch.toDouble());
  final j = jsonDecode(r.body);
  final tag = '${j['tag_name'] ?? ''}';
  if (!isNewer(tag, kAppVersion)) return null;
  return UpdateInfo(
    tag.replaceFirst(RegExp(r'^[vV]'), ''),
    '${j['body'] ?? ''}'.trim(),
    '${j['html_url']}',
    pickAsset((j['assets'] as List?) ?? const []),
  );
}

/// Once a day on launch, silent unless an update exists. On the Mac the
/// update is downloaded and installed in the background first, then the
/// user is asked to restart.
Future<void> autoCheckForUpdate(BuildContext context) async {
  if (!settings.flag('updateAuto') || updateRepo.isEmpty) return;
  final last = settings.number('updateCheckedAt', 0);
  if (DateTime.now().millisecondsSinceEpoch - last < 24 * 3600 * 1000) return;
  try {
    final u = await checkForUpdate();
    if (u == null || !context.mounted) return;
    if (Platform.isMacOS && u.downloadUrl != null) {
      try {
        await installMacUpdate(u.downloadUrl!);
        if (context.mounted) await askRestart(context, u);
        return;
      } catch (_) {} // fall back to the normal dialog
    }
    if (context.mounted) await showUpdate(context, u);
  } catch (_) {}
}

/// 1.18 dropped the Mac app sandbox (so it can update itself). Settings
/// lived in the sandbox container; copy them over once so printers survive.
Future<void> migrateSandboxPrefs() async {
  if (!Platform.isMacOS) return;
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty || home.contains('/Library/Containers/')) return; // still sandboxed
  const id = 'com.matside.printerHub';
  final mine = File('$home/Library/Preferences/$id.plist');
  final old = File('$home/Library/Containers/$id/Data/Library/Preferences/$id.plist');
  if (mine.existsSync() || !old.existsSync()) return;
  await Process.run('/usr/bin/defaults', ['import', id, old.path]);
}

/// The running .app bundle (".../Printer Hub.app").
String get _bundlePath =>
    File(Platform.resolvedExecutable).parent.parent.parent.path;

/// Downloads the release .dmg, copies the app out of it over the running
/// bundle, and cleans up. Needs the Mac build to be unsandboxed.
/// [progress] gets 0..1 while downloading.
Future<void> installMacUpdate(String url, {void Function(double)? progress}) async {
  if (!url.toLowerCase().endsWith('.dmg')) throw UpdateError('No .dmg in this release');
  final tmp = await Directory.systemTemp.createTemp('printerhub-update');
  final dmg = File('${tmp.path}/update.dmg');
  final mnt = '${tmp.path}/mnt';
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(url)));
    if (res.statusCode >= 300) throw UpdateError('Download failed (${res.statusCode})');
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = dmg.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress?.call(got / total);
    }
    await sink.close();

    Future<void> sh(String exe, List<String> args) async {
      final r = await Process.run(exe, args);
      if (r.exitCode != 0) throw UpdateError('${args.first} failed: ${'${r.stderr}'.trim()}');
    }

    await sh('/usr/bin/hdiutil',
        ['attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mnt, dmg.path]);
    try {
      final app = Directory(mnt).listSync().whereType<Directory>().firstWhere(
          (d) => d.path.endsWith('.app'),
          orElse: () => throw UpdateError('No app inside the .dmg'));
      final dest = _bundlePath;
      final fresh = '$dest.new', old = '$dest.old';
      await Process.run('/bin/rm', ['-rf', fresh, old]);
      await sh('/usr/bin/ditto', [app.path, fresh]);
      await Process.run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', fresh]);
      // Swap: the running copy keeps working from memory until restart.
      await sh('/bin/mv', [dest, old]);
      try {
        await sh('/bin/mv', [fresh, dest]);
      } catch (e) {
        await Process.run('/bin/mv', [old, dest]);
        rethrow;
      }
      await Process.run('/bin/rm', ['-rf', old]);
    } finally {
      await Process.run('/usr/bin/hdiutil', ['detach', mnt, '-force']);
    }
  } finally {
    client.close();
    tmp.delete(recursive: true).ignore();
  }
}

/// Quits and reopens the (already replaced) app.
Future<Never> restartApp() async {
  await Process.start('/bin/sh', ['-c', 'sleep 1; open "\$0"', _bundlePath],
      mode: ProcessStartMode.detached);
  exit(0);
}

Future<void> askRestart(BuildContext context, UpdateInfo u) => showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Version ${u.version} is installed'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Text('Restart Printer Hub to start using it.'
                '${u.notes.isEmpty ? '' : '\n\n${u.notes}'}'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton.icon(
            onPressed: restartApp,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Restart now'),
          ),
        ],
      ),
    );

/// Mac: download + install with a progress dialog, then offer a restart.
/// iPhone: hand the .ipa to SideStore. Otherwise open the download.
Future<void> _install(BuildContext context, UpdateInfo u) async {
  final url = u.downloadUrl;
  if (url != null && Platform.isMacOS) {
    final p = ValueNotifier<double?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('Updating to ${u.version}'),
        content: ValueListenableBuilder<double?>(
          valueListenable: p,
          builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v),
            const SizedBox(height: 12),
            Text(v == null || v < 1 ? 'Downloading…' : 'Installing…', style: T.small),
          ]),
        ),
      ),
    );
    try {
      await installMacUpdate(url, progress: (v) => p.value = v);
      if (!context.mounted) return;
      Navigator.pop(context);
      await askRestart(context, u);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context);
      toast(context, 'Update failed: $e', error: true);
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
    return;
  }
  if (url != null && Platform.isIOS) {
    final scheme = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Install ${u.version} with'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'sidestore'), child: const Text('SideStore')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'livecontainer'), child: const Text('LiveContainer')),
        ],
      ),
    );
    if (scheme == null) return;
    final app = Uri.parse('$scheme://install?url=${Uri.encodeComponent(url)}');
    if (await launchUrl(app, mode: LaunchMode.externalApplication)) return;
  }
  launchUrl(Uri.parse(url ?? u.pageUrl), mode: LaunchMode.externalApplication);
}

/// "Check for updates" button.
Future<void> checkForUpdateNow(BuildContext context) async {
  try {
    final u = await checkForUpdate();
    if (!context.mounted) return;
    if (u == null) {
      toast(context, 'You\'re on the latest version ($kAppVersion)');
    } else {
      await showUpdate(context, u);
    }
  } catch (e) {
    if (context.mounted) toast(context, '$e', error: true);
  }
}

Future<void> showUpdate(BuildContext context, UpdateInfo u) => showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update available: ${u.version}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Text(
              'You have $kAppVersion.\n\n'
              '${u.notes.isEmpty ? 'No release notes.' : u.notes}',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _install(context, u);
            },
            icon: const Icon(Icons.download_rounded),
            label: Text(u.downloadUrl == null ? 'Open release' : 'Update'),
          ),
        ],
      ),
    );
