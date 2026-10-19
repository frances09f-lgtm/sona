import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show loadFonts;
import 'chart_upgrade_test.dart' show painter, capture;

// Reproduces the user's production condition with a REAL live quote:
// TwelveData 1m candles ending a couple of minutes ago (feed lag), live
// bid from Swissquote. The last drawn candle must meet the yellow line.
void main() {
  testWidgets('real quote: forming candle meets the live line (1H range)', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    const bid = 4159.925;
    final now = DateTime.now();
    // 60 one-minute bars ending 2 minutes ago, prices around the real bid.
    final bars = List.generate(60, (i) {
      final start = now.subtract(Duration(minutes: 62 - i));
      final wobble = (i % 7 - 3) * 0.05;
      return Candle(
        time: start,
        open: bid - 0.3 + wobble,
        high: bid - 0.1 + wobble,
        low: bid - 0.6 + wobble,
        close: bid - 0.4 + wobble,
        volume: 1,
      );
    });
    final key = GlobalKey();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: CandleChartPanel(
              rangeMode: true,
              loader: (_) async => bars,
              marketSnapshot: () => const ChartMarketSnapshot(
                price: bid,
                fresh: true,
              ),
              livePrice: bid,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final cs = painter(t).candles;
    final p = painter(t);
    print('LIVE_CHECK livePrice=${p.livePrice} lastClose=${cs.last.close} '
        'lastTime=${cs.last.time} n=${cs.length}');
    expect(cs.last.close, bid);
    await capture(t, key, 'repro-live-line');
    await t.pumpWidget(const SizedBox());
  });
}
