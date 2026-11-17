import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/market_data/twelve_data_candles.dart';

import 'zz_placeholder_fix_capture_test.dart' show loadFonts;

/// Visual proof aid for the Nov 16 fullscreen fixes, NOT a release gate.
/// Real Twelve Data XAU/USD session bars from test/fixtures. No-op unless
/// FIX_PREVIEW=1 (then run with --update-goldens).
void main() {
  final capture = Platform.environment['FIX_PREVIEW'] == '1';

  testWidgets('fullscreen: live header, chip under heading, timeframes',
      (tester) async {
    if (!capture) return;
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    final raw = jsonDecode(
        File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
    final values = (raw['values'] as List).cast<Map<String, dynamic>>();
    final all = <Candle>[
      for (final v in values)
        Candle(
          time: DateTime.parse(
                  '${(v['datetime'] as String).replaceFirst(' ', 'T')}Z')
              .toLocal(),
          open: double.parse(v['open'] as String),
          high: double.parse(v['high'] as String),
          low: double.parse(v['low'] as String),
          close: double.parse(v['close'] as String),
        ),
    ]..sort((a, b) => a.time.compareTo(b.time));
    final data = dropClosedMarketPlaceholders(all);
    final tail = data.sublist(data.length - 40);
    final lo = tail.map((c) => c.low).reduce(math.min);
    final hi = tail.map((c) => c.high).reduce(math.max);

    var live = data.last.close;
    (int, int) stats = (0, 0);
    final tick = ValueNotifier<int>(0);
    final requested = <String>[];
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
        home: FullscreenChartPage(
          loader: (iv) async {
            requested.add(iv);
            return data;
          },
          rangeMode: true,
          livePrice: live,
          signalStats: stats,
          livePriceOf: () => live,
          signalStatsOf: () => stats,
          signalZonesOf: () => [
            SignalZone(isBuy: true, low: lo - 2.0, high: lo + 1.0),
          ],
          quickTimeframes: true,
          marketUpdates: tick,
          marketSnapshot: () => ChartMarketSnapshot(
            price: live,
            fresh: true,
            bid: live - 0.33,
            ask: live + 0.33,
          ),
          onTradeSide: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(find.byType(FullscreenChartPage),
        matchesGoldenFile('goldens/fix_fullscreen_1_open.png'));
    final openText = CandlePainter.fmtAxisPrice(live);
    expect(find.textContaining(openText), findsWidgets);

    // Market moves while fullscreen stays open: header must follow.
    live = hi + 9.0;
    stats = (1, 2);
    tick.value++;
    await tester.pumpAndSettle();
    expect(find.textContaining(CandlePainter.fmtAxisPrice(live)), findsWidgets);
    await expectLater(find.byType(FullscreenChartPage),
        matchesGoldenFile('goldens/fix_fullscreen_2_after_tick.png'));

    // Candle-size chips.
    for (final label in ['1m', '5m', '1h', '4h', '1D']) {
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await expectLater(find.byType(FullscreenChartPage),
          matchesGoldenFile('goldens/fix_fullscreen_3_tf_$label.png'));
    }
    expect(requested, containsAll(['1min', '5min', '1h', '4h', '1day']));
  });
}
