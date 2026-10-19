import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';
import 'package:sona/position_precision.dart';
import 'package:sona/paper_margin.dart';
import 'package:sona/trade_safety.dart';

import 'screens_test.dart' show loadFonts;

Map<String, dynamic> position(
  Object? qty, {
  String side = 'buy',
  double entry = 4185,
}) => {
  'id': '$side-$qty',
  'status': 'open',
  'direction': side,
  'entry': entry,
  'qty': qty,
  'tp': null,
  'sl': null,
};
AppState account() => AppState()
  ..price = 4185.68
  ..bid = 4185.35
  ..ask = 4186.01
  ..priceOk = true
  ..priceAt = DateTime.now().millisecondsSinceEpoch;
Future<void> capture(WidgetTester t, GlobalKey key, String name) async {
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/sona-$name-synthetic.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test('ounce display never turns valid small quantity into zero', () {
    expect(formatOz(1), '1.00');
    expect(formatOz(.01), '0.01');
    expect(formatOz(.000239), '0.000239');
    for (final q in [1e-9, .000000015, .000239, .0049]) {
      expect(double.parse(formatOz(q)), greaterThan(0));
    }
    for (final q in [null, 0, -1, double.nan, double.infinity, 'invalid']) {
      expect(formatOz(q), 'Unknown size');
    }
    expect(formatOz('0.000239'), '0.000239');
  });
  test('subcent P/L keeps sign, exact zero and unavailable are distinct', () {
    expect(formatPaperMoney(.0001, sign: true), '+<\$0.01');
    expect(formatPaperMoney(-.0001, sign: true), '-<\$0.01');
    expect(formatPaperMoney(0, sign: true), '\$0.00');
    expect(formatPaperMoney(null, sign: true), '-');
    expect(formatPaperMoney(double.nan), '-');
    expect(formatPaperMoney(1.25, sign: true), '+\$1.25');
  });
  test('actual buy and sell mark paths preserve size and spread units', () {
    final app = account();
    final q = (10 * 10 / 100) / 4186.01;
    expect(app.livePnl(position(q)), closeTo((4185.35 - 4185) * q, 1e-12));
    expect(
      app.livePnl(position(q, side: 'sell')),
      closeTo((4185 - 4186.01) * q, 1e-12),
    );
    expect(app.livePnl(position(q, entry: 4186.01)), lessThan(0));
    expect(pnlAtLevel(position(q), 4188), closeTo(3 * q, 1e-12));
    final riskQty = quantityForRisk(.01, 'buy', 4186.01, 4182.01)!;
    expect(riskQty, closeTo(.0025, 1e-8));
    expect(formatOz(riskQty), '0.0025');
    app.dispose();
  });
  test(
    'legacy JSON roundtrip does not guess or overwrite unknown quantities',
    () {
      for (final q in [null, 0, -1, 'bad', 'NaN', 'Infinity']) {
        final record = Map<String, dynamic>.from(
          jsonDecode(jsonEncode(position(q))),
        );
        final before = jsonEncode(record);
        final app = account()
          ..positions = [record, position(.000239, side: 'sell')];
        expect(app.livePnl(record), isNull);
        expect(app.floatPnl(), isNull);
        expect(
          PaperMargin.estimate(
            balance: 10,
            bid: 4185.35,
            ask: 4186.01,
            positions: app.positions,
          ),
          isNull,
        );
        expect(jsonEncode(record), before);
        app.dispose();
      }
      final app = account();
      final record = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(position('0.000239'))),
      );
      expect(app.livePnl(record), closeTo(.35 * .000239, 1e-12));
      expect(record['qty'], '0.000239');
      app.dispose();
    },
  );
  test('invalid legacy position cannot submit a foreground close', () async {
    final app = account()..unlocked = true;
    for (final q in [null, 0, -1, 'bad', double.nan, double.infinity]) {
      expect(
        await app.closePaper(position(q)),
        'Position size or entry unavailable. No close submitted.',
      );
      expect(app.closing, isEmpty);
    }
    app.dispose();
  });
  testWidgets(
    'real Portfolio displays small positions without zero ounces or zero P/L',
    (t) async {
      t.view.physicalSize = const Size(780, 1688);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await loadFonts();
      final app = account()
        ..positions = [position(.000239), position('0.0025', side: 'sell')];
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  const Text('SYNTHETIC TEST POSITIONS'),
                  Expanded(child: PositionsTab(app: app)),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('0.000239 oz  BUY'), findsOneWidget);
      expect(find.text('0.0025 oz  SELL'), findsOneWidget);
      expect(find.text('+<\$0.01'), findsOneWidget);
      expect(find.text('-<\$0.01'), findsOneWidget);
      expect(find.text('0.00 oz  BUY'), findsNothing);
      expect(find.text('+\$0.00'), findsNothing);
      await capture(t, key, 'precision-compact');
      await t.tap(find.byKey(ValueKey('open-position-buy-0.000239')));
      await t.pumpAndSettle();
      expect(find.text('0.000239 Troy Ounces'), findsOneWidget);
      expect(t.takeException(), isNull);
      await capture(t, key, 'precision-expanded');
      t.view.physicalSize = const Size(640, 1280);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      app.dispose();
    },
  );
  testWidgets(
    'missing/zero legacy size stays unknown and expansion does not crash',
    (t) async {
      final app = account()..positions = [position(0)];
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: PositionsTab(app: app)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Unknown size  BUY'), findsOneWidget);
      await t.tap(find.byKey(ValueKey('open-position-buy-0')));
      await t.pumpAndSettle();
      expect(
        find.text('Risk unavailable: size or entry unknown'),
        findsOneWidget,
      );
      final close = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Close Trade: -'),
      );
      expect(close.onPressed, isNull);
      expect(t.takeException(), isNull);
      app.dispose();
    },
  );
}
