import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
      open: o, high: h, low: l, close: c,
    );
  });
}

Widget harness(List<Candle> data, {double? bid, double? ask}) {
  final lastBid = bid ?? data.last.close;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: Center(
        child: SizedBox(
          width: 390,
          height: 480,
          child: CandleChartPanel(
            loader: (iv) async => data,
            livePrice: lastBid,
            marketSnapshot: () => ChartMarketSnapshot(
              price: lastBid,
              bid: bid,
              ask: ask,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('MT5 timeframe set M1..W1 is present', (tester) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data));
    await tester.pumpAndSettle();
    for (final tf in ['M1', 'M5', 'M15', 'M30', 'H1', 'H4', 'D1', 'W1']) {
      expect(find.text(tf), findsOneWidget, reason: 'missing $tf');
    }
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/xm360_timeframes.png'),
    );
  });

  testWidgets('crosshair toggle + drag shows price and time tags', (
    tester,
  ) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data, ask: data.last.close + 3.5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Crosshair'));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CustomPaint).first);
    await tester.dragFrom(
      center - const Offset(60, 30),
      const Offset(80, 40),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/xm360_crosshair.png'),
    );
  });

  testWidgets('Heikin Ashi chart type renders', (tester) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Candles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heikin Ashi').last);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/xm360_heikin.png'),
    );
  });

  testWidgets('bid and ask lines with right-axis tags', (tester) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data, ask: data.last.close + 3.5));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/xm360_bidask.png'),
    );
  });
}
