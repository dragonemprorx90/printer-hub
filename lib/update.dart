import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'settings.dart';
import 'ui.dart';

/// Keep in step with `version:` in pubspec.yaml.
const kAppVersion = '1.6.1';

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

/// Once a day on launch, silent unless an update exists.
Future<void> autoCheckForUpdate(BuildContext context) async {
  if (!settings.flag('updateAuto') || updateRepo.isEmpty) return;
  final last = settings.number('updateCheckedAt', 0);
  if (DateTime.now().millisecondsSinceEpoch - last < 24 * 3600 * 1000) return;
  try {
    final u = await checkForUpdate();
    if (u != null && context.mounted) await showUpdate(context, u);
  } catch (_) {}
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
              launchUrl(Uri.parse(u.downloadUrl ?? u.pageUrl),
                  mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.download_rounded),
            label: Text(u.downloadUrl == null ? 'Open release' : 'Download'),
          ),
        ],
      ),
    );
