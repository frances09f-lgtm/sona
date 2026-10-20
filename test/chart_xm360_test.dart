import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  testWidgets('chart card is clean: no interval or range chips', (
    tester,
  ) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data));
    await tester.pumpAndSettle();
    for (final tf in ['M1', 'M5', 'M15', 'M30', 'H1', 'H4', 'D1', 'W1']) {
      expect(find.text(tf), findsNothing, reason: '$tf should be in Settings');
    }
    expect(find.text('Candle intervals'), findsNothing);
    expect(find.text('History ranges'), findsNothing);
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/xm360_timeframes.png'),
    );
  });

  testWidgets('crosshair toggle + drag shows price and time tags', (
    tester,
  ) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({kChartShowAskPref: true});
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
    SharedPreferences.setMockInitialValues({kChartShowAskPref: true});
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data, ask: data.last.close + 3.5));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/xm360_bidask.png'),
    );
  });

  CandlePainter chartPainter(WidgetTester tester) {
    final paints = tester.widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(CandleChartPanel),
        matching: find.byType(CustomPaint),
      ),
    );
    return paints
        .map((p) => p.painter)
        .whereType<CandlePainter>()
        .firstWhere((p) => p.candles.isNotEmpty);
  }

  testWidgets('ask line is hidden by default', (tester) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({});
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data, ask: data.last.close + 3.5));
    await tester.pumpAndSettle();
    expect(chartPainter(tester).ask, isNull);
  });

  testWidgets('ask line shows when the Settings pref is on', (tester) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({kChartShowAskPref: true});
    final data = fakeCandles(80);
    final ask = data.last.close + 3.5;
    await tester.pumpWidget(harness(data, ask: ask));
    await tester.pumpAndSettle();
    expect(chartPainter(tester).ask, ask);
  });

  testWidgets('fresh chart has no indicators by default (XM-style)', (
    tester,
  ) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(harness(data));
    await tester.pumpAndSettle();
    final state = tester.state<CandleChartPanelState>(
      find.byType(CandleChartPanel),
    );
    expect(state.smaOn, isFalse);
    expect(state.emaOn, isFalse);
    expect(state.sma200On, isFalse);
    expect(state.rsiOn, isFalse);
    expect(state.macdOn, isFalse);
    expect(state.bollingerOn, isFalse);
  });

  testWidgets('pre-v2 saved layout loses the old default SMA/EMA once', (
    tester,
  ) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 480,
            child: CandleChartPanel(
              loader: (iv) async => data,
              initialLayout: {
                'sma20': true, // old default, saved by <=1.0.92
                'ema50': true,
                'rsi': true, // explicit user choice survives
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<CandleChartPanelState>(
      find.byType(CandleChartPanel),
    );
    expect(state.smaOn, isFalse, reason: 'old default reset once');
    expect(state.emaOn, isFalse, reason: 'old default reset once');
    expect(state.rsiOn, isTrue, reason: 'explicit choice survives');
  });

  testWidgets('Settings has a Chart section with interval and range pickers', (
    tester,
  ) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: SonaSettingsScreen(app: AppState()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chart'), findsOneWidget);
    expect(find.text('Candle interval'), findsOneWidget);
    expect(find.text('History range'), findsOneWidget);
    await expectLater(
      find.byType(SonaSettingsScreen),
      matchesGoldenFile('goldens/xm360_settings_chart.png'),
    );
    // Pick a history range: mode flips to range and persists.
    await tester.tap(find.text('History range'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1W').last);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kChartModePref), 'range');
    expect(prefs.getString(kChartRangePref), 'range:1W');
    expect(prefs.getInt(kChartSelectionRevPref), 1);
    // Pick a candle interval: mode flips back to candles.
    await tester.tap(find.text('Candle interval'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('M5').last);
    await tester.pumpAndSettle();
    final prefs2 = await SharedPreferences.getInstance();
    expect(prefs2.getString(kChartModePref), 'candles');
    expect(prefs2.getString(kChartIntervalPref), '5min');
    expect(prefs2.getInt(kChartSelectionRevPref), 2);
  });
}
