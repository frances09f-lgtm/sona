import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAccount extends AppState {
  int calls = 0;
  String? side;
  double? qty, take, stop;
  @override
  bool get priceFresh => true;
  @override
  Future<String?> openPaper(String d, double q, double? tp, double? sl) async {
    calls++;
    side = d;
    qty = q;
    take = tp;
    stop = sl;
    return null;
  }
}

void main() {
  testWidgets(
    'sheet trades only on submit with user quantity and optional protection',
    (t) async {
      final app = FakeAccount()
        ..bid = 4000
        ..ask = 4001
        ..price = 4000.5
        ..priceOk = true
        ..priceAt = DateTime.now().millisecondsSinceEpoch;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaperOrderSheet(app: app, side: 'sell'),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(app.calls, 0);
      await t.enterText(find.byType(TextField).first, '0.0025'); // lots = 0.25 oz
      await t.tap(find.byType(Switch).last);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), '3990');
      await t.enterText(find.byType(TextField).at(2), '4010');
      await t.ensureVisible(find.text('Place Order at 4000.00'));
    await t.tap(find.text('Place Order at 4000.00'));
      await t.pumpAndSettle();
      expect(app.calls, 1);
      expect(app.side, 'sell');
      expect(app.qty, .25);
      expect(app.take, 3990);
      expect(app.stop, 4010);
    },
  );
  testWidgets('remembers last placed lot size and prefills next open',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Future<void> openSheet(AppState app, String side) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => showModalBottomSheet(
                    context: ctx,
                    isScrollControlled: true,
                    builder: (_) => PaperOrderSheet(app: app, side: side),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    final app = FakeAccount()
      ..bid = 4000
      ..ask = 4001
      ..price = 4000.5
      ..priceOk = true
      ..priceAt = DateTime.now().millisecondsSinceEpoch;
    app.prefs = prefs;
    await openSheet(app, 'sell');
    // First open ever: default 0.01, no memory caption value.
    expect(find.text('Last used: none yet'), findsOneWidget);
    await t.enterText(find.byType(TextField).first, '0.05');
    await t.ensureVisible(find.text('Place Order at 4000.00'));
    await t.tap(find.text('Place Order at 4000.00'));
    await t.pumpAndSettle();
    expect(app.qty, 5);
    expect(prefs.getDouble('tj_last_lots'), 0.05);

    // Reopen: prefilled with the last placed size.
    final app2 = FakeAccount()
      ..bid = 4000
      ..ask = 4001
      ..price = 4000.5
      ..priceOk = true
      ..priceAt = DateTime.now().millisecondsSinceEpoch;
    app2.prefs = prefs;
    await openSheet(app2, 'buy');
    final field = t.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, '0.05');
    expect(
      find.text('Last used: 0.05 lots · remembered on this phone'),
      findsOneWidget,
    );
  });
}
