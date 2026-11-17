import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/market_data/models.dart';

import 'fullscreen_editor_test.dart' show fakeCandles, loadFonts;

void main() {
  Future<CandleChartPanelState> pump(
      WidgetTester tester, List<Candle> data) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
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
          quickTimeframes: true,
          onTradeSide: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<CandleChartPanelState>(find.byType(CandleChartPanel));
  }

  testWidgets('no separate timeframe chip row; 1D range shows 15m candles',
      (tester) async {
    final panel = await pump(tester, fakeCandles(120));
    expect(find.byKey(const ValueKey('tf-5m')), findsNothing);
    expect(find.byKey(const ValueKey('tf-1D')), findsNothing);
    expect(panel.usingRange, isTrue);
    expect(tradeRangeSpec('range:1D').$1, '15min');
    expect(find.text('GOLD · 15m'), findsOneWidget);
    expect(find.text('15m'), findsOneWidget);
  });

  testWidgets('toolbar menu picks candle size and marks the current one',
      (tester) async {
    final panel = await pump(tester, fakeCandles(120));
    await tester.tap(find.text('15m'));
    await tester.pumpAndSettle();
    expect(find.text('\u2713 1D range'), findsOneWidget);
    await tester.tap(find.text('5m'));
    await tester.pumpAndSettle();
    expect(panel.usingRange, isFalse);
    expect(panel.interval.code, '5min');
    expect(find.text('GOLD · 5m'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('\u2713 5m'), findsOneWidget);
  });

  testWidgets('existing indicator menu (sigma) still toggles SMA 20',
      (tester) async {
    final panel = await pump(tester, fakeCandles(120));
    expect(panel.smaOn, isFalse);
    await tester.tap(find.byIcon(Icons.functions));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SMA 20'));
    await tester.pumpAndSettle();
    expect(panel.smaOn, isTrue);
  });
}
