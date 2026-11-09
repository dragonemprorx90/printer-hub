import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printer_hub/ui.dart';

double _opacity(WidgetTester t) =>
    t.widget<Opacity>(find.descendant(of: find.byType(Reveal), matching: find.byType(Opacity))).opacity;

Widget _app(int epoch, {bool reduce = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: RevealScope(epoch: epoch, child: const Reveal(index: 2, child: Text('x'))),
      ),
    );

void main() {
  testWidgets('Reveal enters after its stagger delay and replays on a new epoch', (t) async {
    await t.pumpWidget(_app(0));
    expect(_opacity(t), 0);
    await t.pump(const Duration(milliseconds: 100)); // past the 2-step delay
    await t.pumpAndSettle();
    expect(_opacity(t), 1);

    await t.pumpWidget(_app(1)); // tab shown again
    expect(_opacity(t), 0);
    await t.pump(const Duration(milliseconds: 100)); // past the 2-step delay
    await t.pumpAndSettle();
    expect(_opacity(t), 1);
  });

  testWidgets('Reveal shows at once with reduced motion', (t) async {
    await t.pumpWidget(_app(0, reduce: true));
    expect(_opacity(t), 1);
  });
}
