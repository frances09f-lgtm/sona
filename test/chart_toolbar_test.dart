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
    expect(find.text('1D range'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('5m'));
    await tester.pumpAndSettle();
    expect(panel.usingRange, isFalse);
    expect(panel.interval.code, '5min');
    expect(find.text('GOLD · 5m'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('5m'), findsWidgets);
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

  testWidgets('a far-away signal box does not stretch the price axis',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final data = fakeCandles(96);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FullscreenChartPage(
          loader: (iv) async => data,
          livePrice: data.last.close,
          rangeMode: true,
          signalZones: const [
            SignalZone(isBuy: false, low: 4400, high: 4410),
            SignalZone(isBuy: true, low: 3700, high: 3710),
          ],
          onTradeSide: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('4,400'), findsNothing);
    expect(find.textContaining('3,700'), findsNothing);
    final hi = data.map((c) => c.high).reduce((a, b) => a > b ? a : b);
    final lo = data.map((c) => c.low).reduce((a, b) => a < b ? a : b);
    // Every price label on the axis lies near the candles, not near 4400.
    final labels = find.textContaining(RegExp(r'^\d,\d{3}\.00$'));
    for (final e in labels.evaluate()) {
      final v =
          double.parse((e.widget as Text).data!.replaceAll(',', ''));
      expect(v, inInclusiveRange(lo - 40, hi + 40));
    }
  });

  test('axis extent: far boxes ignored, overlapping and near boxes kept', () {
    const far = SignalZone(isBuy: false, low: 4400, high: 4410);
    const farLow = SignalZone(isBuy: true, low: 3700, high: 3710);
    const inside = SignalZone(isBuy: true, low: 3860, high: 3865);
    const near = SignalZone(isBuy: false, low: 3893, high: 3897);
    expect(axisExtentWithZones(3892, 3855, [far, farLow]), (3892.0, 3855.0));
    expect(axisExtentWithZones(3892, 3855, [inside]), (3892.0, 3855.0));
    expect(axisExtentWithZones(3892, 3855, [near]), (3897.0, 3855.0));
    expect(axisExtentWithZones(3892, 3855, [far, near, farLow]),
        (3897.0, 3855.0));
  });
}
