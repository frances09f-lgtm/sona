import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/chart/indicators.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show fakeCandles, loadFonts;

CandlePainter painter(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<CandlePainter>()
    .last;
Future<void> capture(WidgetTester t, GlobalKey key, String name) async {
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/sona-chart-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test('trade overlay labels avoid collisions at plot edges', () {
    final used = <double>[];
    for (final priceY in [999.0, 999.0, -99.0, -99.0, 40.0, 40.0]) {
      final slot = overlayLabelY(priceY, 100, used)!;
      expect(used.every((v) => (slot - v).abs() >= 12), true);
      used.add(slot);
    }
  });
  testWidgets('history ranges fullscreen and mode changes stay usable', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(820, 390));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final key = GlobalKey<CandleChartPanelState>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CandleChartPanel(
              key: key,
              rangeMode: true,
              loader: (_) async => fakeCandles(100),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.fullscreen));
    await t.pumpAndSettle();
    expect(find.text('1Y').last, findsOneWidget);
    await t.tap(find.text('1M').last);
    await t.pumpAndSettle();
    final full = t.state<CandleChartPanelState>(
      find.byType(CandleChartPanel).last,
    );
    expect(full.interval.code, 'range:1M');
    await t.tap(find.text('Candle intervals').last);
    await t.pumpAndSettle();
    await t.tap(find.text('4H').last);
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.fullscreen_exit));
    await t.pumpAndSettle();
    expect(key.currentState!.usingRange, false);
    expect(key.currentState!.interval.code, '4h');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  test('indicator math: custom MACD, warmup, invalid input, flat RSI', () {
    final data = List.generate(
      20,
      (i) => Candle(
        time: DateTime.utc(2026).add(Duration(minutes: i)),
        open: 100 + i.toDouble(),
        high: 100 + i.toDouble(),
        low: 100 + i.toDouble(),
        close: 100 + i.toDouble(),
      ),
    );
    final m = macd(data, fast: 3, slow: 5, signalPeriod: 2);
    expect(m.$1.length, 16);
    expect(m.$2.length, 15);
    expect(m.$1.every((v) => (v - 1).abs() < 1e-8), true);
    expect(m.$3.every((v) => v.abs() < 1e-8), true);
    expect(macd(data.take(4).toList(), fast: 3, slow: 5).$1, isEmpty);
    expect(macd(data, fast: 5, slow: 3).$1, isEmpty);
    expect(
      macd(data.take(5).toList(), fast: 3, slow: 5, signalPeriod: 2).$2,
      isEmpty,
    );
    final flat = List.generate(
      20,
      (i) => Candle(
        time: DateTime.utc(2026).add(Duration(minutes: i)),
        open: 100,
        high: 100,
        low: 100,
        close: 100,
      ),
    );
    expect(rsi(flat, 14), everyElement(50));
    final bad = [
      ...data,
      Candle(
        time: DateTime(2026),
        open: 100,
        high: 100,
        low: 100,
        close: double.nan,
      ),
    ];
    expect(ema(bad, 3), isEmpty);
    expect(rsi(bad, 3), isEmpty);
    expect(macd(bad).$1, isEmpty);
  });
  test('paper overlays validate records, side/quantity PnL, stale marks', () {
    Map<String, dynamic> record(String d) => {
      'status': 'open',
      'direction': d,
      'entry': 100,
      'qty': 2,
      'sl': 95,
      'tp': 110,
    };
    expect(
      ChartPosition.fromRecord(record('buy'), mark: 102, fresh: true)!.pnl,
      4,
    );
    expect(
      ChartPosition.fromRecord(record('sell'), mark: 102, fresh: true)!.pnl,
      -4,
    );
    expect(
      ChartPosition.fromRecord(record('sell'), mark: 98, fresh: true)!.pnl,
      4,
    );
    expect(
      ChartPosition.fromRecord(record('buy'), mark: 102, fresh: false)!.pnl,
      isNull,
    );
    expect(
      ChartPosition.fromRecord({...record('buy'), 'qty': double.infinity}),
      isNull,
    );
    expect(
      ChartPosition.fromRecord({...record('buy'), 'status': 'closed'}),
      isNull,
    );
    expect(
      validChartCandle(
        Candle(time: DateTime(2026), open: 100, high: 99, low: 98, close: 100),
      ),
      false,
    );
  });
  testWidgets(
    'compact chart styles, settings validation, saved layout and pinch/pan',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      await t.binding.setSurfaceSize(const Size(360, 850));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final key = GlobalKey<CandleChartPanelState>(), image = GlobalKey();
      final data = fakeCandles(100);
      await t.pumpWidget(
        RepaintBoundary(
          key: image,
          child: MaterialApp(
            theme: ThemeData.dark(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: SingleChildScrollView(
                child: CandleChartPanel(
                  key: key,
                  loader: (_) async => data,
                  marketSnapshot: () => ChartMarketSnapshot(
                    price: data.last.close,
                    fresh: true,
                    positions: [
                      ChartPosition(
                        buy: true,
                        entry: 4105,
                        quantity: 2,
                        stop: 4095,
                        target: 4140,
                        pnl: 12,
                      ),
                      ChartPosition(
                        buy: false,
                        entry: 4110,
                        quantity: 1,
                        stop: 4150,
                        target: 4050,
                        pnl: -3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Chart style'));
      await t.pumpAndSettle();
      await t.tap(find.text('Line'));
      await t.pumpAndSettle();
      expect(painter(t).chartStyle, ChartStyle.line);
      await t.tap(find.byTooltip('Chart style'));
      await t.pumpAndSettle();
      await t.tap(find.text('Bars'));
      await t.pumpAndSettle();
      expect(painter(t).chartStyle, ChartStyle.bars);
      await t.tap(find.text('Indicators'));
      await t.pumpAndSettle();
      await t.tap(find.text('Indicator settings…'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('indicator-period-2')), '30');
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(find.textContaining('MACD fast must'), findsOneWidget);
      for (final entry in <int, int>{0: 21, 1: 7, 2: 8, 3: 17, 4: 5}.entries) {
        await t.enterText(
          find.byKey(ValueKey('indicator-period-${entry.key}')),
          '${entry.value}',
        );
      }
      await t.ensureVisible(find.text('Apply'));
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      final s = key.currentState!;
      expect(s.emaPeriod, 21);
      expect(s.rsiPeriod, 7);
      expect(s.macdSlow, 17);
      await t.tap(find.text('Indicators'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('RSI 7'));
      await t.tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'RSI 7'));
      await t.pumpAndSettle();
      await t.tap(find.text('Indicators'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('MACD 8/17/5'));
      await t.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'MACD 8/17/5'),
      );
      await t.pumpAndSettle();
      expect(s.rsiOn, true);
      expect(s.macdOn, true);
      await s.savePreset('Chart upgrade');
      final layout = Map<String, dynamic>.from(
        (await s.readPresets())['Chart upgrade'],
      );
      s.chartStyle = ChartStyle.candles;
      s.emaPeriod = 50;
      s.applyPreset(layout);
      await t.pumpAndSettle();
      expect(s.chartStyle, ChartStyle.bars);
      expect(s.emaPeriod, 21);
      final chart = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CandlePainter,
      );
      final center = t.getCenter(chart);
      final a = await t.createGesture(pointer: 1),
          b = await t.createGesture(pointer: 2);
      await a.down(center - const Offset(30, 0));
      await b.down(center + const Offset(30, 0));
      await t.pump();
      await a.moveTo(center - const Offset(85, 0));
      await b.moveTo(center + const Offset(85, 0));
      await t.pump();
      await a.up();
      await b.up();
      await t.pumpAndSettle();
      expect(s.visibleOverride, lessThan(100));
      await t.drag(chart, const Offset(75, 0));
      await t.pumpAndSettle();
      expect(s.scrollCandles, greaterThan(0));
      expect(painter(t).positions.length, 2);
      expect(find.textContaining('BUY 0.02 lots (2.0 oz) +\$12.00'), findsOneWidget);
      expect(t.takeException(), isNull);
      await capture(t, image, 'phone-synthetic');
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'fullscreen preserves layout, listens to live updates, returns settings, restores orientation',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      await t.binding.setSurfaceSize(const Size(820, 390));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final calls = <MethodCall>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final updates = ValueNotifier(0),
          key = GlobalKey<CandleChartPanelState>(),
          image = GlobalKey();
      var px = 4120.0;
      await t.pumpWidget(
        RepaintBoundary(
          key: image,
          child: MaterialApp(
            theme: ThemeData.dark(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: SingleChildScrollView(
                child: CandleChartPanel(
                  key: key,
                  loader: (_) async => fakeCandles(100),
                  marketUpdates: updates,
                  marketSnapshot: () => ChartMarketSnapshot(
                    price: px,
                    positions: [
                      ChartPosition(
                        buy: true,
                        entry: 4100,
                        quantity: 1,
                        stop: 4090,
                        target: 4130,
                        pnl: px - 4100,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final s = key.currentState!;
      // ignore: invalid_use_of_protected_member
      s.setState(() {
        s.chartStyle = ChartStyle.line;
        s.rsiOn = true;
        s.macdOn = true;
        s.emaPeriod = 21;
        s.visibleOverride = 30;
        s.scrollCandles = 10;
      });
      await t.pumpAndSettle();
      await t.tap(find.byIcon(Icons.fullscreen));
      await t.pumpAndSettle();
      final full = t.state<CandleChartPanelState>(
        find.byType(CandleChartPanel).last,
      );
      expect(full.chartStyle, ChartStyle.line);
      expect(full.emaPeriod, 21);
      expect(full.rsiOn, true);
      expect(full.visibleOverride, 30);
      expect(full.scrollCandles, 10);
      px = 4124;
      updates.value++;
      await t.pumpAndSettle();
      expect(painter(t).livePrice, 4124);
      expect(find.textContaining('+\$24.00'), findsOneWidget);
      expect(t.takeException(), isNull);
      await capture(t, image, 'landscape-synthetic');
      // ignore: invalid_use_of_protected_member
      full.setState(() => full.chartStyle = ChartStyle.bars);
      await t.pumpAndSettle();
      await t.tap(find.byIcon(Icons.fullscreen_exit));
      await t.pumpAndSettle();
      expect(s.chartStyle, ChartStyle.bars);
      expect(s.scrollCandles, 10);
      expect(
        calls
            .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
            .first
            .arguments,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
      );
      expect(
        calls
            .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
            .last
            .arguments,
        ['DeviceOrientation.portraitUp'],
      );
      await t.pumpWidget(const SizedBox());
      updates.dispose();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'invalid history is refused; fresh quote marker never rewrites historic candles',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      var valid = true;
      final key = GlobalKey<CandleChartPanelState>();
      final original = fakeCandles(70);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CandleChartPanel(
              key: key,
              loader: (_) async => valid
                  ? original
                  : [
                      Candle(
                        time: DateTime.utc(2026),
                        open: double.nan,
                        high: 1,
                        low: 1,
                        close: 1,
                      ),
                    ],
              marketSnapshot: () =>
                  const ChartMarketSnapshot(price: 9999, fresh: false),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(painter(t).livePrice, isNull);
      expect(painter(t).candles.last.close, original.last.close);
      valid = false;
      await t.pump(const Duration(minutes: 5));
      await t.pumpAndSettle();
      expect(find.textContaining('invalid prices'), findsOneWidget);
      expect(key.currentState!.candles, original);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lagging candle feed: forming bar synthesized from live quote, line meets last candle',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      // 15m bars (default interval), last bar closed ~20 minutes ago:
      // ~1.3 bars of lag, inside the 3-bar synthesis cap.
      final now = DateTime.now();
      final bars = List.generate(
        50,
        (i) => Candle(
          time: now.subtract(Duration(minutes: 15 * (50 - i) + 5)),
          open: 4100,
          high: 4110,
          low: 4090,
          close: 4105,
          volume: 1,
        ),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CandleChartPanel(
              loader: (_) async => bars,
              marketSnapshot: () =>
                  const ChartMarketSnapshot(price: 4123.5, fresh: true),
              livePrice: 4123.5,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final cs = painter(t).candles;
      expect(cs.length, bars.length + 1); // synthesized forming bar appended
      expect(cs.last.close, 4123.5); // close == live quote
      // The forming bar must be INSIDE the visible window (a provider-
      // length window clips it off the right edge - the v1.0.88 bug).
      final p0 = painter(t);
      expect(p0.firstVisible + p0.visibleCount, greaterThanOrEqualTo(cs.length));
      expect(cs.last.open, 4105); // opens at last real close
      expect(cs.take(bars.length).map((c) => c.close).join(','),
          bars.map((c) => c.close).join(',')); // history untouched
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('candle-feed outage: no bar is fabricated beyond 3 bars of lag',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    final bars = fakeCandles(60); // 13+ days stale
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CandleChartPanel(
            loader: (_) async => bars,
            marketSnapshot: () =>
                const ChartMarketSnapshot(price: 4123.5, fresh: true),
            livePrice: 4123.5,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(painter(t).candles.length, bars.length); // nothing fabricated
    await t.pumpWidget(const SizedBox());
  });
}
