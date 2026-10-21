import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sona/backtest.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/main.dart';
import 'package:sona/strategies_screen.dart';
import 'package:sona/strategy.dart';

import 'candle_chart_test.dart' show fakeCandles, loadFonts;

Future<File> snap(GlobalKey key, String path) async {
  final im = await (key.currentContext!.findRenderObject()
          as RenderRepaintBoundary)
      .toImage(pixelRatio: 2);
  final b = await im.toByteData(format: ui.ImageByteFormat.png);
  return File(path).writeAsBytes(b!.buffer.asUint8List());
}

void main() {
  testWidgets('strategies screen: add, toggle, delete', (t) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: StrategiesScreen(app: AppState()),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('No strategies yet'), findsOneWidget);

    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    expect(find.text('Add strategy'), findsOneWidget);
    await t.enterText(find.byType(TextField).first, 'London 1H break');
    // real-size editor render for spacing review (v1.0.97 fix)
    await t.runAsync(() => snap(key, '/tmp/sona-v1097-editor.png'));
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(find.text('London 1H break'), findsOneWidget);
    expect(find.byTooltip('Run backtest (1 month)'), findsOneWidget);
    await t.runAsync(() => snap(key, '/tmp/sona-v1096-strategies.png'));

    // Persisted?
    final saved = await StrategyStore.load();
    expect(saved.single.name, 'London 1H break');
    expect(saved.single.showOnChart, isTrue);

    // Toggle show-on-chart off and back on.
    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();
    expect((await StrategyStore.load()).single.showOnChart, isFalse);

    // Long-press deletes with a confirm dialog.
    await t.longPress(find.text('London 1H break'));
    await t.pumpAndSettle();
    expect(find.text('Delete London 1H break?'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.textContaining('No strategies yet'), findsOneWidget);
    expect(await StrategyStore.load(), isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'strategy levels stay off the chart (v1.2.3 clean-chart directive, golden)',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    await StrategyStore.save([
      PriceActionStrategy(id: 's1', name: 'Hourly high/low', notes: 'demo'),
    ]);
    await loadFonts();
    final data = fakeCandles(80);
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFF0F1115),
            body: Center(
              child: SizedBox(
                width: 380,
                height: 420,
                child: CandleChartPanel(
                  loader: (iv) async => data,
                  livePrice: data.last.close + 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/chart_strategy_levels.png'), // now: clean chart, no strategy lines
    );
    await t.runAsync(() => snap(key, '/tmp/sona-v1096-chart-levels.png'));
    expect(t.takeException(), isNull);
  });

  test('strategy levels outside the visible price range never draw', () {
    // v1.0.97 regression: off-range 1H levels drew over the GOLD header
    // above the chart card on a real phone. Paint into a recording canvas
    // and assert every line stays inside the plot rect.
    final data = fakeCandles(60);
    var hi = 0.0, lo = double.infinity;
    for (final c in data) {
      if (c.high > hi) hi = c.high;
      if (c.low < lo) lo = c.low;
    }
    final painter = CandlePainter(
      candles: data,
      visibleCount: data.length,
      strategySegments: [
        StrategyLevelSegment(
            price: hi + 300, isHigh: true, startIdx: 2, endIdx: 40),
        StrategyLevelSegment(
            price: lo - 300, isHigh: false, startIdx: 2, endIdx: 40),
        StrategyLevelSegment(
            price: (hi + lo) / 2, isHigh: true, startIdx: 2, endIdx: 40),
      ],
    );
    final canvas = TestRecordingCanvas();
    painter.paint(canvas, const Size(400, 300));
    const plotH = 300 - 16.0; // size.height - bottomPad (no rsi/macd pane)
    var sawInRange = false;
    for (final rec in canvas.invocations) {
      final call = rec.invocation;
      if (call.memberName == #drawLine) {
        final p1 = call.positionalArguments[0] as Offset;
        final p2 = call.positionalArguments[1] as Offset;
        expect(p1.dy, inClosedOpenRange(-0.001, plotH + 0.001),
            reason: 'line start above/below the plot rect');
        expect(p2.dy, inClosedOpenRange(-0.001, plotH + 0.001),
            reason: 'line end above/below the plot rect');
        if ((p1.dy - plotH / 2).abs() < 5) sawInRange = true;
      }
    }
    expect(sawInRange, isTrue,
        reason: 'the in-range level should still be drawn');
  });

  testWidgets('backtest result screen renders stats and equity curve',
      (t) async {
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final st = PriceActionStrategy(id: 's1', name: 'London 1H break', notes: 'demo');
    final base = DateTime(2026, 10, 5, 8, 0);
    final trades = <BacktestTrade>[
      for (var i = 0; i < 8; i++)
        BacktestTrade(
          long: i.isEven,
          entryTime: base.add(Duration(hours: i * 3)),
          entry: 4100 + i * 4,
          exitTime: base.add(Duration(hours: i * 3 + 2)),
          exit: 4100 + i * 4 + ((i % 3 == 0 ? -6.0 : 9.0) * (i.isEven ? 1 : -1)),
          exitReason: i % 3 == 0 ? 'SL' : 'TP',
        ),
    ];
    final result = BacktestResult(trades, base, base.add(const Duration(days: 3)));
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: BacktestResultScreen(strategy: st, result: result),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Backtest: London 1H break'), findsOneWidget);
    expect(find.text('Win rate'), findsOneWidget);
    expect(find.text('Net points'), findsOneWidget);
    await t.runAsync(() => snap(key, '/tmp/sona-v1096-backtest.png'));
    expect(t.takeException(), isNull);
  });
}
