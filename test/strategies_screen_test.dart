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

  testWidgets('chart shows 1H strategy levels (golden)', (t) async {
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
      matchesGoldenFile('goldens/chart_strategy_levels.png'),
    );
    await t.runAsync(() => snap(key, '/tmp/sona-v1096-chart-levels.png'));
    expect(t.takeException(), isNull);
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
