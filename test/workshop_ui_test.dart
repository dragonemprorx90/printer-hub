import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/moonraker.dart';
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
    expect(find.text('Odometer'.toUpperCase()), findsOneWidget);
    for (final tab in ['Maintenance', 'Filament', 'Notes', 'Quote', 'Calculators']) {
      await t.ensureVisible(find.text(tab)); // the tab bar scrolls on a phone
      await t.tap(find.text(tab));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: tab);
    }
    // The calculators work out answers from the defaults.
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == '7.500'), findsOneWidget);
  });
}
