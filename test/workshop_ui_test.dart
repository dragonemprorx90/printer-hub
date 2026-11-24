import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:printer_hub/main.dart';
import 'package:printer_hub/moonraker.dart';
import 'package:printer_hub/printer_page.dart';
import 'package:printer_hub/settings_page.dart';
import 'package:printer_hub/wall_page.dart';
import 'package:printer_hub/settings.dart';
import 'package:printer_hub/workshop_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// History and spools without a printer.
class _Fake extends MoonrakerClient {
  _Fake() : super(host: 'fake.local');

  @override
  Future<List<PrintJob>> allHistory() async => [
        for (var i = 0; i < 30; i++)
          PrintJob('part_$i.gcode', i % 5 == 0 ? 'error' : 'completed', DateTime.now().subtract(Duration(days: i, hours: i)),
              3600.0 + i * 60, 5000.0 + i * 100, true,
              material: i.isEven ? 'PLA' : 'PETG'),
      ];

  @override
  Future<bool> hasSpoolman() async => true;

  @override
  Future<List<Spool>> spools() async => [
        Spool(1, 'Brand red', 'PLA', 0xFFE53935, 150, 20),
        Spool(2, 'Brand black', 'PETG', 0xFF000000, 800, 25),
      ];

  @override
  Future<List<String>> snapshotFiles() async => const [];
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });

  // Every Workshop tab lays out on a phone without overflow or exceptions.
  testWidgets('Workshop tabs render on a phone', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: WorkshopPage(client: _Fake(), printer: const Printer(name: 'K2 Plus', host: 'fake.local')),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('ODOMETER'), findsOneWidget);
    for (final tab in ['Maintenance', 'Filament', 'Notes', 'Quote', 'Calculators']) {
      await t.ensureVisible(find.text(tab)); // the tab bar scrolls on a phone
      await t.tap(find.text(tab));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: tab);
    }
    // The calculators work out answers from the defaults.
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == '7.500'), findsOneWidget);
  });

  // The printer list with one (unreachable) printer: summary, Needs you, quick sheet.
  testWidgets('Printer list renders, with Needs you and the quick sheet', (t) async {
    SharedPreferences.setMockInitialValues({
      'printers': [jsonEncode(const Printer(name: 'K2 Plus', host: '127.0.0.1', port: 1).toJson())],
      'seenVersion': '99.0.0',
      'updateAuto': false,
      'orcaLink': false, // CI Macs would bind its ports and leave timers
    });
    await settings.load();
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: PrinterListPage()));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('K2 Plus'), findsWidgets);
    await t.tap(find.byIcon(Icons.notifications_none_rounded));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Needs you'), findsOneWidget);
    expect(find.textContaining('offline'), findsWidgets);
    expect(t.takeException(), isNull);
    // Close the page and the client so no reconnect timer is left behind.
    await t.pumpWidget(const SizedBox());
    dropClient(const Printer(name: 'K2 Plus', host: '127.0.0.1', port: 1));
    await t.pump(const Duration(minutes: 2));
  });

  // Every tab of a printer that can't be reached lays out without errors.
  testWidgets('Printer page tabs render offline', (t) async {
    SharedPreferences.setMockInitialValues({'seenVersion': '99.0.0'});
    await settings.load();
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    const p = Printer(name: 'U1', host: '127.0.0.1', port: 2);
    await t.pumpWidget(const MaterialApp(home: PrinterPage(printer: p)));
    await t.pump(const Duration(seconds: 1));
    for (final tab in ['Control', 'Files', 'Tools', 'History', 'Overview']) {
      await t.tap(find.text(tab).last);
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull, reason: tab);
    }
    await t.pumpWidget(const SizedBox());
    dropClient(p);
    await t.pump(const Duration(minutes: 2));
  });

  // Settings lays out, and "Find a setting" scrolls to the section.
  testWidgets('Settings renders and finds a setting', (t) async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: SettingsPage(printers: const [], onImport: (_) {})));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: 'page');
    await t.tap(find.byTooltip('Find a setting'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: 'sheet');
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'currency');
    await t.pumpAndSettle();
    await t.tap(find.text('Currency'));
    await t.pumpAndSettle();
    expect(find.text('COST ESTIMATE'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  // All printers and the camera wall with printers that can't be reached.
  testWidgets('All printers and the wall render offline', (t) async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    const ps = [Printer(name: 'K2', host: '127.0.0.1', port: 3), Printer(name: 'U1', host: '127.0.0.1', port: 4)];
    await t.pumpWidget(const MaterialApp(home: FleetPage(printers: ps)));
    await t.pump(const Duration(seconds: 2));
    expect(t.takeException(), isNull, reason: 'fleet');
    await t.pumpWidget(const MaterialApp(home: WallPage(printers: ps)));
    await t.pump(const Duration(seconds: 2));
    await t.tap(find.byTooltip('Show one printer at a time, in turn'));
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull, reason: 'wall');
    await t.pumpWidget(const SizedBox());
    for (final p in ps) {
      dropClient(p);
    }
    await t.pump(const Duration(minutes: 2));
  });
}
