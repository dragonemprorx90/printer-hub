import 'package:flutter/material.dart';

import 'settings.dart';
import 'ui.dart';
import 'update.dart';

/// Release notes shown once after an update. Add the new version at the top.
const kWhatsNew = <(String, List<String>)>[
  ('1.15.0', [
    'Orca plugin 2.0: opens by itself when Orca starts; after closing it, click "Open Printer Hub" in Orca\'s notification to bring it back.',
    'Removed "Use this printer in Orca". Each printer card shows its Orca connection (127.0.0.1 and port) to enter once; Orca\'s own Filament sync then loads the colours.',
  ]),
  ('1.14.2', [
    'Orca plugin 1.4: fixes the K2 not syncing in Orca (Orca used port 80 instead of Printer Hub\'s). Save the plugin again, then press "Use this printer in Orca" once more.',
  ]),
  ('1.14.1', [
    'Fix: Orca could reach the wrong printer (the K2 got the U1\'s colours). Each printer now keeps its own local Orca address for good. Press "Use this printer in Orca" once more for each printer.',
  ]),
  ('1.14.0', [
    'Orca works with your printers from anywhere: Printer Hub runs a local Moonraker for each printer (127.0.0.1:7130, 7131, …) that reaches it at home or through your home bridge. Orca\'s device page, filament sync and printing go through it.',
    'Orca plugin 1.3: "Use this printer in Orca" points Orca at that local address.',
  ]),
  ('1.13.0', [
    'Orca plugin 1.2: "Use this printer in Orca" loads the matching Orca printer preset (bed size, nozzles), connects it to the printer with Orca\'s own Snapmaker or Creality agent, and sets each filament slot to the loaded material. Then Orca\'s sync button next to Filament loads the colours.',
  ]),
  ('1.12.1', [
    'Home bridge: the U1 filament data Orca reads now replaces old entries instead of adding duplicates.',
  ]),
  ('1.12.0', [
    'Orca plugin 1.1: each printer\'s loaded filaments, light / pause / resume / cancel, and "Sync colours to Orca", which sets Orca\'s filament slots to the printer\'s colours and materials.',
    'The home bridge now publishes the U1\'s lanes in the standard format Orca reads, so Orca\'s own device tab and Sync filaments work with the U1 (the K2\'s CFS already works).',
  ]),
  ('1.11.0', [
    'Orca Slicer link (Mac): add Printer Hub as a physical printer in Orca (Octo/Klipper, 127.0.0.1:7126). Print or Send opens Printer Hub, which uploads at home or from away and shows print setup.',
    'Printer Hub plugin for Orca Slicer 2.5+: a live printer panel beside the 3D view (Settings → Orca Slicer → Save the Orca plugin).',
  ]),
  ('1.10.0', [
    'U1 Print setup, instead of Snapmaker\'s cloud-only screen: choose which head prints each filament (with grams), turn on auto bed leveling, flow calibration or timelapse, then print. Works in LAN mode and from away.',
    'Upload Snapmaker Orca .3mf files: the app takes the sliced plate\'s G-code (and asks which plate if there are several).',
  ]),
  ('1.9.0', [
    'Rules: turn each one on or off, and copy a rule to all your printers.',
    'Recent alerts: see what your home bridge sent (Tools → Away from home).',
    'Low-spool alert from the home bridge after a print (under 100 g by default).',
    'History: filament used per week.',
    'Bed mesh history: save a mesh and see how its range changes over time.',
    'Files: long-press to select several, then queue or delete them together.',
    'A short welcome tour for new installs.',
  ]),
  ('1.8.0', [
    'Dryer schedule: a rule like "every day at 02:00 → dry filament 55°C for 6 h".',
    'Pictures during a print: a rule "every 10 min while printing → save a picture"; History shows them in order.',
    'Spool QR labels (Spoolman format), and scan a label to load that spool into a lane.',
  ]),
  ('1.7.0', [
    'Print sheet shows grams needed per lane against grams left on its spool, and warns when it will run out.',
    'Lane editor: "Choose spool" after loading a new roll.',
    'History shows the spool a print used and its real cost from the spool price (when Spoolman tracks it).',
    'Rules: new triggers (first layer, % progress, paused, heater fault) and a "send me a picture" action.',
    'Send a test alert and show the alerts topic as a QR (Tools → Away from home).',
    'Tap a printer\'s icon to give it its own colour.',
    'Back up and restore all settings (Settings → Printers).',
  ]),
  ('1.6.2', [
    'Add spool: pick a lane and type only the weight. The material and colour come from the lane, and the spool is linked to it.',
  ]),
  ('1.6.1', [
    'Send a file to another printer from its file sheet, and start it there.',
  ]),
  ('1.6.0', [
    'Rules: "when a print finishes, turn the light off", or every day at a set time. Your home bridge runs them, even with the app closed.',
    'Pictures of each print: tap a print in History to see its first layer and the end (taken by your home bridge).',
    'Add spools to Spoolman from the app.',
    'Printer health: CPU, memory, storage, versions and warnings (Tools).',
    'Cancelling or restarting from away asks twice.',
  ]),
  ('1.5.1', [
    'This screen: see what changed after each update.',
  ]),
  ('1.5.0', [
    'Print sheet shows which lane feeds each tool, warns on a mismatch, and lets you remap a tool to another lane.',
    'DragonBreath panel counts down the drying time.',
    'Quiet hours for home bridge alerts (QUIET_HOURS).',
    'Rotate or mirror the camera, per printer.',
    'Wall can sort problems first.',
    'Relay delay shown on the "from away" icon.',
    'Vibrate and sound when a print finishes, fails or pauses.',
  ]),
  ('1.4.0', [
    'Spoolman: set the active spool or link a spool to a U1 lane.',
    'Pause at layer, and heat the chamber before a print.',
    'Alerts with a camera picture, plus first layer, 10 min left and heater fault alerts.',
    'DragonBreath filter runs during ABS/ASA/PC/PA prints.',
  ]),
  ('1.3.3', [
    'U1 filament lanes, DragonBreath drying and fault clear, timelapse videos.',
    'Printer screen works from away.',
  ]),
];

/// -1, 0 or 1 comparing "1.2.10" style versions.
int compareVersions(String a, String b) {
  List<int> p(String v) => [for (final x in v.split('.')) int.tryParse(x) ?? 0];
  final x = p(a), y = p(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// Notes for versions newer than [seen] up to the running one.
List<(String, List<String>)> notesSince(String seen, [String current = kAppVersion]) => [
      for (final n in kWhatsNew)
        if (compareVersions(n.$1, seen) > 0 && compareVersions(n.$1, current) <= 0) n,
    ];

/// Shows "What's new" once per update. A fresh install (no printers yet)
/// just records the version.
Future<void> showWhatsNewIfUpdated(BuildContext context, {required bool freshInstall}) async {
  final seen = settings.text('seenVersion');
  settings.setText('seenVersion', kAppVersion);
  if (freshInstall && seen.isEmpty) return _welcome(context);
  if (freshInstall || seen == kAppVersion) return;
  // ponytail: updating from before this screen existed (no seenVersion), show
  // the last two releases rather than guess which one they came from.
  final notes = seen.isEmpty ? kWhatsNew.take(2).toList() : notesSince(seen);
  if (notes.isEmpty || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("What's new in $kAppVersion"),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (v, items) in notes) ...[
                  if (notes.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(v, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  for (final i in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('•  ', style: TextStyle(color: C.accent)),
                        Expanded(child: Text(i)),
                      ]),
                    ),
                ],
              ]),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
    ),
  );
}

const _tips = [
  (Icons.add_circle_outline_rounded, 'Add a printer', 'Tap + and enter its IP. Printers on your network are found for you.'),
  (Icons.public_rounded, 'From anywhere', 'Run the home bridge on a NAS or Pi and paste its remote access code (or scan its QR).'),
  (Icons.notifications_active_outlined, 'Alerts with the app closed', 'The bridge sends finished / failed / paused alerts, with a picture, to the free ntfy app.'),
  (Icons.rule_rounded, 'Rules', 'Tools → Rules: e.g. "print finishes → light off", or a nightly filament dry.'),
  (Icons.view_quilt_rounded, 'Wall', 'All your cameras on one screen, for a spare tablet.'),
];

Future<void> _welcome(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Welcome to Printer Hub'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final (icon, title, text) in _tips)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon, color: C.accent),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(text),
                ),
            ]),
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("Let's go"))],
      ),
    );
