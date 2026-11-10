import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'moonraker.dart';
import 'settings.dart';
import 'slicer.dart';
import 'ui.dart';

/// Where a downloaded model gets sliced.
enum SliceWhere {
  app('Slice in the app', 'OrcaSlicer on the home bridge', Icons.layers_rounded),
  orca('Open in OrcaSlicer', 'On this Mac', Icons.desktop_mac_rounded),
  mac("Send to my Mac's OrcaSlicer", 'Opens there while Printer Hub runs on the Mac', Icons.send_to_mobile_rounded);

  final String label, detail;
  final IconData icon;
  const SliceWhere(this.label, this.detail, this.icon);
}

/// Hidden printer folder the phone drops models in for the Mac. Moonraker
/// keeps dot-folders out of file lists, and the relay carries it end to end
/// encrypted like any upload, so the home bridge needs nothing new.
const kInbox = '.printerhub-inbox';

/// The choices on this device, the last one used first. The in-app editor is
/// the default until another choice is made.
List<SliceWhere> sliceChoices({required bool isMac, required bool orcaHere, String last = 'app'}) {
  final all = [
    SliceWhere.app,
    if (isMac && orcaHere) SliceWhere.orca,
    if (!isMac) SliceWhere.mac,
  ];
  final first = all.where((w) => w.name == last).firstOrNull ?? SliceWhere.app;
  return [first, ...all.where((w) => w != first)];
}

/// OrcaSlicer's app bundle on this Mac, if installed.
String? orcaApp() => [
      '/Applications/OrcaSlicer.app',
      '${Platform.environment['HOME']}/Applications/OrcaSlicer.app',
    ].where((p) => Directory(p).existsSync()).firstOrNull;

/// A file name from elsewhere made safe to save: no folders, no odd characters.
String safeModelName(String name) {
  final n = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[^\w.\- ()]'), '_')
      .replaceAll(RegExp(r'^\.+'), '');
  return n.isEmpty ? 'model.stl' : n;
}

/// Saves [bytes] to ~/Downloads/Printer Hub and opens it in OrcaSlicer.
/// ponytail: `open -a` rather than the Orca plugin: it works whether Orca is
/// running or not and needs no plugin; the plugin can't be told to import.
Future<String> openInOrca(String name, Uint8List bytes) async {
  final app = orcaApp();
  if (app == null) throw 'OrcaSlicer is not installed in Applications';
  final dir = Directory('${Platform.environment['HOME']}/Downloads/Printer Hub')..createSync(recursive: true);
  final file = File('${dir.path}/${safeModelName(name)}');
  await file.writeAsBytes(bytes);
  final r = await Process.run('/usr/bin/open', ['-a', app, file.path]);
  if (r.exitCode != 0) throw 'OrcaSlicer did not open: ${r.stderr}';
  return file.path;
}

/// Mac: opens every model the phone left in [c]'s inbox, then removes it from
/// the printer. A file that fails to open stays for next time.
Future<List<String>> takeInbox(MoonrakerClient c,
    {Future<void> Function(String name, Uint8List bytes) open = _open}) async {
  final List<GcodeFile> files;
  try {
    files = (await c.directory(kInbox)).$2;
  } catch (_) {
    return const []; // no inbox yet
  }
  final done = <String>[];
  for (final f in files) {
    try {
      await open(f.name, await c.download(f.path));
      await c.deleteFile(f.path);
      done.add(f.name);
    } catch (_) {}
  }
  return done;
}

Future<void> _open(String name, Uint8List bytes) => openInOrca(name, bytes);

/// Asks where to slice [model] and does it. Returns the G-code files the
/// in-app editor put on the printer (null for the other choices or if closed).
Future<List<String>?> sliceOrSend(BuildContext context, MoonrakerClient client, String name, Uint8List model,
    {String folder = ''}) async {
  final isMac = Platform.isMacOS;
  final choices = sliceChoices(
      isMac: isMac, orcaHere: isMac && orcaApp() != null, last: settings.text('sliceWhere', 'app'));
  final where = choices.length == 1
      ? choices.first
      : await showModalBottomSheet<SliceWhere>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(title: Text('Slice $name', style: T.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
              for (final w in choices)
                ListTile(
                  leading: Icon(w.icon, color: w == choices.first ? C.accent : C.muted),
                  title: Text(w.label),
                  subtitle: Text(w.detail),
                  onTap: () => Navigator.pop(ctx, w),
                ),
            ]),
          ),
        );
  if (where == null || !context.mounted) return null;
  settings.setText('sliceWhere', where.name);
  switch (where) {
    case SliceWhere.app:
      return showSliceDialog(context, client, name, model, folder: folder);
    case SliceWhere.orca:
      await run(context, () => openInOrca(name, model), done: 'Opened $name in OrcaSlicer');
    case SliceWhere.mac:
      await run(context, () => client.upload(safeModelName(name), model, folder: kInbox),
          done: 'Sent. It opens in OrcaSlicer on your Mac');
  }
  return null;
}
