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
      open: o,
      high: h,
      low: l,
      close: c,
    );
  });
}

void main() {
  testWidgets('fullscreen editor renders like the broker reference (golden)',
      (tester) async {
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
