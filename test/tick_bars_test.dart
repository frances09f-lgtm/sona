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
    'live ticks never rewrite or append provider candles',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      final t0 = CandleChartPanelState.chartNow();
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
      expect(cs.length, bars.length);
      expect(cs.map((c) => (c.time,c.open,c.high,c.low,c.close,c.volume)).toList(),
          bars.map((c) => (c.time,c.open,c.high,c.low,c.close,c.volume)).toList());
      expect(p.livePrice, live);
      expect(cs.last.close, isNot(live));
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('forming provider OHLC survives extreme live ticks and a missing interval', (t) async {
    SharedPreferences.setMockInitialValues({}); await loadFonts();
    final now=CandleChartPanelState.chartNow();
    final bars=[
      Candle(time:now.subtract(const Duration(minutes:40)),open:100,high:110,low:90,close:105),
      Candle(time:now.subtract(const Duration(minutes:2)),open:106,high:108,low:104,close:107),
    ];
    await t.pumpWidget(MaterialApp(home:Scaffold(body:CandleChartPanel(
      loader:(_) async=>bars,
      marketSnapshot:()=>ChartMarketSnapshot(price:150,fresh:true,liveTicks:[(now.millisecondsSinceEpoch,150),(now.subtract(const Duration(seconds:1)).millisecondsSinceEpoch,50)]),
    ))));
    await t.pumpAndSettle();final p=painter(t);
    expect(p.candles.length,2);
    expect(p.candles.last.open,106);expect(p.candles.last.high,108);
    expect(p.candles.last.low,104);expect(p.candles.last.close,107);
    expect(p.livePrice,150);
    await t.pumpWidget(const SizedBox());
  });

}
