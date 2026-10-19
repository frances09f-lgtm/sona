import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show loadFonts;
import 'chart_upgrade_test.dart' show painter;

void main() {
  testWidgets(
    '3 consecutive minute rollovers: one forming bar, open == prior close, close == line',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      final t0 = DateTime.now();
      // Provider 1m history ending 2.5 min ago (feed lag), flat-ish real ranges.
      final bars = List.generate(
        40,
        (i) => Candle(
          time: t0.subtract(Duration(seconds: 150 + 60 * (39 - i))),
          open: 4160.0,
          high: 4160.3,
          low: 4159.8,
          close: 4160.1,
          volume: 1,
        ),
      );
      // Ticks walking up across the last 3 minute windows.
      final ticks = <(int, double)>[
        for (var s = 175; s >= 1; s -= 5)
          (
            t0.subtract(Duration(seconds: s)).millisecondsSinceEpoch,
            4160.1 + (175 - s) * 0.004,
          ),
      ];
      const live = 4160.1 + 174 * 0.004;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CandleChartPanel(
              rangeMode: true,
              loader: (_) async => bars,
              marketSnapshot: () => ChartMarketSnapshot(
                price: live,
                fresh: true,
                liveTicks: ticks,
              ),
              livePrice: live,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
      // ignore: invalid_use_of_protected_member
      st.setState(() => st.interval = tradeRanges[0]); // 1H -> 1m bars
      await t.pumpAndSettle();
      final p = painter(t);
      final cs = p.candles;
      // 40 provider bars + tick-built bars for the covered minutes + forming.
      final added = cs.length - 40;
      expect(added, greaterThanOrEqualTo(2));
      // Every tick-built bar opens at the previous bar's close.
      for (var i = 40; i < cs.length; i++) {
        expect(cs[i].open, closeTo(cs[i - 1].close, 1e-9),
            reason: 'bar $i open != prior close');
      }
      // Forming bar: close == line, and it is the LAST bar (exactly one).
      expect(cs.last.close, live);
      expect(p.livePrice, live);
      // Forming bar is inside the visible window.
      expect(p.firstVisible + p.visibleCount, greaterThanOrEqualTo(cs.length));
      // High/low never exceed the real tick extremes plus the anchor chain.
      final tickHi = ticks.map((e) => e.$2).reduce((a, b) => a > b ? a : b);
      final tickLo = ticks.map((e) => e.$2).reduce((a, b) => a < b ? a : b);
      final anchor = bars.last.close;
      var hiBound = tickHi > anchor ? tickHi : anchor;
      if (live > hiBound) hiBound = live;
      final loBound = tickLo < anchor ? tickLo : anchor;
      for (var i = 40; i < cs.length; i++) {
        expect(cs[i].high, lessThanOrEqualTo(hiBound + 1e-9));
        expect(cs[i].low, greaterThanOrEqualTo(loBound - 1e-9));
      }
      await t.pumpWidget(const SizedBox());
    },
  );
}
