import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/main.dart';
import 'package:sona/market_data/models.dart';

import 'screens_test.dart' show demoState, loadFonts;

const _steps = <String, Duration>{
  '1min': Duration(minutes: 1),
  '5min': Duration(minutes: 5),
  '1h': Duration(hours: 1),
  '4h': Duration(hours: 4),
  '1day': Duration(days: 1),
};

/// Deterministic bars whose spacing equals the requested candle size, so a
/// test can prove which interval the chart actually asked for and drew.
List<Candle> barsFor(String code) {
  final step = _steps[code] ?? const Duration(minutes: 15);
  final base = DateTime.utc(2026, 11, 2, 0, 0);
  var px = 3900.0;
  return List.generate(120, (i) {
    final o = px;
    final c = o + ((i % 7) - 3) * 0.8;
    px = c;
    return Candle(
      time: base.add(step * i),
      open: o,
      high: (o > c ? o : c) + 1.2,
      low: (o < c ? o : c) - 1.2,
      close: c,
    );
  });
}

CandlePainter painterOf(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((p) => p.painter)
    .whereType<CandlePainter>()
    .first;

Future<void> pickBar(WidgetTester t, String label) async {
  await t.tap(find.byType(PopupMenuButton<String>).first);
  await t.pumpAndSettle();
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
  });

  Future<
      ({
        ValueNotifier<int> tick,
        List<String> asked,
        void Function(double?, (int, int)?, List<SignalZone>?) set,
      })> pumpFullscreen(WidgetTester t) async {
    SharedPreferences.setMockInitialValues(
      {'trade_chart_mode_v1': 'sona'});
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    var live = 3900.0;
    (int, int)? stats = (0, 0);
    var zones = <SignalZone>[
      const SignalZone(isBuy: true, low: 3880, high: 3882),
    ];
    final tick = ValueNotifier<int>(0);
    final asked = <String>[];
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FullscreenChartPage(
          loader: (iv) async {
            asked.add(iv);
            return barsFor(iv);
          },
          rangeMode: true,
          livePrice: live,
          livePriceOf: () => live,
          signalStatsOf: () => stats,
          signalZonesOf: () => zones,
          quickTimeframes: true,
          marketUpdates: tick,
          marketSnapshot: () => ChartMarketSnapshot(
            price: live,
            fresh: true,
            bid: live - 0.3,
            ask: live + 0.3,
          ),
          onTradeSide: (_) {},
        ),
      ),
    );
    await t.pumpAndSettle();
    return (
      tick: tick,
      asked: asked,
      set: (p, s, z) {
        if (p != null) live = p;
        if (s != null) stats = s;
        if (z != null) zones = z;
        tick.value++;
      },
    );
  }

  testWidgets('fullscreen trade prices, count chip and signal boxes follow the '
      'live source after opening', (t) async {
    final h = await pumpFullscreen(t);
    expect(painterOf(t).signalStats, (0, 0));
    expect(painterOf(t).signalZones.single.isBuy, isTrue);
    expect(painterOf(t).signalZones.single.low, 3880);
    expect(find.text('3,899.70'), findsOneWidget);
    h.set(3850.25, (2, 1), [
      const SignalZone(isBuy: false, low: 3905, high: 3907),
      const SignalZone(isBuy: true, low: 3840, high: 3843),
    ]);
    await t.pumpAndSettle();
    expect(painterOf(t).signalStats, (2, 1));
    expect(painterOf(t).signalZones.length, 2);
    expect(painterOf(t).signalZones.first.isBuy, isFalse);
    expect(painterOf(t).signalZones.last.low, 3840);
    expect(find.text('3,849.95'), findsOneWidget);
    expect(find.text('3,899.70'), findsNothing);
  });

  testWidgets('1m/5m/1h/4h/1D menu picks load that exact candle size', (t) async {
    final h = await pumpFullscreen(t);
    final expected = <String, Duration>{
      '1m': _steps['1min']!,
      '5m': _steps['5min']!,
      '1h': _steps['1h']!,
      '4h': _steps['4h']!,
      '1D': _steps['1day']!,
    };
    final codes = {
      '1m': '1min',
      '5m': '5min',
      '1h': '1h',
      '4h': '4h',
      '1D': '1day',
    };
    for (final e in expected.entries) {
      await pickBar(t, e.key);
      final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
      expect(st.usingRange, isFalse, reason: e.key);
      expect(st.interval.code, codes[e.key], reason: e.key);
      expect(h.asked.last, codes[e.key], reason: e.key);
      expect(st.candles.length, greaterThan(10));
      expect(st.candles[1].time.difference(st.candles[0].time), e.value,
          reason: 'bars drawn for ${e.key} must be ${e.value} apart');
      expect(find.text('GOLD · ${e.key}'), findsOneWidget);
    }
  });

  testWidgets('a stretched price axis resets when the timeframe changes',
      (t) async {
    await pumpFullscreen(t);
    final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
    st.debugSetView(visibleCount: 60, scroll: 0);
    await t.pumpAndSettle();
    final rect = t.getRect(find.byType(CandleChartPanel));
    final g =
        await t.startGesture(Offset(rect.right - 20, rect.center.dy - 60));
    await t.pump();
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 12));
      await t.pump();
    }
    await g.up();
    await t.pumpAndSettle();
    expect(st.debugPriceScale, greaterThan(1.0));
    await pickBar(t, '5m');
    expect(st.debugPriceScale, 1.0);
  });

  testWidgets('Trade screen candle-size chips switch the real interval',
      (t) async {
    SharedPreferences.setMockInitialValues(
      {'trade_chart_mode_v1': 'sona'});
    final app = demoState();
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final asked = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: TradeTab(
            app: app,
            candleLoaderOverride: (iv) async {
              asked.add(iv);
              return barsFor(iv);
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    // The old history-range chips are gone from the Trade screen (user
    // request); only the candle-size chips remain.
    for (final gone in ['1H', '1W', '1M', '3M', '1Y']) {
      expect(find.text(gone), findsNothing, reason: 'range chip $gone');
    }
    final labels = {
      '1m': '1min',
      '5m': '5min',
      '1h': '1h',
      '4h': '4h',
      '1D': '1day',
    };
    for (final e in labels.entries) {
      await t.ensureVisible(find.byKey(ValueKey('trade-tf-${e.key}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('trade-tf-${e.key}')));
      await t.pumpAndSettle();
      final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
      expect(st.usingRange, isFalse, reason: e.key);
      expect(st.interval.code, e.value, reason: e.key);
      expect(asked.last, e.value, reason: e.key);
      expect(st.candles[1].time.difference(st.candles[0].time),
          _steps[e.value], reason: e.key);
    }
  });
}
