import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/strategy.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

List<Candle> fakeCandles(int n) {
  final rnd = math.Random(42);
  double px = 4100;
  final base = DateTime(2026, 10, 6, 9, 0);
  return List.generate(n, (i) {
    final o = px;
    final drift = (rnd.nextDouble() - 0.48) * 8;
    final c = o + drift;
    final h = math.max(o, c) + rnd.nextDouble() * 3;
    final l = math.min(o, c) - rnd.nextDouble() * 3;
    px = c;
    return Candle(
      time: base.add(Duration(minutes: 15 * i)),
      open: o,
      high: h,
      low: l,
      close: c,
    );
  });
}

void main() {
  Future<void> pumpEditor(WidgetTester tester, List<Candle> data) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FullscreenChartPage(
          loader: (iv) async => data,
          livePrice: data.last.close + 1.2,
          rangeMode: true,
          marketSnapshot: () => ChartMarketSnapshot(
            price: data.last.close,
            fresh: true,
            bid: data.last.close - 0.18,
            ask: data.last.close + 0.17,
          ),
          onTradeSide: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('editor undo/redo restores drawings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    final data = fakeCandles(120);
    await pumpEditor(tester, data);
    final panel = tester.state<CandleChartPanelState>(
      find.byType(CandleChartPanel),
    );
    expect(panel.trendLines, isEmpty);
    expect(panel.canUndo, isFalse);

    // Trend mode, then two anchor taps on the chart body.
    await tester.tap(find.byIcon(Icons.show_chart));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(CandleChartPanel));
    await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.top + 300));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.top + 380));
    await tester.pumpAndSettle();
    expect(panel.trendLines.length, 1);
    expect(panel.canUndo, isTrue);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(panel.trendLines, isEmpty);
    expect(panel.canRedo, isTrue);

    await tester.tap(find.byIcon(Icons.redo));
    await tester.pumpAndSettle();
    expect(panel.trendLines.length, 1);
  });

  testWidgets('editor templates save, list and apply', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    final data = fakeCandles(120);
    await pumpEditor(tester, data);
    final panel = tester.state<CandleChartPanelState>(
      find.byType(CandleChartPanel),
    );

    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pumpAndSettle();
    expect(find.text('Templates'), findsOneWidget);
    await tester.tap(find.text('Save current as template'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Scalp setup');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Turn an indicator on, then re-apply the template to restore.
    panel.setState(() => panel.rsiOn = true);
    await tester.pumpAndSettle();
    expect(panel.rsiOn, isTrue);

    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pumpAndSettle();
    expect(find.text('Scalp setup'), findsOneWidget);
    await tester.tap(find.text('Scalp setup'));
    await tester.pumpAndSettle();
    expect(panel.rsiOn, isFalse);

    // Persists on-device.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sona_chart_templates'), contains('Scalp setup'));
  });

  testWidgets(
      'v1.2.3: open-trade levels stay, strategy markers gone (golden)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await StrategyStore.save([
      PriceActionStrategy(id: 's1', name: 'Hourly high/low', notes: 'demo'),
    ]);
    await loadFonts();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final data = fakeCandles(120);
    final last = data.last.close;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FullscreenChartPage(
          loader: (iv) async => data,
          livePrice: last + 1.2,
          rangeMode: true,
          marketSnapshot: () => ChartMarketSnapshot(
            price: last,
            fresh: true,
            bid: last - 0.18,
            ask: last + 0.17,
            positions: [
              ChartPosition(
                buy: true,
                entry: last + 4,
                quantity: 1,
                stop: last - 9,
                target: last + 22,
                pnl: -3,
              ),
            ],
          ),
          onTradeSide: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(FullscreenChartPage),
      matchesGoldenFile('goldens/fullscreen_editor_positions.png'),
    );
  });

  testWidgets('fullscreen editor renders like the broker reference (golden)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final data = fakeCandles(120);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FullscreenChartPage(
          loader: (iv) async => data,
          livePrice: data.last.close + 1.2,
          rangeMode: true,
          marketSnapshot: () => ChartMarketSnapshot(
            price: data.last.close,
            fresh: true,
            bid: data.last.close - 0.18,
            ask: data.last.close + 0.17,
          ),
          onTradeSide: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Reference scaffold: GOLD header, Date Range / clock / auto bar,
    // floating SELL and BUY pills over the chart.
    expect(find.text('GOLD'), findsOneWidget);
    expect(find.text('Date Range'), findsOneWidget);
    expect(find.text('auto'), findsOneWidget);
    expect(find.text('SELL'), findsOneWidget);
    expect(find.text('BUY'), findsOneWidget);
    await expectLater(
      find.byType(FullscreenChartPage),
      matchesGoldenFile('goldens/fullscreen_editor.png'),
    );
  });
}
